using System.Security.Claims;
using LabMetricsDashboard.Models.Menu;
using Microsoft.Extensions.Caching.Memory;

namespace LabMetricsDashboard.Services;

public interface IMenuService
{
    /// <summary>Navbar tree for the current user (union of all their roles), cached per role set.</summary>
    Task<List<MenuItemVm>> GetMenuForUserAsync(ClaimsPrincipal user, CancellationToken ct);

    /// <summary>
    /// Server-side enforcement (FR-9). Returns false only when the route is managed by the
    /// menu master AND the user's menu does not include it as a clickable link.
    /// Routes that are not in the menu master at all (AJAX endpoints, exports, ...) are allowed.
    /// </summary>
    Task<bool> CanAccessAsync(ClaimsPrincipal user, string? area, string? controller, string? action, CancellationToken ct);

    /// <summary>
    /// Per-role visibility for UI elements that are not navbar menu items (the header
    /// chat icon, the help-bubble shortcut). An admin's explicit Enable/Disable on the
    /// Role Menu Mapping screen wins; with nothing set for any of the user's roles the
    /// <paramref name="fallback"/> applies, which keeps behaviour unchanged until an
    /// admin actually makes a choice.
    /// </summary>
    Task<bool> IsFeatureEnabledAsync(ClaimsPrincipal user, string featureKey, bool fallback, CancellationToken ct);

    /// <summary>Invalidate all cached menu data. Call after any Menu Master / Role Menu Mapping save.</summary>
    void InvalidateCache();
}

public sealed class MenuService : IMenuService
{
    private static readonly TimeSpan CacheDuration = TimeSpan.FromMinutes(30);

    // When the Reports API is down/slow, cache the empty result briefly so we retry
    // soon — but do NOT hit the failing API on every single request in the meantime.
    // Without this, an unreachable menu API stalled every page for the full HTTP timeout.
    private static readonly TimeSpan FailureCacheDuration = TimeSpan.FromMinutes(1);

    private readonly IMemoryCache _cache;
    private readonly IMenuApiClient _api;
    private readonly ILogger<MenuService> _logger;

    // Bumped on every admin save so all per-role-set entries are invalidated at once.
    private static int _cacheVersion;

    public MenuService(IMemoryCache cache, IMenuApiClient api, ILogger<MenuService> logger)
    {
        _cache = cache;
        _api = api;
        _logger = logger;
    }

    public void InvalidateCache() => Interlocked.Increment(ref _cacheVersion);

    public async Task<List<MenuItemVm>> GetMenuForUserAsync(ClaimsPrincipal user, CancellationToken ct)
    {
        if (user.Identity?.IsAuthenticated != true) return new List<MenuItemVm>();

        var key = $"menu:v{Volatile.Read(ref _cacheVersion)}:roles:{RoleKey(user)}";
        var cached = await _cache.GetOrCreateAsync(key, async entry =>
        {
            try
            {
                var flat = await _api.GetMyMenusAsync(ct);
                entry.AbsoluteExpirationRelativeToNow = CacheDuration;
                return BuildTree(flat);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Menu API unavailable; using empty menu for {Duration}.", FailureCacheDuration);
                entry.AbsoluteExpirationRelativeToNow = FailureCacheDuration;
                return new List<MenuItemVm>(); // view falls back to the static navbar
            }
        });
        return cached ?? new List<MenuItemVm>();
    }

    public async Task<bool> CanAccessAsync(ClaimsPrincipal user, string? area, string? controller, string? action, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(controller) || string.IsNullOrWhiteSpace(action)) return true;
        var routeKey = RouteKey(area, controller, action);

        try
        {
            var managed = await GetManagedRoutesAsync(ct);
            if (!managed.Contains(routeKey)) return true; // not menu-managed -> not enforced

            var allowed = await GetAllowedRoutesAsync(user, ct);
            if (allowed.Contains(routeKey)) return true;

            // A feature toggle grants its screen too. Without this, an admin who enables the
            // header chat icon for a role that has no ReimbursementChat menu would publish an
            // icon that lands on Access Denied.
            return await IsGrantedByFeatureAsync(user, routeKey, ct);
        }
        catch (Exception ex)
        {
            // Fail open: menu enforcement must not take the whole application down
            // when the Reports API or the menu tables are unavailable.
            _logger.LogWarning(ex, "Menu access check failed for {Controller}/{Action}; allowing request.", controller, action);
            return true;
        }
    }

    public async Task<bool> IsFeatureEnabledAsync(ClaimsPrincipal user, string featureKey, bool fallback, CancellationToken ct)
    {
        if (user.Identity?.IsAuthenticated != true) return false;

        var settings = await GetFeatureSettingsAsync(user, ct);
        return settings.TryGetValue(featureKey, out var isEnabled) ? isEnabled : fallback;
    }

    /// <summary>
    /// Routes a feature toggle can grant on its own, keyed by <see cref="RouteKey"/>.
    /// Both reimbursement toggles open the same screen, so enabling either one is enough.
    /// </summary>
    private static readonly Dictionary<string, string[]> FeatureGrantedRoutes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["/reimbursementchat/index"] = new[]
        {
            MenuFeatureKeys.ReimbursementChatHeaderIcon,
            MenuFeatureKeys.ReimbursementChatHelpBubble
        }
    };

    private async Task<bool> IsGrantedByFeatureAsync(ClaimsPrincipal user, string routeKey, CancellationToken ct)
    {
        if (!FeatureGrantedRoutes.TryGetValue(routeKey, out var featureKeys)) return false;
        var settings = await GetFeatureSettingsAsync(user, ct);
        return featureKeys.Any(key => settings.TryGetValue(key, out var isEnabled) && isEnabled);
    }

    /// <summary>
    /// Explicit role feature settings, already resolved across the user's roles by the API
    /// (any role that enables a feature wins). Features nobody has decided are absent.
    /// </summary>
    private async Task<Dictionary<string, bool>> GetFeatureSettingsAsync(ClaimsPrincipal user, CancellationToken ct)
    {
        var key = $"menu:v{Volatile.Read(ref _cacheVersion)}:features:{RoleKey(user)}";
        var settings = await _cache.GetOrCreateAsync(key, async entry =>
        {
            try
            {
                var rows = await _api.GetMyFeaturesAsync(ct);
                entry.AbsoluteExpirationRelativeToNow = CacheDuration;
                return rows
                    .GroupBy(r => r.FeatureKey, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(g => g.Key, g => g.Any(r => r.IsEnabled), StringComparer.OrdinalIgnoreCase);
            }
            catch (Exception ex)
            {
                // Same fail-open contract as the menu itself: an unreachable API must not
                // change what the user sees, so callers fall back to their own default.
                _logger.LogWarning(ex, "Role feature API unavailable; using defaults for {Duration}.", FailureCacheDuration);
                entry.AbsoluteExpirationRelativeToNow = FailureCacheDuration;
                return new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            }
        });
        return settings ?? new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
    }

    private async Task<HashSet<string>> GetManagedRoutesAsync(CancellationToken ct)
    {
        var key = $"menu:v{Volatile.Read(ref _cacheVersion)}:routes";
        var set = await _cache.GetOrCreateAsync(key, async entry =>
        {
            try
            {
                var routes = await _api.GetManagedRoutesAsync(ct);
                entry.AbsoluteExpirationRelativeToNow = CacheDuration;
                return routes
                    .Select(r => RouteKey(r.AreaName, r.ControllerName, r.ActionName))
                    .ToHashSet(StringComparer.OrdinalIgnoreCase);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Menu routes API unavailable; enforcement disabled for {Duration}.", FailureCacheDuration);
                entry.AbsoluteExpirationRelativeToNow = FailureCacheDuration;
                return new HashSet<string>(StringComparer.OrdinalIgnoreCase); // empty => fail open
            }
        });
        return set ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    }

    private async Task<HashSet<string>> GetAllowedRoutesAsync(ClaimsPrincipal user, CancellationToken ct)
    {
        var key = $"menu:v{Volatile.Read(ref _cacheVersion)}:access:{RoleKey(user)}";
        var set = await _cache.GetOrCreateAsync(key, async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = CacheDuration;
            var tree = await GetMenuForUserAsync(user, ct);
            var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var root in tree)
            {
                if (root.IsDisabled) continue; // disabled parent gates the whole branch
                if (root.HasLink) allowed.Add(RouteKey(root.AreaName, root.ControllerName!, root.ActionName!));
                foreach (var child in root.Children.Where(c => !c.IsDisabled && c.HasLink))
                    allowed.Add(RouteKey(child.AreaName, child.ControllerName!, child.ActionName!));
            }
            return allowed;
        });
        return set ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    }

    private static string RoleKey(ClaimsPrincipal user)
    {
        var roles = user.Claims
            .Where(c => c.Type == ClaimTypes.Role)
            .Select(c => c.Value.Trim().ToLowerInvariant())
            .Where(v => v.Length > 0)
            .Distinct()
            .OrderBy(v => v, StringComparer.Ordinal);
        return string.Join("|", roles);
    }

    private static string RouteKey(string? area, string controller, string action)
        => $"{area ?? string.Empty}/{controller}/{action}".ToLowerInvariant();

    private static List<MenuItemVm> BuildTree(IReadOnlyList<MenuItemDto> flat)
    {
        var nodes = flat.Select(m => new MenuItemVm
        {
            MenuItemId = m.MenuItemId,
            ParentMenuItemId = m.ParentMenuItemId,
            MenuName = m.MenuName,
            ControllerName = m.ControllerName,
            ActionName = m.ActionName,
            AreaName = m.AreaName,
            IconClass = m.IconClass,
            IconImagePath = m.IconImagePath,
            MenuOrder = m.MenuOrder,
            IsDisabled = m.IsDisabled
        }).ToList();

        var byId = nodes.ToDictionary(m => m.MenuItemId);
        var roots = new List<MenuItemVm>();

        foreach (var node in nodes)
        {
            if (node.ParentMenuItemId.HasValue && byId.TryGetValue(node.ParentMenuItemId.Value, out var parent))
                parent.Children.Add(node);
            else if (!node.ParentMenuItemId.HasValue)
                roots.Add(node);
            // child whose parent is not visible for this role/date window -> dropped by design
        }

        foreach (var root in roots)
            root.Children = root.Children.OrderBy(c => c.MenuOrder).ThenBy(c => c.MenuName).ToList();

        // hide grouping-only parents that ended up with no visible children
        return roots
            .Where(r => r.HasLink || r.Children.Count > 0)
            .OrderBy(r => r.MenuOrder).ThenBy(r => r.MenuName)
            .ToList();
    }
}
