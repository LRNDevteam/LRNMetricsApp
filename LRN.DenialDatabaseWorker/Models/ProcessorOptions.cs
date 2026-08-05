namespace DenialDatabaseProcessorWorker.Models;

public sealed class ProcessorOptions
{
	public const string SectionName = "DenialDatabaseProcessor";

	public bool RunOnceOnStartup { get; init; } = true;

	/// <summary>Local output root. Subfolders are created automatically.</summary>
	public string OutputRoot { get; init; } = @"C:\LRN-Files\Automation\LRN-Output\DenialDatabase";

	/// <summary>CSV log path (single file that is appended).</summary>
	public string LogCsvPath { get; init; } = @"C:\LRN-Files\Automation\LRN-Logs\DenialDatabaseProcessor_Log.csv";

	public SharePointOptions SharePoint { get; init; } = new();

	/// <summary>
	/// Denial source table inside each lab database. The payer policy workbook is no longer
	/// produced; the same content is written to this table by the upstream process.
	/// </summary>
	public string PayerValidationReportTable { get; init; } = "dbo.PayerValidationReport";

	/// <summary>Only rows with this Pay Status are pulled into the denial tables.</summary>
	public string DeniedPayStatus { get; init; } = "Denied";

	/// <summary>
	/// true  = process only the newest RunId in PayerValidationReport (matches the old one-file-per-run behaviour).
	/// false = process every denied row in the table, stamped with the newest RunId.
	/// </summary>
	public bool ProcessLatestRunOnly { get; init; } = true;

	/// <summary>
	/// Master switch for the Excel/CSV/ZIP export package. Turn it off to run the worker
	/// as a pure SQL copy (PayerValidationReport -> DenialInsight / DenialLineItem / DenialTaskBoard).
	/// </summary>
	public bool GenerateOutputFiles { get; init; } = false;

	/// <summary>Upload the export package to SharePoint. Ignored when GenerateOutputFiles is false.</summary>
	public bool UploadOutputsToSharePoint { get; init; } = false;

	// Add this so worker can access configuration
	public IConfiguration? Configuration { get; set; }
	public double IntervalMinutes { get; set; }

	// NEW — REQUIRED BY BULK WRITERS
	public string DatabaseConnectionString { get; set; } = "";

}

public sealed class SharePointOptions
{
	public bool Enabled { get; init; } = false;

	public string TenantId { get; init; } = "";
	public string ClientId { get; init; } = "";
	public string ClientSecret { get; init; } = "";

	/// <summary>Example: https://tenant.sharepoint.com/sites/SiteName</summary>
	public string SiteUrl { get; init; } = "";
}
