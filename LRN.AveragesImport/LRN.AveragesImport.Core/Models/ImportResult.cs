namespace LRN.AveragesImport.Core.Models;

public enum ImportStatus
{
    Imported,
    SkippedAlreadyImported,
    FileNotFound,
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
    public int BadRows { get; init; }
    public string? FileName { get; init; }
    public string? Error { get; init; }
}
