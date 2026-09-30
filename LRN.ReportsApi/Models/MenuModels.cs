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
        },

        // AR Workbench permission matrix (read by ArWorkbenchController). Listed here so the role
        // feature admin screen shows them and ReplaceRoleFeaturesAsync keeps them on save.
        new() { FeatureKey = ArWorkbenchFeatures.Access,         DisplayName = "AR Workbench: open the workbench",       Description = "Required for any access to the AR Workbench. Alone, it gives read-only (viewer) access." },
        new() { FeatureKey = ArWorkbenchFeatures.Assign,         DisplayName = "AR Workbench: assign and reassign",      Description = "Assignment Management, assignment batches and bulk reassign." },
        new() { FeatureKey = ArWorkbenchFeatures.EditClaim,      DisplayName = "AR Workbench: work claims",              Description = "Log follow-ups and act on claims. Without Assign, the user sees only their own caseload." },
        new() { FeatureKey = ArWorkbenchFeatures.QaDecide,       DisplayName = "AR Workbench: QA decisions",             Description = "Approve or reject in QA Verification (never their own work)." },
        new() { FeatureKey = ArWorkbenchFeatures.Approve,        DisplayName = "AR Workbench: approvals",                Description = "CIP approvals, escalations and data processing (RCM Manager level)." },
        new() { FeatureKey = ArWorkbenchFeatures.ManageUsers,    DisplayName = "AR Workbench: user access",              Description = "Set clinic / provider access scope for workbench users (Administrator level)." },
        new() { FeatureKey = ArWorkbenchFeatures.ViewAudit,      DisplayName = "AR Workbench: audit logs",               Description = "Cross-claim activity trail." },
        new() { FeatureKey = ArWorkbenchFeatures.ManageSettings, DisplayName = "AR Workbench: master file maintenance",   Description = "Edit master lists, denial code map and settings." },
        new() { FeatureKey = ArWorkbenchFeatures.AllClients,     DisplayName = "AR Workbench: all clients",              Description = "See every client, not only an assigned one." },
        new() { FeatureKey = ArWorkbenchFeatures.ViewClientMgmt, DisplayName = "AR Workbench: client management",        Description = "Client roster and activation." },
        new() { FeatureKey = ArWorkbenchFeatures.ScopeClinic,    DisplayName = "AR Workbench: limit to one clinic",      Description = "Clinic Viewer. The clinic is set per user and lab in dbo.ARWorkbenchUserScope." },
        new() { FeatureKey = ArWorkbenchFeatures.ScopeProvider,  DisplayName = "AR Workbench: limit to one provider",    Description = "Provider Viewer. The provider is set per user and lab in dbo.ARWorkbenchUserScope." }
    };

    public static bool IsKnown(string? featureKey)
        => !string.IsNullOrWhiteSpace(featureKey)
        && All.Any(f => string.Equals(f.FeatureKey, featureKey, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// dbo.RoleFeatureAccess keys for the AR Workbench, granted only to the 8 "AR Workbench - ..." roles
/// (LRNMaster_01_ArWorkbench_Roles_Access.sql).
/// </summary>
public static class ArWorkbenchFeatures
{
    /// <summary>dbo.Roles.RoleName prefix of the AR Workbench roles. No other role is read.</summary>
    public const string RolePrefix = "AR Workbench - ";
    public const string Prefix = "ARWorkbench.";
    public const string ScopeClinic = "ARWorkbench.Scope.Clinic";
    public const string ScopeProvider = "ARWorkbench.Scope.Provider";
    public const string Access = "ARWorkbench.Access";
    public const string Assign = "ARWorkbench.Assign";
    public const string EditClaim = "ARWorkbench.EditClaim";
    public const string QaDecide = "ARWorkbench.QaDecide";
    public const string Approve = "ARWorkbench.Approve";
    public const string ManageUsers = "ARWorkbench.ManageUsers";
    public const string ViewAudit = "ARWorkbench.ViewAudit";
    public const string ManageSettings = "ARWorkbench.ManageSettings";
    public const string AllClients = "ARWorkbench.AllClients";
    public const string ViewClientMgmt = "ARWorkbench.ViewClientMgmt";
}
