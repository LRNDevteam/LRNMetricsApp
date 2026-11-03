using Microsoft.AspNetCore.Mvc.ViewFeatures;

namespace LabMetricsDashboard.Services.ReportSnapshots;

/// <summary>
/// Set in ViewData (<see cref="ViewDataKey"/>) when a report page renders a saved snapshot instead of the
/// lab's live data. The layout then shows the page read-only, without the menu, filters or exports, and
/// blocks every call back to the live report. The views swap the URLs they load their lazy tabs from for
/// the ones here, which serve the same tabs from the snapshot.
/// </summary>
public sealed class ReportSnapshotViewContext
{
    public const string ViewDataKey = "ReportSnapshot";

    public static ReportSnapshotViewContext? From(ViewDataDictionary viewData) =>
        viewData[ViewDataKey] as ReportSnapshotViewContext;

    /// <summary>The snapshot file shown (the report's PageModel file, or the Parquet file of a data view).</summary>
    public long FileId { get; init; }
    public long SnapshotRunId { get; init; }
    public string ReportCode { get; init; } = "";
    /// <summary>The Parquet section shown by a data view; null for a report view.</summary>
    public string? ResultSetName { get; init; }
    public string LabName { get; init; } = "";
    public string RunId { get; init; } = "";
    public string WeekFolder { get; init; } = "";
    public DateTime? CapturedOnUtc { get; init; }
    public string? Trigger { get; init; }
    public IReadOnlyList<string> LogicChanges { get; init; } = [];

    /// <summary>Path prefix of the viewer's own endpoints - the only calls a snapshot page may make.</summary>
    public string ViewerBasePath { get; init; } = "";

    // Replacements for the live pages' lazy-load endpoints.
    public string? ProductionPaneUrl { get; init; }
    public string? ProductionMetaUrl { get; init; }
    public string? CollectionTabUrl { get; init; }
    public string? CollectionMetaUrl { get; init; }
    public string? InsightPanelUrlTemplate { get; init; }

    /// <summary>Executive Summary highlight tabs: the run's snapshot of each report, by ReportCode; absent = not captured.</summary>
    public IReadOnlyDictionary<string, string> HighlightUrls { get; init; } = new Dictionary<string, string>();

    public string ReportTitle => Title(ReportCode);

    /// <summary>The Executive Summary highlight frame for a report (ExecutiveSummaryHighlightsExcel's names), or null.</summary>
    public string? HighlightUrl(string report)
    {
        var code = report switch
        {
            "Production" => ReportCodes.ProductionSummary,
            "Collection" => ReportCodes.CollectionSummary,
            "Lims" => ReportCodes.LisSummary,
            "Denial" => ReportCodes.DenialSummary,
            _ => null
        };
        return code is not null && HighlightUrls.TryGetValue(code, out var url) ? url : null;
    }

    /// <summary>The Denial Insight panel of this snapshot for a bucket (Current / Previous).</summary>
    public string? InsightPanelUrl(string bucket) =>
        InsightPanelUrlTemplate?.Replace("__bucket__", Uri.EscapeDataString(bucket), StringComparison.Ordinal);

    public static string Title(string reportCode) => reportCode switch
    {
        ReportCodes.ExecutiveSummary => "Executive Summary",
        ReportCodes.LisSummary => "LIS Summary",
        ReportCodes.ProductionSummary => "Production Summary",
        ReportCodes.CollectionSummary => "Collection Summary",
        ReportCodes.DenialSummary => "Denial Summary",
        ReportCodes.DenialInsight => "Denial Insight",
        ReportCodes.LisInsight => "LIS Key Insights",
        ReportCodes.ProductionInsight => "Production Key Insights",
        ReportCodes.CollectionInsight => "Collection Key Insights",
        "LINELEVEL" => "Line Level",
        "CLAIMLEVEL" => "Claim Level",
        "LIMS" => "LIMS",
        _ => reportCode
    };

    /// <summary>ReportSnapshotFile.ReportCode of the page reports (LRN.ReportWorker's ReportSnapshotCodes).</summary>
    public static class ReportCodes
    {
        public const string ExecutiveSummary = "EXECSUMMARY";
        public const string LisSummary = "LISSUMMARY";
        public const string ProductionSummary = "PRODSUMMARY";
        public const string CollectionSummary = "COLLSUMMARY";
        public const string DenialSummary = "DENIALSUMMARY";
        public const string DenialInsight = "DENIALINSIGHT";
        // The Key Insights & Highlights panels: users' notes, captured on each save or delete.
        public const string LisInsight = "LISINSIGHT";
        public const string ProductionInsight = "PRODINSIGHT";
        public const string CollectionInsight = "COLLINSIGHT";

        /// <summary>The master data Parquet files (LRN.MasterFileProcessorWorker step 88), ResultSetName Data.</summary>
        public static readonly IReadOnlyList<string> MasterData = ["LINELEVEL", "CLAIMLEVEL", "LIMS"];

        /// <summary>The insights snapshot of a report, by the report's code; null for a report without the panel.</summary>
        public static string? InsightFor(string reportCode) => reportCode switch
        {
            LisSummary => LisInsight,
            ProductionSummary => ProductionInsight,
            CollectionSummary => CollectionInsight,
            _ => null
        };

        /// <summary>The insights snapshot of a Notes report name (NotesController.AllowedReports); null for one without it.</summary>
        public static string? InsightForNotesReport(string reportName) => reportName switch
        {
            "LIS Report" => LisInsight,
            "Production Report" => ProductionInsight,
            "Collection Report" => CollectionInsight,
            _ => null
        };
    }

    /// <summary>The run's Key Insights snapshot of this report, as JSON for the read-only panel; null = none captured.</summary>
    public string? InsightsUrl { get; init; }
}
