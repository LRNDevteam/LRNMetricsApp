namespace LRN.MasterFileProcessorWorker.Snapshots;

/// <summary>
/// Worker switches for the weekly master-data snapshots (step 88): once a lab's Line Level, Claim
/// Level and LIMS tables are loaded, each is written to one Parquet file per run, so the lab
/// database keeps only the current week while the last <see cref="KeepWeeks"/> weeks stay readable.
/// Configured under <c>MasterDataSnapshot</c> in appsettings.json.
/// </summary>
public sealed class MasterDataSnapshotOptions
{
    public const string SectionName = "MasterDataSnapshot";

    /// <summary>
    /// Master switch. Defaults to FALSE so deploying this is inert until the LRNMaster tables
    /// (Database/LRN.MasterFileProcessorWorker/Create_ReportSnapshots.sql) and the storage exist.
    /// Each lab additionally opts in with <c>"MasterDataSnapshotEnabled": true</c> in its
    /// MasterFileProcessor:Labs entry.
    /// </summary>
    public bool Enabled { get; set; }

    /// <summary>Which tables are snapshotted. All three on by default.</summary>
    public bool IncludeLineLevel { get; set; } = true;
    public bool IncludeClaimLevel { get; set; } = true;
    public bool IncludeLims { get; set; } = true;

    /// <summary>
    /// "Blob" (Azure Blob Storage, the production target) or "LocalFolder" (a disk or file share,
    /// for development and for servers without a storage account yet).
    /// </summary>
    public string Storage { get; set; } = SnapshotStorageKinds.Blob;

    /// <summary>
    /// Blob endpoint, e.g. https://stlrnwebappfiles.blob.core.windows.net. Only from the Key Vault
    /// secret <c>MasterDataSnapshot--BlobServiceUri</c> (not in appsettings.json). Authenticates with
    /// the service's managed identity (DefaultAzureCredential), which needs "Storage Blob Data
    /// Contributor" on the container - never an account key, SAS or connection string.
    /// </summary>
    public string BlobServiceUri { get; set; } = string.Empty;

    /// <summary>
    /// Private container; never public access. Only from the Key Vault secret
    /// <c>MasterDataSnapshot--ContainerName</c>.
    /// </summary>
    public string ContainerName { get; set; } = string.Empty;

    /// <summary>Root folder when <see cref="Storage"/> is LocalFolder. Relative paths resolve against the service directory.</summary>
    public string LocalFolder { get; set; } = "Snapshots";

    /// <summary>
    /// Where each Parquet file is written before upload. Empty = %TEMP%\LRN-Snapshots. Every file is
    /// deleted once uploaded; a large lab's Line Level needs this much free space for one file.
    /// </summary>
    public string WorkFolder { get; set; } = string.Empty;

    /// <summary>
    /// How many week folders to keep per lab, counting the run just written. The latest successful
    /// run of each week is kept; older runs of the same week (superseded by a re-run) and anything
    /// past this count are deleted - blobs first, then their LRNMaster rows. Minimum 1.
    /// </summary>
    public int KeepWeeks { get; set; } = 5;

    /// <summary>
    /// Additionally keep the last run of each of this many most recent months, even once it falls
    /// outside <see cref="KeepWeeks"/>. 0 = weekly retention only.
    /// </summary>
    public int KeepMonthEnd { get; set; }

    /// <summary>Rows per Parquet row group. Memory use grows with this times the column count.</summary>
    public int RowGroupSize { get; set; } = 100_000;

    /// <summary>"Snappy" (fast, default) or "Zstd" (smaller files, more CPU).</summary>
    public string Compression { get; set; } = "Snappy";

    /// <summary>Timeout for the SELECT that streams one table into its file.</summary>
    public int CommandTimeoutSeconds { get; set; } = 3600;

    /// <summary>
    /// Recorded on every dbo.ReportSnapshotFile row. Bump it when the snapshot layout itself
    /// changes, so readers can tell old files from new; old snapshots are never rewritten.
    /// </summary>
    public int SchemaVersion { get; set; } = 1;
}

public static class SnapshotStorageKinds
{
    public const string Blob = "Blob";
    public const string LocalFolder = "LocalFolder";
}

/// <summary>ReportSnapshotFile.ReportCode for the three master datasets.</summary>
public static class MasterDataReportCodes
{
    public const string LineLevel = "LINELEVEL";
    public const string ClaimLevel = "CLAIMLEVEL";
    public const string Lims = "LIMS";

    /// <summary>One result set per master table.</summary>
    public const string ResultSetName = "Data";
}
