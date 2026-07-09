using LabMetricsDashboard.Models.Menu;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.ViewComponents;

/// <summary>
/// Renders the database-driven navbar for the logged-in user's roles.
/// On any failure (Reports API down, menu tables missing) it returns an empty
/// model and the view falls back to the legacy static menu.
/// </summary>
public sealed class DynamicMenuViewComponent : ViewComponent
{
    private readonly IMenuService _menuService;
    private readonly ILogger<DynamicMenuViewComponent> _logger;

    public DynamicMenuViewComponent(IMenuService menuService, ILogger<DynamicMenuViewComponent> logger)
    {
        _menuService = menuService;
        _logger = logger;
    }

    public async Task<IViewComponentResult> InvokeAsync()
    {
        var model = new List<MenuItemVm>();
        try
        {
            model = await _menuService.GetMenuForUserAsync(HttpContext.User, HttpContext.RequestAborted);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Dynamic menu load failed; falling back to the static navbar.");
        }
        return View(model);
    }
}
