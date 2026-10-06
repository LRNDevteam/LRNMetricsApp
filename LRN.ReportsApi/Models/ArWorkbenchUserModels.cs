namespace LRN.ReportsApi.Models;

/// <summary>An AR Workbench user on the User Management screen (LRNMaster dbo.LabUsers).</summary>
public sealed class ArWorkbenchManagedUser
{
    public int LabUserId { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string? Email { get; set; }
    public bool IsActive { get; set; }
    /// <summary>The user's "AR Workbench - ..." roles, without the prefix.</summary>
    public List<ArWorkbenchRoleOption> Roles { get; set; } = new();
    /// <summary>The user's labs that the caller manages.</summary>
    public List<ArWorkbenchLabOption> Labs { get; set; } = new();
    /// <summary>Labs the user has outside the caller's labs (not named, only counted).</summary>
    public int OtherLabCount { get; set; }
    /// <summary>The user also holds roles outside the AR Workbench (LRN Metrics, Denial Workflow ...).</summary>
    public bool HasOtherRoles { get; set; }
    public bool IsSiteAdmin { get; set; }
    public bool CanEdit { get; set; }
    /// <summary>Why the caller cannot edit this user, when CanEdit is false.</summary>
    public string? ReadOnlyReason { get; set; }
    public string? CreatedBy { get; set; }
}

public sealed class ArWorkbenchRoleOption
{
    public int RoleId { get; set; }
    public string RoleName { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
}

public sealed class ArWorkbenchLabOption
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
}

public sealed class ArWorkbenchUserManagement
{
    public List<ArWorkbenchManagedUser> Users { get; set; } = new();
    /// <summary>The labs the caller can grant: every lab for a Super Admin, otherwise the caller's own labs.</summary>
    public List<ArWorkbenchLabOption> Labs { get; set; } = new();
    public List<ArWorkbenchRoleOption> Roles { get; set; } = new();
    public bool AllLabs { get; set; }
}

public sealed class ArWorkbenchCreateUserRequest
{
    public string? UserName { get; set; }
    public string? Password { get; set; }
    public string? Email { get; set; }
    public int? RoleId { get; set; }
    public List<int>? LabIds { get; set; }
}

public sealed class ArWorkbenchUpdateUserRequest
{
    public string? Email { get; set; }
    public int? RoleId { get; set; }
    public List<int>? LabIds { get; set; }
    public bool? IsActive { get; set; }
    /// <summary>Optional password reset; blank keeps the current password.</summary>
    public string? Password { get; set; }
}
