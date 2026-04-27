namespace LabMetricsDashboard.Models;

public sealed class UserLab
{
    public int ULID { get; init; }
    public int LabId { get; init; }
    public int LabUserID { get; init; }
    // Optional lab display name (joined from Labs table)
    public string LabName { get; init; } = string.Empty;
}
