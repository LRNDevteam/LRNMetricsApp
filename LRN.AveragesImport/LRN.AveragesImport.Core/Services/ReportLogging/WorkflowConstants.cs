using LRN.AveragesImport.Core.Models;

namespace LRN.AveragesImport.Core.Services.ReportLogging;

/// <summary>
/// Permitted @Status values for dbo.usp_ReportsWorkflowTracker_Upsert.
/// Case matters — anything else is rejected by the procedure.
/// </summary>
public static class WorkflowStatus
{
    /// <summary>Work has begun. Written immediately after the "already done" check passes.</summary>
    public const string InProgress = "InProgress";

    /// <summary>The report produced its output.</summary>
    public const string Success = "Success";

    /// <summary>It did not complete. Short reason in @Remarks, full exception in the info log.</summary>
    public const string Failed = "Failed";

    /// <summary>It deliberately did not run. Always give the reason in @Remarks.</summary>
    public const string Skipped = "Skipped";
}

/// <summary>
/// Permitted @LogType values for dbo.usp_ReportRunIdInfoLog_Insert.
/// Case matters — anything else is rejected by the procedure.
/// </summary>
public static class RunLogType
{
    public const string Start = "Start";
    public const string Info = "Info";
    public const string Warning = "Warning";
    public const string Error = "Error";
    public const string End = "End";
}

/// <summary>
/// Report names from dbo.ReportTypeMaster. @ReportName must match one of these character
/// for character; the procedure resolves ReportTypeId from the name and rejects anything else.
///
/// This worker produces two reports, not one, so the name is passed per call rather than
/// held in options: the two aggregates succeed and fail independently (a lab can import its
/// CPT averages while the panel aggregate fails), and the tracker holds one row per
/// RunId + Lab + Report — a single shared name could not represent that split outcome.
///
/// Both names must exist in dbo.ReportTypeMaster; see Database/05_ReportTypeMaster_Averages.sql.
/// </summary>
public static class WorkflowReportNames
{
    public const string CptAverages = "CPT Averages";
    public const string PanelAverages = "Panel Averages";

    /// <summary>Maps the worker's internal aggregate name to its ReportTypeMaster name.</summary>
    public static string For(string fileType) => fileType switch
    {
        FileTypes.CptAverage => CptAverages,
        FileTypes.PanelAverage => PanelAverages,
        _ => throw new ArgumentOutOfRangeException(nameof(fileType), fileType, "No ReportTypeMaster name for this aggregate.")
    };
}
