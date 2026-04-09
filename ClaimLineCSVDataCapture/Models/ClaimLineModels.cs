namespace ClaimLineCSVDataCapture.Models;

/// <summary>
/// Generic data row driven by the field mapping configuration.
/// Replaces hardcoded ClaimLevelRow/LineLevelRow — fields are stored as key-value pairs
/// keyed by SQL column name so adding/removing CSV columns requires only a JSON change.
/// </summary>
public sealed class CsvDataRow
{
    /// <summary>System fields injected by the application (not from CSV).</summary>
    public string FileLogId { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public string WeekFolder { get; set; } = string.Empty;
    public string SourceFullPath { get; set; } = string.Empty;
    public string FileName { get; set; } = string.Empty;
    public string FileType { get; set; } = string.Empty;
    public string RowHash { get; set; } = string.Empty;

    /// <summary>
    /// CSV-sourced field values keyed by SQL column name.
    /// Only fields listed in FieldMappings.json are captured;
    /// extra CSV columns (e.g., 200+ but only 150 configured) are ignored.
    /// </summary>
    public Dictionary<string, string> Fields { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Gets a field value by SQL column name, returning empty string if not present.</summary>
    public string Get(string sqlColumn) =>
        Fields.TryGetValue(sqlColumn, out var val) ? val : string.Empty;
}
