public sealed class ImportOptions
{
    // Local staging download folder
    public string WatchFolder { get; set; } = "";

    // Where to move a bad XLSX (and error txt) so it won't keep retrying
    public string ErrorFolder { get; set; } = "";

    // Root for outputs:
    // \LabReportOutputs\Masters\{Lab}\Master\<Month>\<LatestDate>\(ClaimLevel|LineLevel)
    public string ReportOutputsRoot { get; set; } = "";

    // If true, keep the downloaded XLSX in WatchFolder after processing (useful for debugging)
    public bool KeepDownloadedFiles { get; set; } = false;

    // Poll interval
    public int PollSeconds { get; set; } = 60;

    // ---- CSV FILE output switches (MasterFileProcessor section) ---------------------------
    // Whether the standardized line-level / claim-level CSV is written to the output folder.
    // Independent per level, and overridable per lab in its Labs[] entry below.
    //
    //   "MasterFileProcessor": {
    //     "CreateLineLevelCsv": true,
    //     "CreateClaimLevelCsv": false,
    //     ...
    //
    // THESE CONTROL THE FILE ONLY. The SQL bulk copy into LineLevelData / ClaimLevelData always
    // runs regardless: the file is always produced in the staging folder and the loader reads it
    // from there, so false means "no file on disk", never "no data in the table".
    // To stop a level loading to SQL, set BulkCopyToTable=false in that lab's *FieldMappings.json.
    public bool CreateLineLevelCsv { get; set; } = true;
    public bool CreateClaimLevelCsv { get; set; } = true;

    // Sheet candidates (comma separated). Worker picks first one that exists.
    // Example: "Master Line Level,Line Level,LineLevel,Master_Line_Level"
    public string SheetName { get; set; } = "Master Line Level,Line Level,LineLevel,Master_Line_Level";

    // Claim sheet candidates
    public string ClaimSheetName { get; set; } = "Claim Level,ClaimLevel,Master Claim Level,Master_Claim_Level,Claim_Level";

    // Header row for schema validator & billing-frequency reader
    public int HeaderRow { get; set; } = 1;

    // Optional billing frequency (can be enabled later)
    public bool EnableBillingFrequency { get; set; } = false;
    public string DestinationTable { get; set; } = "dbo.BillingFrequency";

    // Processed status table (SQL)
    public string FileStatusTable { get; set; } = "dbo.BillingFrequencyFileStatus";

    // Schema JSON (relative paths are resolved from AppContext.BaseDirectory)
    public string LineLevelSchemaJsonPath { get; set; } = "Schemas/LineLevel.schema.json";
    public string ClaimLevelSchemaJsonPath { get; set; } = "Schemas/ClaimLevel.schema.json";

    // COMMON schema json paths for standardized CSV output
    public string CommonLineLevelSchemaJsonPath { get; set; } = "Schemas/LineLevel.schema.json";
    public string CommonClaimLevelSchemaJsonPath { get; set; } = "Schemas/ClaimLevel.schema.json";

    // Consolidated Lab Insurance Master (CSV) for payer normalization
    public string InsuranceMasterCsvPath { get; set; } = "";
    public string PanelMasterFilePath { get; set; } = "";

    // Local folder for filestatus_*.csv
    public string FileStatusLogLocalFolder { get; set; } = "";

    // Keep RAW exports
    public bool KeepRawCsvExports { get; set; } = false;

    // When no SharePoint week folder covers today:
    //   false (default) -> skip the run; previous week folders are never processed.
    //   true            -> fall back to the latest available week folder and process its file
    //                      (pre-Jul-2026 behavior).
    public bool ProcessPreviousWeekFile { get; set; } = false;

    public SharePointOptions SharePoint { get; set; } = new();

    public List<LabFileMap> Labs { get; set; } = new();
}

public sealed class SharePointOptions
{
    public bool Enabled { get; set; } = false;

    // Graph app-only authentication
    public string TenantId { get; set; } = "";
    public string ClientId { get; set; } = "";
    public string ClientSecret { get; set; } = "";

    // Example:
    // Hostname: "3eclaimsprocessingllc.sharepoint.com"
    // SitePath: "/sites/3EClaimsProcessingLLC"
    public string Hostname { get; set; } = "";
    public string SitePath { get; set; } = "";

    // Drive name (often "Documents")
    public string DriveName { get; set; } = "Documents";

    // OPTIONAL: move processed file to a processed folder
    public bool MoveToProcessed { get; set; } = false;
    public string? ProcessedFolderPath { get; set; }
	public string? SharedFolderUrl { get; set; }

    // Where to upload filestatus_*.csv (path under drive root). Default: "Data Analysis"
    public string FileStatusLogUploadFolderPath { get; set; } = "Data Analysis";

    // ---------------- Output upload (Payer Policy Validation Report) ----------------

    /// <summary>
    /// Root folder (under drive root) where standardized CSV outputs should be uploaded.
    /// Example: "10. Automation/LRN-Output/Payer Policy Validation Report/Lab"
    /// </summary>
    public string OutputUploadFolderPath { get; set; } = "";

    /// <summary>
    /// If true, worker/uploader will upload the generated ClaimLevel + LineLevel CSV outputs.
    /// </summary>
    public bool UploadOutputs { get; set; } = true;

    // ---------------- Master File Processor log upload ----------------

    /// <summary>
    /// Folder (under drive root) to upload the daily master processor log.
    /// Example: "10. Automation/LRN-Logs/Master File Processor"
    /// </summary>
    public string MasterProcessorLogUploadFolderPath { get; set; } = "";

    /// <summary>
    /// If true, worker/uploader will upload the daily master processor log CSV.
    /// </summary>
    public bool UploadMasterProcessorLog { get; set; } = true;
}

public sealed class LabFileMap
{
    public int LabId { get; set; }
    public string LabName { get; set; } = "";

    // SharePoint root path for this Lab (relative to drive root, no leading slash)
    // Example: "Data Analysis/Certus/To Daryl/Master Data"
    public string SharePointRootPath { get; set; } = "";

    // File pattern inside the latest date folder (wildcards)
    // Example: "Certus_Master File_*.xlsx"
    public string SharePointFilePattern { get; set; } = "*.xlsx";

    // Optional per-lab schema overrides (relative to app base)
    public string? LineLevelSchemaJsonPath { get; set; }
    public string? ClaimLevelSchemaJsonPath { get; set; }

	public string? LimsMasterFilePattern { get; set; }
	public string? ClientPaidFileNamePattern { get; set; }

	// Comma-separated line-level sheet names for labs whose line-level data spans multiple sheets (e.g. NWL).
	// When set, overrides the global SheetName for this lab. Multiple entries trigger a combined export
	// with an added "Source" column; the value per row is the sheet name with " Line Level" suffix stripped.
	public string? LineLevelSheetNames { get; set; }

	// ---- Per-lab CSV FILE output switches -------------------------------------------------
	// Override MasterFileProcessor:CreateLineLevelCsv / CreateClaimLevelCsv for THIS lab only.
	// File output only - the SQL load is unaffected. See the section-level comment above.
	//
	//   { "LabId": 18, "LabName": "Certus",
	//     "CreateLineLevelCsv": true, "CreateClaimLevelCsv": false, ... }
	//
	// Leave unset (null) to inherit the section-level default.
	public bool? CreateLineLevelCsv { get; set; }
	public bool? CreateClaimLevelCsv { get; set; }
}
