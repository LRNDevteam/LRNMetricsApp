namespace LabMetricsDashboard.Models;

/// <summary>Mirrors LRN.ReportsApi's DenialDashboardSnapshotInfo - the API's response shape for a saved snapshot.</summary>
public sealed class DenialDashboardSnapshotInfo
{
    public long SnapshotId { get; set; }
    public int LabId { get; set; }
    public string PeriodType { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }
    public string FileName { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
    public bool IsArchived { get; set; }
    public DateTime? ArchivedOn { get; set; }
    public DateTime CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
}
