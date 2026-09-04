namespace LRN.ReportsApi.Models;

/// <summary>Full menu-item row used by both the navbar fetch and the Menu Master admin grid.</summary>
public sealed class MenuItemDto
{
    public int MenuItemId { get; set; }
    public int? ParentMenuItemId { get; set; }
    public string MenuName { get; set; } = string.Empty;
    public string? ControllerName { get; set; }
    public string? ActionName { get; set; }
    public string? AreaName { get; set; }
    public string? IconClass { get; set; }
    public string? IconImagePath { get; set; }
    public int MenuOrder { get; set; }
    public DateTime? ActiveFrom { get; set; }
    public DateTime? ActiveTo { get; set; }
    public bool IsDisabled { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? CreatedOn { get; set; }
    public string? ModifiedBy { get; set; }
    public DateTime? ModifiedOn { get; set; }
}

/// <summary>Create/update payload for a menu item.</summary>
public sealed class MenuItemSaveRequest
{
    public int? ParentMenuItemId { get; set; }
    public string MenuName { get; set; } = string.Empty;
    public string? ControllerName { get; set; }
    public string? ActionName { get; set; }
    public string? AreaName { get; set; }
    public string? IconClass { get; set; }
    public string? IconImagePath { get; set; }
    public int MenuOrder { get; set; }
    public DateTime? ActiveFrom { get; set; }
    public DateTime? ActiveTo { get; set; }
    public bool IsDisabled { get; set; }
}

public sealed class MenuDisabledRequest
{
    public bool IsDisabled { get; set; }
}

/// <summary>Controller/Action pair managed by the menu master (used for server-side enforcement).</summary>
public sealed class MenuRouteDto
{
    public string? AreaName { get; set; }
    public string ControllerName { get; set; } = string.Empty;
    public string ActionName { get; set; } = string.Empty;
}

public sealed class MenuRoleOptionDto
{
    public int RoleId { get; set; }
    public string RoleName { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}

public sealed class RoleMenuSaveRequest
{
    public List<int> MenuIds { get; set; } = new();
}

/// <summary>
/// A UI element that is not a navbar menu item but still needs per-role access
/// (header icons, in-page launchers). Managed on the Role Menu Mapping screen.
/// </summary>
public sealed class MenuFeatureDto
{
    public string FeatureKey { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
}

/// <summary>One role's explicit setting for a feature. Absent = "not decided" (host falls back).</summary>
public sealed class RoleFeatureDto
{
    public string FeatureKey { get; set; } = string.Empty;
    public bool IsEnabled { get; set; }
}

public sealed class RoleFeatureSaveRequest
{
    public List<RoleFeatureDto> Features { get; set; } = new();
}

/// <summary>
/// The fixed list of role-togglable features. Kept in code rather than a table: each key is
/// wired to a specific piece of UI, so a row nothing reads would only mislead an admin.
/// </summary>
public static class MenuFeatureCatalog
{
    public const string ReimbursementChatHeaderIcon = "ReimbursementChat.HeaderIcon";
    public const string ReimbursementChatHelpBubble = "ReimbursementChat.HelpBubble";

    public static IReadOnlyList<MenuFeatureDto> All { get; } = new List<MenuFeatureDto>
    {
        new()
        {
            FeatureKey  = ReimbursementChatHeaderIcon,
            DisplayName = "Reimbursement chat icon (header)",
            Description = "The robot icon in the top bar that opens Reimbursement Insights in a new tab."
        },
        new()
        {
            FeatureKey  = ReimbursementChatHelpBubble,
            DisplayName = "Reimbursement option in the help chat bubble",
            Description = "The \"Ask about reimbursement rates\" shortcut inside the floating help bot."
        }
    };

    public static bool IsKnown(string? featureKey)
        => !string.IsNullOrWhiteSpace(featureKey)
        && All.Any(f => string.Equals(f.FeatureKey, featureKey, StringComparison.OrdinalIgnoreCase));
}
