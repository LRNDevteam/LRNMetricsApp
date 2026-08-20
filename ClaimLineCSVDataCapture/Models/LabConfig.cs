using System.Text.Json.Serialization;

namespace ClaimLineCSVDataCapture.Models;

public sealed class LabConfig
{
    public string LabName { get; set; } = string.Empty;

    [JsonPropertyName("Paths")]
    public LabPaths Paths { get; set; } = new();

    [JsonPropertyName("Output")]
    public LabOutput Output { get; set; } = new();

    public bool DBEnabled { get; set; }
    public string? DbConnectionString { get; set; }

    /// <summary>
    /// When <c>true</c>, the claim-line CSV capture process reads the file
    /// and inserts data into SQL via <see cref="DbConnectionString"/>.
    /// </summary>
    public bool ClaimLineInsert { get; set; }

    /// <summary>
    /// When <c>true</c>, the latest ClaimLevel and LineLevel CSV files are always
    /// re-processed, even if the same file or RunId was already loaded.
    /// Existing data for the lab is purged from <c>ClaimLevelData</c>,
    /// <c>LineLevelData</c>, and <c>LineClaimFileLogs</c> before re-inserting,
    /// ensuring the tables reflect the current file contents with no duplicates.
    /// Requires <see cref="ClaimLineInsert"/> to also be <c>true</c>.
    /// </summary>
    public bool ClaimLineRefresh { get; set; }

    /// <summary>
    /// The RunId this app last processed for the lab, persisted back into the lab's
    /// JSON config file (next to <see cref="ClaimLineRefresh"/>) at the end of a
    /// successful run.
    /// <para>
    /// On each execution the app calls <c>sp_GetRecentSuccessRunByLab</c> (LRNMaster)
    /// to obtain the latest successfully completed RunId and compares it with this
    /// value. Downstream processing runs only when the two differ (a new successful
    /// run has landed) or when <see cref="ClaimLineRefresh"/> is <c>true</c>.
    /// </para>
    /// Leave empty/absent on a brand-new lab — the first run will then always be
    /// treated as changed.
    /// </summary>
    public string? LastProcessedRunId { get; set; }

    /// <summary>
    /// Lab name passed to the <c>sp_GetRecentSuccessRunByLab</c> stored procedure
    /// (run against the LRNMaster database via the appsettings <c>DefaultConnection</c>)
    /// to fetch the latest successfully completed RunId for this lab.
    /// <para>
    /// The returned RunId (e.g. <c>20260522R0118</c>) is compared with
    /// <see cref="LastProcessedRunId"/>. When the two differ a new successful run has
    /// landed and the refresh steps execute; when they match nothing has changed and
    /// the lab is skipped unless <see cref="ClaimLineRefresh"/> forces a re-run.
    /// </para>
    /// Example: <c>"PCR Labs of America"</c>.
    /// </summary>
    public string? FetchLatestCompletedRunIDParameter { get; set; }

    /// <summary>
    /// Optional per-lab Production Summary settings used when generating the
    /// Production Report Excel from the capture app.
    /// </summary>
    public ProductionSummaryConfig? ProductionSummary { get; set; }

    /// <summary>
    /// Combined path: <c>ServerMastersBasePath</c> \ <c>ServerMasterFolderName</c>.
    /// This is where Claim Level and Line Level CSV files are located.
    /// </summary>
    [JsonIgnore]
    public string ServerMastersPath =>
        string.IsNullOrWhiteSpace(Paths.ServerMastersBasePath) || string.IsNullOrWhiteSpace(Paths.ServerMasterFolderName)
            ? string.Empty
            : Path.Combine(Paths.ServerMastersBasePath, Paths.ServerMasterFolderName);
}

public sealed class LabPaths
{
    public string ServerMastersBasePath { get; set; } = string.Empty;
    public string ServerMasterFolderName { get; set; } = string.Empty;
    public string LabProcessingBasePath { get; set; } = string.Empty;
    public string RecentlyProcessedLineLevelStandardizedFile { get; set; } = string.Empty;
    public string RecentlyProcessedClaimLevelStandardizedFile { get; set; } = string.Empty;
    public string LineLevelStandardizedCsv { get; set; } = string.Empty;
    public string ClaimLevelStandardizedCsv { get; set; } = string.Empty;
    public string PayerMaster { get; set; } = string.Empty;
    public string CodingMaster { get; set; } = string.Empty;
    public string CptFeeSchedule { get; set; } = string.Empty;

    /// <summary>
    /// Optional path to a lab-specific FieldMappings.json.
    /// When set and the file exists, it overrides the global FieldMappingsPath from appsettings.json.
    /// </summary>
    public string? LabFieldMappingsPath { get; set; }

    /// <summary>
    /// Keyword used to identify TransactionDetail Adjustment XLSX files by filename.
    /// Example: "TransactionDetail Adjustment"
    /// Required when the lab receives this supplemental file.
    /// </summary>
    public string? TransactionDetailAdjustmentKeyword { get; set; }

    /// <summary>
    /// Folder path where TransactionDetail Adjustment XLSX files are searched.
    /// When null or empty, falls back to the lab's <c>ServerMastersPath</c>.
    /// </summary>
    public string? TransactionDetailAdjustmentPath { get; set; }
}

public sealed class LabOutput
{
    public string PayerCptAverageBase { get; set; } = string.Empty;
    public string CodingValidationBase { get; set; } = string.Empty;
    public string Reports { get; set; } = string.Empty;
    public string Avgs { get; set; } = string.Empty;
    public string Archive { get; set; } = string.Empty;
    public string ConslidatedAvgs { get; set; } = string.Empty;

    /// <summary>
    /// Optional folder for BeechTree Three-Pillar diagnostic JSON snapshots
    /// (LIS / PMS / Cash per billed week range). When empty, files go to
    /// <see cref="Reports"/>\ThreePillar.
    /// </summary>
    public string ThreePillarJsonPath { get; set; } = string.Empty;
}

public sealed class ProductionSummaryConfig
{
    public string? Rule { get; set; }
    public string? WeekRule { get; set; }
    public string? WeekRange { get; set; }
}
