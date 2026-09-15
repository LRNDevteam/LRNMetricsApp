namespace LRN.ReportsApi.Models;

/// <summary>
/// A saved Excel snapshot of the Denial Dashboard (Monthly Summary + Weekly Summary + Denial
/// Insight - the same workbook "Download Excel" already produces), named by period range. Mirrors
/// DenialSummarySnapshotInfo's shape; a separate type because this snapshot belongs to a different
/// table (dbo.DenialDashboardSnapshot) with different retention defaults.
/// </summary>
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

public sealed class DenialDashboardSnapshotFile
{
    public string FileName { get; set; } = string.Empty;
    public byte[] Content { get; set; } = Array.Empty<byte>();
}

/// <summary>What LabMetricsDashboard posts once it has built the workbook client-side (it owns
/// DenialDashboardExcelExportBuilder; this API only stores/retrieves the bytes per lab).</summary>
public sealed class DenialDashboardSnapshotUploadRequest
{
    public string PeriodType { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }
    public string FileName { get; set; } = string.Empty;
    public byte[] Content { get; set; } = Array.Empty<byte>();
    public string? CreatedBy { get; set; }
}

/// <summary>Bound from appsettings "DenialDashboardSnapshots".</summary>
public sealed class DenialDashboardSnapshotOptions
{
    /// <summary>Active snapshots kept per lab; older ones are archived, never deleted.</summary>
    public int WeeklyRetention { get; set; } = 4;
    public int MonthlyRetention { get; set; } = 4;
    public int OnDemandRetention { get; set; } = 4;
}
