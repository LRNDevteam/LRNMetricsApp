using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services.Security;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Resolves which lab to use for the current request and persists the
/// choice in a cookie so subsequent page navigations default to the
/// same lab without requiring a <c>?lab=</c> query parameter.
///
/// <para><b>This is the tenant boundary.</b> Every page resolves its lab here and then opens that
/// lab's database with the connection string the answer selects, so whatever this returns is the
/// client whose data the request can read. It therefore answers only with a lab the signed-in user
/// is actually entitled to.</para>
/// </summary>
/// <remarks>
/// It did not always. The <c>?lab=</c> parameter was returned verbatim, unchecked, while only the
/// cookie was validated - and validated against every configured lab rather than the user's own. Any
/// authenticated user could therefore read any client's data by editing one query parameter. The
/// check lives here rather than in the callers because there are around forty call sites across the
/// controllers and all but three passed the full lab list; one gate they all already funnel through
/// is the only version of this that stays correct as pages are added.
/// </remarks>
public static class LabSelectionHelper
{
    private const string CookieName = "lmd_selected_lab";

    /// <summary>
    /// Determines the active lab from (in priority order):
    /// <list type="number">
    ///   <item><c>lab</c> query-string parameter - honoured only if the user is entitled to it</item>
    ///   <item><c>lmd_selected_lab</c> cookie - same check</item>
    ///   <item>First lab the user is entitled to</item>
    /// </list>
    /// Returns empty when the user is entitled to none, which the callers already surface as
    /// "lab not configured" rather than falling through to somebody else's data.
    /// </summary>
    public static string Resolve(HttpContext httpContext, string? labParam, List<string> availableLabs)
    {
        ArgumentNullException.ThrowIfNull(httpContext);

        var permitted = PermittedLabs(httpContext, availableLabs);

        // An unentitled ?lab= is IGNORED, not rejected: a user following a stale or shared link
        // lands on their own lab rather than on an error, and either way sees nothing of the lab
        // they asked for.
        var selectedLab = Match(permitted, labParam);

        if (string.IsNullOrWhiteSpace(selectedLab)
            && httpContext.Request.Cookies.TryGetValue(CookieName, out var cookieLab))
        {
            selectedLab = Match(permitted, cookieLab);
        }

        selectedLab ??= permitted.FirstOrDefault();

        if (!string.IsNullOrWhiteSpace(selectedLab))
        {
            httpContext.Response.Cookies.Append(CookieName, selectedLab, new CookieOptions
            {
                HttpOnly = true,
                SameSite = SameSiteMode.Lax,
                IsEssential = true,
                MaxAge = TimeSpan.FromDays(30),
            });
        }

        return selectedLab ?? string.Empty;
    }

    /// <summary>
    /// The labs this user may open: the ones assigned to them, plus - for a Super Admin - every
    /// configured lab except a demo one they were not explicitly given.
    /// </summary>
    /// <remarks>
    /// The assignments come from the "LabName" claims stamped at login, whose values are
    /// LabConfig:LabsID names, which is the same key space as LabSettings.Labs. A lab assigned
    /// after the user signed in is therefore not reachable until they sign in again - the safe
    /// direction to be wrong in.
    /// </remarks>
    public static List<string> PermittedLabs(HttpContext httpContext, IEnumerable<string> configuredLabs)
    {
        var user = httpContext.User;
        if (user?.Identity?.IsAuthenticated != true) return [];

        var configured = configuredLabs?.ToList() ?? [];
        var assigned = AppRoles.LabNames(user).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var isSuperAdmin = AppRoles.IsSuperAdmin(user);

        // LabConfigOptions owns the demo-lab carve-out, so the same rule the lab picker uses is
        // the rule enforced here. Without it registered, fall back to the strict reading.
        var labConfig = httpContext.RequestServices?.GetService<LabConfigOptions>();
        if (labConfig is not null) return labConfig.VisibleLabs(configured, assigned, isSuperAdmin);

        return configured.Where(lab => assigned.Contains(lab) || isSuperAdmin).ToList();
    }

    /// <summary>
    /// The configured spelling of <paramref name="candidate"/> when it is permitted, else null.
    /// Returning the configured spelling keeps a differently-cased URL from being written into the
    /// cookie and then failing a case-sensitive lookup later.
    /// </summary>
    private static string? Match(List<string> permitted, string? candidate)
        => string.IsNullOrWhiteSpace(candidate)
            ? null
            : permitted.FirstOrDefault(l => string.Equals(l, candidate.Trim(), StringComparison.OrdinalIgnoreCase));
}
