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
