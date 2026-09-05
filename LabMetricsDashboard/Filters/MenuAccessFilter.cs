using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace LabMetricsDashboard.Filters;

/// <summary>
/// Server-side menu enforcement (spec FR-9): a user who types a URL directly is blocked
/// with 403 when the route belongs to the menu master but is not in the user's role menu.
/// Routes that are NOT managed by the menu master (AJAX endpoints, exports, partial loads)
/// are never blocked, so rollout is safe for existing functionality.
/// </summary>
public sealed class MenuAccessFilter : IAsyncAuthorizationFilter
{
    // Infrastructure controllers that must always stay reachable regardless of menu mapping.
    private static readonly HashSet<string> AllowedControllers = new(StringComparer.OrdinalIgnoreCase)
    {
        "Account", "Home", "Usage", "HelpBot"
    };

    private static readonly HashSet<string> AllowedDashboardActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "FirstPaintClient",
        "ProductionSummaryReportTab",
        "ProductionSummaryReportMeta",
    };

    private static readonly HashSet<string> AllowedCollectionActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "GetTabPartial", "GetMeta",
    };

    private static readonly HashSet<string> AllowedLisActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "GetSummary", "GetMeta",
    };

    private static readonly HashSet<string> AllowedExecutiveActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "GetTable", "FilterOptions",
    };

    private readonly IMenuService _menuService;

    public MenuAccessFilter(IMenuService menuService)
    {
        _menuService = menuService;
    }

    public async Task OnAuthorizationAsync(AuthorizationFilterContext context)
    {
        if (context.ActionDescriptor.EndpointMetadata.OfType<IAllowAnonymous>().Any()) return;

        var user = context.HttpContext.User;
        if (user.Identity?.IsAuthenticated != true) return; // global auth policy handles this

        // Admins always keep full access (the seed script grants them every menu anyway).
        if (user.IsInRole("Admin") || user.IsInRole("LRN Admin") || user.IsInRole("LRNAdmin")) return;

        var routeValues = context.RouteData.Values;
        var controller = routeValues["controller"] as string;
        var action = routeValues["action"] as string;
        if (string.IsNullOrWhiteSpace(controller) || string.IsNullOrWhiteSpace(action)) return;
        if (AllowedControllers.Contains(controller)) return;
        if (string.Equals(controller, "Dashboard", StringComparison.OrdinalIgnoreCase)
            && AllowedDashboardActions.Contains(action))
            return;
        if (string.Equals(controller, "CollectionSummary", StringComparison.OrdinalIgnoreCase)
            && AllowedCollectionActions.Contains(action))
            return;
        if (string.Equals(controller, "LisSummary", StringComparison.OrdinalIgnoreCase)
            && AllowedLisActions.Contains(action))
            return;
        if (string.Equals(controller, "ExecutiveSummary", StringComparison.OrdinalIgnoreCase)
            && AllowedExecutiveActions.Contains(action))
            return;

        var area = routeValues["area"] as string;
        var menuSw = System.Diagnostics.Stopwatch.StartNew();
        var allowed = await _menuService.CanAccessAsync(user, area, controller, action, context.HttpContext.RequestAborted);
        if (menuSw.ElapsedMilliseconds >= 200)
        {
            FirstPaintLog.Write(
                Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance,
                "Menu",
                controller ?? "",
                $"{controller}/{action}",
                menuSw.ElapsedMilliseconds);
        }
        if (!allowed)
        {
            context.Result = new ForbidResult(); // -> Account/AccessDenied
        }
    }
}
