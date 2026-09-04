namespace LabMetricsDashboard.Models;

/// <summary>
/// The analyst-manager-team lookup AR reports join against a lab's free-text
/// DenialTaskBoard.AssignedTo (see AR Reporting Requirements GAP-2). One row per active user who
/// has a manager and/or team on file; a user with neither is not worth a row here, since the
/// report-side join is a LEFT JOIN and a missing row already reads as "no manager on file".
/// </summary>
public sealed class AnalystManagerTeam
{
    public string UserName { get; set; } = string.Empty;
    public string ManagerUserName { get; set; } = string.Empty;
    public string TeamName { get; set; } = string.Empty;
}
