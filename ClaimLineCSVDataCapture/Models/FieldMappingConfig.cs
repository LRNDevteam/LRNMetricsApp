using System.Text.Json.Serialization;

namespace ClaimLineCSVDataCapture.Models;

/// <summary>
/// Root config for CSV-to-SQL field mappings.
/// Loaded from FieldMappings.json at startup.
/// </summary>
public sealed class FieldMappingsRoot
{
    [JsonPropertyName("ClaimLevel")]
    public FileTypeMapping ClaimLevel { get; set; } = new();

    [JsonPropertyName("LineLevel")]
    public FileTypeMapping LineLevel { get; set; } = new();
}

/// <summary>
/// Mapping configuration for a single file type (Claim Level or Line Level).
/// Contains the SQL table/TVP/SP names and the list of field mappings.
/// </summary>
public sealed class FileTypeMapping
{
    /// <summary>Target SQL table name (e.g., "dbo.ClaimLevelData").</summary>
    public string SqlTableName { get; set; } = string.Empty;

    /// <summary>SQL TVP type name (e.g., "dbo.ClaimLevelDataTVP").</summary>
    public string TvpTypeName { get; set; } = string.Empty;

    /// <summary>Stored procedure name (e.g., "dbo.usp_BulkInsertClaimLevelData").</summary>
    public string SprocName { get; set; } = string.Empty;

    /// <summary>File type identifier stored in DB (e.g., "claimlevel").</summary>
    public string FileTypeKey { get; set; } = string.Empty;

    /// <summary>Ordered list of field mappings from CSV header to SQL column.</summary>
    public List<FieldMapping> Fields { get; set; } = [];
}

/// <summary>
/// A single CSV header ? SQL column mapping.
/// </summary>
public sealed class FieldMapping
{
    /// <summary>Column header name in the CSV file (case-insensitive match).</summary>
    public string CsvHeader { get; set; } = string.Empty;

    /// <summary>Target column name in the SQL table/TVP.</summary>
    public string SqlColumn { get; set; } = string.Empty;

    /// <summary>Whether this field's value is included in the RowHash for change detection.</summary>
    public bool IncludeInHash { get; set; } = true;

    /// <summary>
    /// Optional data type hint (e.g., "integer") used to clean CSV values
    /// that arrive with spurious decimal suffixes like ".00".
    /// </summary>
    public string? DataType { get; set; }
}
