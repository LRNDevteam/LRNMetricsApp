namespace LRN.AveragesImport.Core.Configuration;

public sealed class ImportSettings
{
    public const string SectionName = "ImportSettings";

    public string BasePath { get; set; } = @"C:\LRN-Files\Automation\LRN-Output\Averages";
    public int IntervalMinutes { get; set; } = 60;
    public string StoredProcedure { get; set; } = "sp_GetRecentSuccessRunByLab";
    public int MaxBadRowsPerFile { get; set; } = 50;
    public int BulkCopyBatchSize { get; set; } = 5000;
    public List<LabMapping> Labs { get; set; } = new();
}

/// <summary>
/// Bridges the stored procedure's lab name (e.g. "Augustus Labs") to the numeric
/// LabId written to SQL and the folder/filename segment used on disk (e.g. "Augustus").
/// </summary>
public sealed class LabMapping
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string FolderName { get; set; } = string.Empty;
}
