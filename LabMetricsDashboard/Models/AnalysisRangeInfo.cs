namespace LabMetricsDashboard.Models;

/// <summary>
/// Header banner values shared across Production Report–style pages:
/// Billed Week Range, ReportId (RunID), and optional Inserted Date.
/// </summary>
public sealed class AnalysisRangeInfo
{
    public string? WeekFolder { get; init; }
    public string? RunId { get; init; }
    public DateTime? InsertedDateTime { get; init; }

    public bool HasAny =>
        !string.IsNullOrWhiteSpace(WeekFolder)
        || !string.IsNullOrWhiteSpace(RunId)
        || InsertedDateTime.HasValue;

    public static AnalysisRangeInfo Empty { get; } = new();
}
