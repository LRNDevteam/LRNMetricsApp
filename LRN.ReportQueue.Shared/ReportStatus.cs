namespace LRN.ReportQueue.Shared;

/// <summary>
/// Report lifecycle. Values match dbo.UserReqReportStatus (TINYINT) in each lab DB.
///
/// Queued → Processing → Completed → Downloaded → Expired → (purged)
///                     ↘ Failed  → (Retry → Queued)
/// Deleted   — user removed it from their panel (file removed immediately).
/// Cancelled — user killed a Queued/Processing report.
/// </summary>
public enum ReportStatus : byte
{
    Queued     = 1,
    Processing = 2,
    Completed  = 3,
    Failed     = 4,
    Downloaded = 5,
    Expired    = 6,
    Deleted    = 7,
    Cancelled  = 8,
}

public static class ReportStatusExtensions
{
    /// <summary>Statuses shown in the user's Reports panel.</summary>
    public static readonly ReportStatus[] VisibleToUser =
        [ReportStatus.Queued, ReportStatus.Processing, ReportStatus.Completed,
         ReportStatus.Failed, ReportStatus.Downloaded];

    public static bool IsDownloadable(this ReportStatus s) =>
        s is ReportStatus.Completed or ReportStatus.Downloaded;

    public static bool IsActive(this ReportStatus s) =>
        s is ReportStatus.Queued or ReportStatus.Processing;

    public static string DisplayName(this ReportStatus s) => s switch
    {
        ReportStatus.Queued     => "Queued",
        ReportStatus.Processing => "Processing",
        ReportStatus.Completed  => "Ready",
        ReportStatus.Failed     => "Failed",
        ReportStatus.Downloaded => "Downloaded",
        ReportStatus.Expired    => "Expired",
        ReportStatus.Deleted    => "Deleted",
        ReportStatus.Cancelled  => "Cancelled",
        _                       => s.ToString(),
    };
}

/// <summary>Well-known report type keys stored in UserReqReports.ReportType.</summary>
public static class ReportTypes
{
    public const string PayerPolicyValidation = "PayerPolicyValidation";
    public const string PredictionAnalysis    = "PredictionAnalysis";
    public const string ForecastingSummary    = "ForecastingSummary";
    public const string ClaimLevelDetails     = "ClaimLevelDetails";
    public const string LineLevelDetails      = "LineLevelDetails";

    // Future (same architecture, new generator per type):
    public const string ExecutiveSummary   = "ExecutiveSummary";
    public const string ProductionReport   = "ProductionReport";
    public const string CollectionReport   = "CollectionReport";
    public const string RevenueDashboard   = "RevenueDashboard";
    public const string ClinicSummary      = "ClinicSummary";
    public const string SalesRepSummary    = "SalesRepSummary";
    public const string LisSummary         = "LisSummary";
}
