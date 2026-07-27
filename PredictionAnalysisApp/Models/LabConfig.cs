namespace PredictionAnalysis.Models;

/// <summary>
/// Per-lab runtime configuration loaded from {LabConfigFolder}\{LabName}.json.
/// </summary>
public sealed class LabConfig
{
    public string LabName { get; set; } = string.Empty;

    public string InputFolderPath { get; set; } = string.Empty;

    public string ProcessingFolderPath { get; set; } = string.Empty;

    public string OutputFolderPath { get; set; } = string.Empty;

    public bool EnableDatabaseInsert { get; set; }

    /// <summary>Connection string for this lab's LRN database (e.g. CoveLRN).</summary>
    public string? DbConnectionString { get; set; }

    /// <summary>
    /// Connection string for LRNMaster � used to look up
    /// <c>DenialMapperSuperMaster.DenialDescription</c> when enriching denial aggregates.
    /// </summary>
    public string? MasterDbConnectionString { get; set; }

    public int DbInsertChunkSize { get; set; } = 25_000;

    /// <summary>
    /// Optional override for ReportId window size used by chunked aggregate refresh.
    /// 0 = auto: when PayerValidationReport rows for the run are &gt;=
    /// <see cref="DbAggregateLargeLabRowThreshold"/> (default 7 lakh), use 100000.
    /// Chunking never changes COUNT(DISTINCT VisitNumber) / SUM results.
    /// </summary>
    public int DbAggregateChunkSize { get; set; }

    /// <summary>
    /// Optional CommandTimeout (seconds) for aggregate refresh.
    /// 0 = auto: 3600s when row count &gt;= large-lab threshold, else 600s.
    /// </summary>
    public int DbAggregateRefreshTimeoutSeconds { get; set; }

    /// <summary>
    /// Row-count threshold for auto chunk + long timeout (any lab, not only NorthWest).
    /// Default 700000 (7 lakh).
    /// </summary>
    public int DbAggregateLargeLabRowThreshold { get; set; } = 700_000;

    /// <summary>
    /// Forces the aggregate step to run for the newest RunId even if its
    /// PayerValidationFileLog.FileStatus is not 3. The app resets this to false
    /// after a successful aggregate run.
    /// </summary>
    public bool DataRefresh { get; set; }

    public string? LastProcessedFile { get; set; }

    public string? LastProcessedRelativePath { get; set; }

    public string? LastOutputFilePath { get; set; }
}
