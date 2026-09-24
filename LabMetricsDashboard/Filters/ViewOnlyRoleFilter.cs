using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace LabMetricsDashboard.Filters;

/// <summary>
/// Refuses every state-changing request from a view-only role, whatever page it came from.
/// </summary>
/// <remarks>
/// <para>Lab User is defined as the lab's own staff watching their claims, with no write path at
/// all. LRN.ReportsApi already enforces that on the Denial Workflow side
/// (<c>IsLabUserRole</c> / <c>DenyWriteForLabUser</c>), but the MVC dashboard had no equivalent:
/// the role's reach there was whatever menus an administrator happened to map to it, and any write
/// action on a granted page went through. This closes that gap in one place rather than adding a
/// role test to each of the ~75 POST actions, which is the kind of list that goes stale.</para>
///
/// <para>Hiding buttons is not the boundary - this filter is. Views may still hide controls for
/// tidiness, but a hand-made POST is refused here regardless.</para>
///
/// <para><b>Reading is never blocked.</b> Only unsafe HTTP methods are, and exporting is reading:
/// <c>UserReports</c> queues and downloads by POST, so it is allowed by default. Telemetry beacons
/// and the read-only assistants are allowed for the same reason - they change no lab data.</para>
/// </remarks>
public sealed class ViewOnlyRoleFilter : IAsyncAuthorizationFilter
{
    /// <summary>Roles with no write path. Overridden by <c>ViewOnly:Roles</c>.</summary>
    private static readonly string[] DefaultViewOnlyRoles = ["Lab User"];

    /// <summary>
    /// Unsafe-method endpoints a view-only role may still call, as "controller" or
    /// "controller/action". Overridden by <c>ViewOnly:AllowedPosts</c>.
    /// </summary>
    private static readonly string[] DefaultAllowedPosts =
    [
        "account/login",
        "account/logout",
        "userreports",              // export queue: queue, download, cancel - exporting is reading
        "dashboard/firstpaintclient",
        "usage/heartbeat",
        "helpbot/ask",
        "reimbursementchat/ask",
        "denialworkflow/authtoken", // issues the React JWT; the API enforces the role again
    ];

    private readonly IConfiguration _configuration;
    private readonly ILogger<ViewOnlyRoleFilter> _logger;

    public ViewOnlyRoleFilter(IConfiguration configuration, ILogger<ViewOnlyRoleFilter> logger)
    {
        _configuration = configuration;
        _logger = logger;
    }

    public Task OnAuthorizationAsync(AuthorizationFilterContext context)
    {
        if (context.ActionDescriptor.EndpointMetadata.OfType<IAllowAnonymous>().Any())
            return Task.CompletedTask;

        var user = context.HttpContext.User;
        if (user.Identity?.IsAuthenticated != true) return Task.CompletedTask;

        if (IsSafeMethod(context.HttpContext.Request.Method)) return Task.CompletedTask;
        if (!IsViewOnly(user)) return Task.CompletedTask;

        var controller = context.RouteData.Values["controller"] as string ?? "";
        var action = context.RouteData.Values["action"] as string ?? "";
        if (IsAllowed(controller, action)) return Task.CompletedTask;

        _logger.LogWarning(
            "View-only role blocked {Method} {Controller}/{Action} for {User} (roles: {Roles}).",
            context.HttpContext.Request.Method, controller, action,
            user.Identity?.Name ?? "(unknown)",
            string.Join(", ", user.Claims.Where(c => c.Type == ClaimTypes.Role).Select(c => c.Value)));

        // A fetch/XHR caller wants a status it can act on; a form post wants a page. Returning the
        // login redirect to an XHR would surface as the login HTML inside the grid.
        context.Result = IsApiRequest(context.HttpContext.Request)
            ? new ObjectResult(new { message = "Your account has view-only access and cannot change data." })
            {
                StatusCode = StatusCodes.Status403Forbidden
            }
            : new ForbidResult();

        return Task.CompletedTask;
    }

    private static bool IsSafeMethod(string method) =>
        HttpMethods.IsGet(method) || HttpMethods.IsHead(method) || HttpMethods.IsOptions(method);

    private static bool IsApiRequest(HttpRequest request) =>
        string.Equals(request.Headers["X-Requested-With"], "XMLHttpRequest", StringComparison.OrdinalIgnoreCase)
        || (request.Headers.Accept.ToString() ?? "").Contains("application/json", StringComparison.OrdinalIgnoreCase)
        || (request.ContentType ?? "").Contains("application/json", StringComparison.OrdinalIgnoreCase);

    private bool IsViewOnly(ClaimsPrincipal user)
    {
        var configured = _configuration.GetSection("ViewOnly:Roles").Get<string[]>();
        var roles = configured is { Length: > 0 } ? configured : DefaultViewOnlyRoles;

        var held = user.Claims
            .Where(c => c.Type == ClaimTypes.Role)
            .Select(c => c.Value);

        return HoldsViewOnlyRole(held, roles);
    }

    private bool IsAllowed(string controller, string action)
    {
        var configured = _configuration.GetSection("ViewOnly:AllowedPosts").Get<string[]>();
        var allowed = configured is { Length: > 0 } ? configured : DefaultAllowedPosts;

        return IsAllowedEndpoint(controller, action, allowed);
    }

    /// <summary>True when any role the user holds is on the view-only list.</summary>
    internal static bool HoldsViewOnlyRole(IEnumerable<string?> heldRoles, IEnumerable<string> viewOnlyRoles)
    {
        var held = heldRoles.Select(RoleKey).Where(k => k.Length > 0).ToHashSet(StringComparer.Ordinal);
        return viewOnlyRoles.Select(RoleKey).Any(k => k.Length > 0 && held.Contains(k));
    }

    /// <summary>
    /// True when the endpoint is on the allow list, matched as a whole controller or as
    /// "controller/action".
    /// </summary>
    internal static bool IsAllowedEndpoint(string controller, string action, IEnumerable<string> allowed)
    {
        var full = $"{controller}/{action}";
        return allowed.Any(a =>
            string.Equals(a, controller, StringComparison.OrdinalIgnoreCase)
            || string.Equals(a, full, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Role names are spelled inconsistently in dbo.Roles ("Labuser" against "Lab User"), so
    /// spacing and punctuation are stripped before comparing.
    /// </summary>
    private static string RoleKey(string? value) =>
        new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
}
