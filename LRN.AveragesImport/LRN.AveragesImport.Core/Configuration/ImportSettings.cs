namespace LRN.AveragesImport.Core.Configuration;

public sealed class ImportSettings
{
    public const string SectionName = "ImportSettings";

    public int IntervalMinutes { get; set; } = 60;
    public string StoredProcedure { get; set; } = "sp_GetRecentSuccessRunByLab";
    public int BulkCopyBatchSize { get; set; } = 5000;

    /// <summary>
    /// Seconds allowed for one aggregation query against a lab database. The v1.1
    /// window rules fan each source row out across up to 3 windows × 2 bases, so a
    /// 1.2M-row LineLevelData sorts several million rows; ~90s measured on the
    /// largest lab, with headroom here for the slower SQLEXPRESS instances.
    /// </summary>
    public int AggregateCommandTimeoutSeconds { get; set; } = 1800;

    public List<LabMapping> Labs { get; set; } = new();
}

/// <summary>
/// Bridges the stored procedure's lab name (e.g. "Augustus Labs") to the numeric
/// LabId written to LRNMaster and the lab's own database, which holds the
/// LineLevelData the averages are aggregated from.
/// </summary>
public sealed class LabMapping
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;

    /// <summary>
    /// Connection string for the lab's source database (the one containing
    /// dbo.LineLevelData). A lab with no connection string is skipped.
    /// </summary>
    public string ConnectionString { get; set; } = string.Empty;
}
