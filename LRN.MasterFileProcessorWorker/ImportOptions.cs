public sealed class ImportOptions
{
    public string WatchFolder { get; set; } = "";
    public string ErrorFolder { get; set; } = "";
    public string ReportOutputsRoot { get; set; } = "";
    public bool KeepDownloadedFiles { get; set; } = false;
    public int PollSeconds { get; set; } = 60;
    public string SheetName { get; set; } = "Master Line Level,Line Level,LineLevel,Master_Line_Level";
    public string ClaimSheetName { get; set; } = "Claim Level,ClaimLevel,Master Claim Level,Master_Claim_Level,Claim_Level";
    public int HeaderRow { get; set; } = 1;
    public bool EnableBillingFrequency { get; set; } = false;
    public string DestinationTable { get; set; } = "dbo.BillingFrequency";
    public string FileStatusTable { get; set; } = "dbo.BillingFrequencyFileStatus";
    public string LineLevelSchemaJsonPath { get; set; } = "Schemas/LineLevel.schema.json";
    public string ClaimLevelSchemaJsonPath { get; set; } = "Schemas/ClaimLevel.schema.json";
    public string CommonLineLevelSchemaJsonPath { get; set; } = "Schemas/LineLevel.schema.json";
    public string CommonClaimLevelSchemaJsonPath { get; set; } = "Schemas/ClaimLevel.schema.json";
    public string InsuranceMasterCsvPath { get; set; } = "";
    public string PanelMasterFilePath { get; set; } = "";
    public string FileStatusLogLocalFolder { get; set; } = "";
    public bool KeepRawCsvExports { get; set; } = false;

    public SharePointOptions SharePoint { get; set; } = new();
    public List<LabFileMap> Labs { get; set; } = new();
}

public sealed class SharePointOptions
{
    public bool Enabled { get; set; } = false;
    public string TenantId { get; set; } = "";
    public string ClientId { get; set; } = "";
    public string ClientSecret { get; set; } = "";
    public string Hostname { get; set; } = "";
    public string SitePath { get; set; } = "";
    public string DriveName { get; set; } = "Documents";
    public bool MoveToProcessed { get; set; } = false;
    public string? ProcessedFolderPath { get; set; }
    public string? SharedFolderUrl { get; set; }
    public string FileStatusLogUploadFolderPath { get; set; } = "Data Analysis";
    public string OutputUploadFolderPath { get; set; } = "";
    public bool UploadOutputs { get; set; } = true;
    public string MasterProcessorLogUploadFolderPath { get; set; } = "";
    public bool UploadMasterProcessorLog { get; set; } = true;
}

public sealed class LabFileMap
{
    public int LabId { get; set; }
    public string LabName { get; set; } = "";
    public string SharePointRootPath { get; set; } = "";
    public string SharePointFilePattern { get; set; } = "*.xlsx";
    public string? LineLevelSchemaJsonPath { get; set; }
    public string? ClaimLevelSchemaJsonPath { get; set; }
    public string? LimsMasterFilePattern { get; set; }
    public string? ClientPaidFileNamePattern { get; set; }

    // Comma-separated line-level sheet names for labs whose line-level data spans multiple sheets (e.g. NWL).
    // When set, overrides the global SheetName for this lab. Multiple entries trigger a combined export
    // with an added "Source" column; the value per row is the sheet name with " Line Level" suffix stripped.
    public string? LineLevelSheetNames { get; set; }
}
