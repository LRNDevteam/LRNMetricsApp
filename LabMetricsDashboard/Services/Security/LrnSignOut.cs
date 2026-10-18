using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services.Security;

/// <summary>
/// Shared sign-out for AccountController.Logout (MVC menu) and DenialWorkflowController.Logout (the
/// AR Workbench's LOGOUT_URL). A Microsoft user also leaves their Microsoft session, so the next
/// person at a shared PC has to sign in - and pass MFA - again.
/// </summary>
public static class LrnSignOut
{
    public static async Task<IActionResult> SignOutAsync(Controller controller)
    {
        var services = controller.HttpContext.RequestServices;
        var configuration = services.GetRequiredService<IConfiguration>();
        var hybrid = services.GetRequiredService<IOptions<HybridAuthOptions>>().Value;

        var wasEntra = controller.User.FindFirstValue(LrnAuth.ProviderClaim) == LrnAuth.EntraProvider;

        await controller.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        controller.Response.Cookies.Delete(LrnAuth.AuthCookieName(configuration), new CookieOptions { Path = "/" });
        controller.Response.Cookies.Delete("lmd_selected_lab", new CookieOptions { Path = "/" });

        var loginUrl = controller.Url.Action("Login", "Account")!;
        return wasEntra && hybrid.EnableMicrosoftLogin
            ? controller.SignOut(new AuthenticationProperties { RedirectUri = loginUrl }, LrnAuth.EntraScheme)
            : controller.Redirect(loginUrl);
    }
}
