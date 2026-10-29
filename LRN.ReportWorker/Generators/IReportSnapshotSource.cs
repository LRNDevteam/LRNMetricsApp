namespace LRN.ReportWorker.Generators;

/// <summary>
/// A page report whose data can be snapshotted: the same view model the page renders and the Excel
/// export is built from, loaded for one lab with NO filters (the page as it first opens). Implemented by
/// the five generators LRN.SnapshotGenerator captures weekly, so a snapshot always holds exactly what
/// the page would have shown for that run - every lab's own stored procedures, variants and fallbacks.
/// </summary>
public interface IReportSnapshotSource
{
    /// <summary>ReportSnapshotFile.ReportCode, e.g. EXECSUMMARY.</summary>
    string SnapshotReportCode { get; }

    /// <summary>
    /// The page's unfiltered view model for <paramref name="labName"/> (a LabSettings key), or null
    /// when the report is not available for that lab (not configured / no stored procedures).
    /// </summary>
    Task<object?> LoadUnfilteredAsync(string labName, CancellationToken ct);
}

/// <summary>ReportSnapshotFile.ReportCode for the page report snapshots.</summary>
public static class ReportSnapshotCodes
{
    public const string ExecutiveSummary = "EXECSUMMARY";
    public const string LisSummary = "LISSUMMARY";
    public const string ProductionSummary = "PRODSUMMARY";
    public const string CollectionSummary = "COLLSUMMARY";
    public const string DenialSummary = "DENIALSUMMARY";
    /// <summary>The Denial Summary page's Denial Insight tab: client-uploaded, captured on upload.</summary>
    public const string DenialInsight = "DENIALINSIGHT";
}
