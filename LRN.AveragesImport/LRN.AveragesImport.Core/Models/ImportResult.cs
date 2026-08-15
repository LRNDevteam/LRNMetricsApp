namespace LRN.AveragesImport.Core.Models;

public enum ImportStatus
{
    Imported,
    SkippedAlreadyImported,
    NoSourceData,
    Failed
}

public sealed class ImportResult
{
    public required string RunId { get; init; }
    public required int LabId { get; init; }
    public required string LabName { get; init; }
    public required string FileType { get; init; }
    public required ImportStatus Status { get; init; }
    public int RowsImported { get; init; }

    /// <summary>Source the aggregate was computed from, e.g. "CoveLRN.dbo.LineLevelData".</summary>
    public string? Source { get; init; }

    public string? Error { get; init; }
}
