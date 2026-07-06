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
