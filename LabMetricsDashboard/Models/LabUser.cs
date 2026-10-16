namespace LabMetricsDashboard.Models;

public sealed class LabUser
{
    public int LabUserID { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public string FirstName { get; set; } = string.Empty;
    public string LastName { get; set; } = string.Empty;
    public string MiddleName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public string Mobile { get; set; } = string.Empty;
    public bool IsExternalUser { get; set; }
    public bool IsActive { get; set; } = true;

    /// <summary>
    /// AR Reporting Requirements GAP-2: the analyst-manager-team dimension seven of the nine
    /// reports need as a filter/column. Self-referencing - null for a user with no manager on
    /// file (e.g. the AR Manager themselves).
    /// </summary>
    public int? ManagerUserID { get; set; }
    public string TeamName { get; set; } = string.Empty;
    public DateTime? CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public string ModifiedBy { get; set; } = string.Empty;

    // Hybrid authentication (Database/LabMetricsDashboard/HybridAuth_Setup.sql).
    /// <summary>"Local" (username + password) or "Entra" (Sign in with Microsoft; no password).</summary>
    public string AuthProvider { get; set; } = "Local";
    /// <summary>The Entra object id (oid). Microsoft sign-in matches on this only - never on email.</summary>
    public Guid? EntraObjectId { get; set; }
    public Guid? EntraTenantId { get; set; }
    public int FailedLoginCount { get; set; }
    public DateTime? LockoutEndUtc { get; set; }
    /// <summary>Copied into the sign-in cookie; when it changes, existing sessions end at their next re-validation.</summary>
    public Guid SecurityStamp { get; set; }
    public DateTime? LastLoginUtc { get; set; }

    public bool IsEntra => string.Equals(AuthProvider, "Entra", StringComparison.OrdinalIgnoreCase);
}
