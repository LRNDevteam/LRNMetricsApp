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
}
