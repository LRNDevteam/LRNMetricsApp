namespace LabMetricsDashboard.Models.Menu;

/// <summary>Menu item row as returned by LRN.ReportsApi (api/menu).</summary>
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

/// <summary>Create/update payload posted to LRN.ReportsApi.</summary>
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

/// <summary>Node of the rendered navbar tree (2 levels: parent -> children).</summary>
public sealed class MenuItemVm
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
    public bool IsDisabled { get; set; }
    public List<MenuItemVm> Children { get; set; } = new();

    public bool HasLink => !string.IsNullOrWhiteSpace(ControllerName)
                        && !string.IsNullOrWhiteSpace(ActionName);
}

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

public sealed class RoleMenuSaveDto
{
    public int RoleId { get; set; }
    public List<int> MenuIds { get; set; } = new();

    /// <summary>
    /// Non-menu UI elements toggled on the same screen (header chat icon, help-bubble
    /// shortcut). Saved together with the menus so one Save button covers both.
    /// </summary>
    public List<RoleFeatureDto> Features { get; set; } = new();
}

/// <summary>A togglable UI element that is not a navbar menu item.</summary>
public sealed class MenuFeatureDto
{
    public string FeatureKey { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
}

/// <summary>One role's explicit setting for a feature. No row = not decided.</summary>
public sealed class RoleFeatureDto
{
    public string FeatureKey { get; set; } = string.Empty;
    public bool IsEnabled { get; set; }
}

/// <summary>Feature keys the dashboard reads. Must match LRN.ReportsApi's MenuFeatureCatalog.</summary>
public static class MenuFeatureKeys
{
    public const string ReimbursementChatHeaderIcon = "ReimbursementChat.HeaderIcon";
    public const string ReimbursementChatHelpBubble = "ReimbursementChat.HelpBubble";
}

public sealed class MenuDisabledDto
{
    public int MenuItemId { get; set; }
    public bool IsDisabled { get; set; }
}

public sealed class MenuDeleteDto
{
    public int MenuItemId { get; set; }
}
