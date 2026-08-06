namespace DenialDatabaseProcessorWorker.Services.ReportLogging;

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
/// </summary>
public static class WorkflowReportNames
{
	public const string ClaimLevelMaster = "Claim Level Master";
	public const string ClinicSummary = "Clinic Summary";
	public const string CodingValidation = "Coding Validation";
	public const string CollectionSummary = "Collection Summary";
	public const string DenialReport = "Denial Report";
	public const string ExecutiveSummary = "Executive Summary";
	public const string Forecasting = "Forecasting";
	public const string LineLevelMaster = "Line Level Master";
	public const string LisSummary = "LIS Summary";
	public const string PayerPolicyValidation = "Payer Policy Validation";
	public const string PredictionAnalysis = "Prediction Analysis";
	public const string ProductionSummary = "Production Summary";
	public const string SalesRepSummary = "Sales Rep Summary";
	public const string ErrorLog = "Error Log";
}
