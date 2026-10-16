using System.Globalization;
using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services.Security;

/// <summary>
/// Cookie OnValidatePrincipal. Claims are built once at sign-in, so without this a user who is
/// deactivated, or loses a role or lab, keeps the old access until the 8-hour cookie expires. Every
/// <see cref="HybridAuthOptions.RevalidateMinutes"/> the cookie is rebuilt from LabUsers - one
/// database round trip per user per interval, not per request - and rejected when the user is gone,
/// inactive, has no role or labs left, or their security stamp changed (password set, account linked).
/// </summary>
public static class LrnCookieRevalidation
{
    public static async Task ValidateAsync(CookieValidatePrincipalContext ctx)
    {
        var services = ctx.HttpContext.RequestServices;
        var options = services.GetRequiredService<IOptions<HybridAuthOptions>>().Value;
        var now = DateTimeOffset.UtcNow;

        if (ctx.Properties.Items.TryGetValue(LrnAuth.ValidatedItem, out var last)
            && DateTimeOffset.TryParse(last, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var when)
            && now - when < TimeSpan.FromMinutes(Math.Max(1, options.RevalidateMinutes)))
            return;

        if (!int.TryParse(ctx.Principal?.FindFirstValue(ClaimTypes.NameIdentifier), out var labUserId))
        {
            await RejectAsync(ctx);
            return;
        }

        try
        {
            var user = await services.GetRequiredService<IUserManagementRepository>().GetUserByIdAsync(labUserId);
            // Cookies issued before this release carry no stamp; they are accepted once and rebuilt with one.
            var stamp = ctx.Principal!.FindFirstValue(LrnAuth.StampClaim);
            if (user is null || !user.IsActive
                || (stamp is not null && !string.Equals(stamp, user.SecurityStamp.ToString(), StringComparison.OrdinalIgnoreCase)))
            {
                await RejectAsync(ctx);
                return;
            }

            var rebuilt = await services.GetRequiredService<LrnSignInService>().BuildAsync(user, logWarnings: false);
            if (rebuilt.Principal is null)
            {
                await RejectAsync(ctx);   // role or labs removed since sign-in
                return;
            }

            ctx.ReplacePrincipal(rebuilt.Principal);
            ctx.Properties.Items[LrnAuth.ValidatedItem] = now.ToString("O", CultureInfo.InvariantCulture);
            ctx.ShouldRenew = true;
        }
        catch (Exception ex)
        {
            // Fail open, like MenuService: a database blip must not sign every user out. The check is
            // retried on the next request because the validated time was not advanced.
            services.GetRequiredService<ILoggerFactory>()
                .CreateLogger(typeof(LrnCookieRevalidation).FullName!)
                .LogWarning(ex, "Cookie re-validation failed for LabUserID {LabUserId}; keeping the current session.", labUserId);
        }
    }

    private static async Task RejectAsync(CookieValidatePrincipalContext ctx)
    {
        ctx.RejectPrincipal();
        await ctx.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    }
}
