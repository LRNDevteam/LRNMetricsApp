using System.Security.Claims;
using LabMetricsDashboard.Filters;
using LabMetricsDashboard.Models.ReportVisibility;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Resolves the signed-in user's Report Visibility settings (Admin &gt; Report Visibility) for one
/// Standard Reports page. See <see cref="ReportVisibilityCatalog"/> for the stored keys.
/// </summary>
public interface IReportAccessService
{
    Task<ReportPageAccess> GetAsync(string pageKey, CancellationToken ct = default);
}

public sealed class ReportAccessService : IReportAccessService
{
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly IMenuService _menuService;
    private readonly ILogger<ReportAccessService> _logger;

    public ReportAccessService(IHttpContextAccessor httpContextAccessor, IMenuService menuService, ILogger<ReportAccessService> logger)
    {
        _httpContextAccessor = httpContextAccessor;
        _menuService = menuService;
        _logger = logger;
    }

    public async Task<ReportPageAccess> GetAsync(string pageKey, CancellationToken ct = default)
    {
        var http = _httpContextAccessor.HttpContext;
        var user = http?.User;
        if (user?.Identity?.IsAuthenticated != true || ReportVisibilityCatalog.FindPage(pageKey) is not { } page)
            return ReportPageAccess.Unrestricted(pageKey);

        // A page renders many tabs, partials and tag helpers: resolve once per request.
        var itemKey = "lmd:report-access:" + page.Key;
        if (http!.Items.TryGetValue(itemKey, out var cached) && cached is ReportPageAccess hit) return hit;

        var access = await ResolveAsync(user, page, ct);
        http.Items[itemKey] = access;
        return access;
    }

    private async Task<ReportPageAccess> ResolveAsync(ClaimsPrincipal user, ReportPageDefinition page, CancellationToken ct)
    {
        // Same rule as MenuAccessFilter: full admins are never restricted.
        if (MenuAccessFilter.IsFullAdmin(user)) return ReportPageAccess.Unrestricted(page.Key);

        try
        {
            var hiddenTabs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var tab in page.Tabs)
            {
                if (await _menuService.GetFeatureSettingAsync(user, ReportVisibilityCatalog.TabViewKey(page.Key, tab.Key), ct) == false)
                    hiddenTabs.Add(tab.Key);
            }

            var insightsVisible = await _menuService.GetFeatureSettingAsync(user, ReportVisibilityCatalog.KeyInsightsViewKey(page.Key), ct) != false;
            var actions = new Dictionary<KeyInsightAction, bool>();
            foreach (var action in page.KeyInsightActions)
            {
                if (await _menuService.GetFeatureSettingAsync(user, ReportVisibilityCatalog.KeyInsightsKey(page.Key, action.Action), ct) is { } allowed)
                    actions[action.Action] = allowed;
            }

            return new ReportPageAccess(page.Key, hiddenTabs, insightsVisible, actions);
        }
        catch (Exception ex)
        {
            // Same fail-open contract as the menu: an unreachable settings API must not hide reports.
            _logger.LogWarning(ex, "Report visibility unavailable for {Page}; showing the page unrestricted.", page.Key);
            return ReportPageAccess.Unrestricted(page.Key);
        }
    }
}

/// <summary>For views and partials: the page's access, or unrestricted when the service is not registered.</summary>
public static class ReportAccessHttpContextExtensions
{
    public static async Task<ReportPageAccess> GetReportAccessAsync(this HttpContext http, string? pageKey)
    {
        if (string.IsNullOrWhiteSpace(pageKey)) return ReportPageAccess.Unrestricted(pageKey ?? string.Empty);
        return http.RequestServices.GetService(typeof(IReportAccessService)) is IReportAccessService service
            ? await service.GetAsync(pageKey, http.RequestAborted)
            : ReportPageAccess.Unrestricted(pageKey);
    }
}

/// <summary>One user's resolved Report Visibility for one page.</summary>
public sealed class ReportPageAccess
{
    private readonly HashSet<string> _hiddenTabs;
    private readonly Dictionary<KeyInsightAction, bool> _actions;

    /// <param name="keyInsightActions">Explicit Allow (true) / Deny (false) per action; a missing action is Default.</param>
    public ReportPageAccess(string pageKey, IEnumerable<string> hiddenTabs, bool keyInsightsVisible,
        IReadOnlyDictionary<KeyInsightAction, bool>? keyInsightActions = null)
    {
        PageKey = pageKey;
        _hiddenTabs = new HashSet<string>(hiddenTabs, StringComparer.OrdinalIgnoreCase);
        KeyInsightsVisible = keyInsightsVisible;
        _actions = keyInsightActions is null ? new() : new Dictionary<KeyInsightAction, bool>(keyInsightActions);
    }

    public static ReportPageAccess Unrestricted(string pageKey) => new(pageKey, [], true);

    public string PageKey { get; }

    public bool KeyInsightsVisible { get; }

    /// <summary>The explicit setting for <paramref name="action"/>, or null when the role left it on Default.</summary>
    public bool? KeyInsightActionOverride(KeyInsightAction action)
        => _actions.TryGetValue(action, out var allowed) ? allowed : null;

    /// <summary>
    /// Whether the user may take <paramref name="action"/> on Key Insights. Needs Key Insights to be
    /// visible; then an explicit Allow / Deny wins, and Default uses <paramref name="fallback"/> - the
    /// page's own rule before Report Visibility existed.
    /// </summary>
    public bool CanKeyInsights(KeyInsightAction action, bool fallback)
        => KeyInsightsVisible && (KeyInsightActionOverride(action) ?? fallback);

    public bool HasHiddenTabs => _hiddenTabs.Count > 0;

    /// <summary>
    /// Whether a tab is shown. <see cref="ReportVisibilityCatalog.KeyInsightsTab"/> follows the Key
    /// Insights setting; a key that is not in the catalog is always visible.
    /// </summary>
    public bool IsTabVisible(string? tabKey)
    {
        if (string.IsNullOrWhiteSpace(tabKey)) return true;
        var key = tabKey.Trim();
        if (string.Equals(key, ReportVisibilityCatalog.KeyInsightsTab, StringComparison.OrdinalIgnoreCase))
            return KeyInsightsVisible;
        return !_hiddenTabs.Contains(key);
    }

    /// <summary>
    /// <paramref name="requested"/> when it is visible, else the first visible tab of
    /// <paramref name="ordered"/>, else null (every tab is hidden).
    /// </summary>
    public string? FirstVisibleTab(string? requested, IEnumerable<string> ordered)
    {
        if (!string.IsNullOrWhiteSpace(requested) && IsTabVisible(requested)) return requested;
        return ordered.FirstOrDefault(IsTabVisible);
    }
}
