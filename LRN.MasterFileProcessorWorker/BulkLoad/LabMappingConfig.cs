namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// One file in <c>Schemas/LabMappings/</c>.
/// <para>
/// The existing shape (SqlTableName / TvpTypeName / SprocName / FileTypeKey / Fields) is kept as-is;
/// this type only ADDS the identity block and the per-level toggles. Every added property has a
/// default that reproduces today's behaviour, so an untouched lab JSON keeps working after deploy.
/// </para>
/// </summary>
public sealed class LabMappingConfig
{
    /// <summary>Set by the loader from the file name; not stored in the JSON.</summary>
    public string SourceFile { get; set; } = "";

    /// <summary>
    /// Joins this mapping to <c>LRNMaster.dbo.Labs</c>, which is the authoritative lab list.
    /// Optional in the JSON: when absent the loader falls back to matching <see cref="LabName"/>,
    /// then the file name, against dbo.Labs.
    /// </summary>
    public int? LabId { get; set; }

    public string? LabName { get; set; }

    /// <summary>
    /// Informational - the real connection comes from dbo.Labs.ConnectionKey. Used only to make
    /// the generated DDL folder name obvious and to sanity-check the resolved connection.
    /// </summary>
    public string? DatabaseName { get; set; }

    public LevelMapping? LineLevel { get; set; }
    public LevelMapping? ClaimLevel { get; set; }

    public LevelMapping? ForLevel(string fileType) =>
        string.Equals(fileType, FileTypes.LineLevel, StringComparison.OrdinalIgnoreCase)
            ? LineLevel
            : ClaimLevel;
}

/// <summary>Table + field mapping and the load toggles for one level of one lab.</summary>
public sealed class LevelMapping
{
    // ----- existing keys, unchanged -----
    public string SqlTableName { get; set; } = "";
    public string? TvpTypeName { get; set; }
    public string? SprocName { get; set; }
    public string? FileTypeKey { get; set; }
    public List<FieldMapping> Fields { get; set; } = new();

    // ----- added toggles (Phase 1). Defaults preserve current behaviour. -----

    /// <summary>Master switch. False skips the level end to end (logged, never silent).</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Publish the standardized CSV for this level to the output folder.
    /// <para>
    /// This does NOT affect the SQL load. The file is always produced in the staging folder and the
    /// loader reads it from there, so turning this off means "no file on disk", never "no data".
    /// Prefer the appsettings keys MasterFileProcessor:CreateLineLevelCsv / CreateClaimLevelCsv,
    /// which take precedence over this.
    /// </para>
    /// </summary>
    public bool CreateCsv { get; set; } = true;

    /// <summary>
    /// Bulk copy the CSV into <see cref="SqlTableName"/>. Off by default so that deploying this
    /// change does not start writing to lab databases until a lab is explicitly opted in.
    /// </summary>
    public bool BulkCopyToTable { get; set; }

    public bool TruncateBeforeLoad { get; set; } = true;

    public int BatchSize { get; set; } = 10000;

    /// <summary>Seconds. Deliberately not 0 (infinite) - a hung load must fail, not block the run.</summary>
    public int BulkCopyTimeoutSeconds { get; set; } = 900;

    /// <summary>
    /// Write every CSV column this mapping does not claim into the <c>AdditionalFields</c> JSON
    /// column, instead of dropping it.
    /// <para>
    /// On by default, but it only takes effect where the destination table actually has the column,
    /// so nothing changes for a database that has not run
    /// <c>sql/Labs/_Common/03_AdditionalFields.sql</c>. Set false for a lab that must keep its rows
    /// strictly to the mapped columns.
    /// </para>
    /// </summary>
    public bool CaptureAdditionalFields { get; set; } = true;


}

/// <summary>One CSV column to one SQL column.</summary>
public sealed class FieldMapping
{
    public string CsvHeader { get; set; } = "";
    public string SqlColumn { get; set; } = "";

    /// <summary>
    /// Participates in <see cref="RowHasher"/>. This is the repo's pre-existing hash convention and
    /// is reused rather than replaced.
    /// </summary>
    public bool IncludeInHash { get; set; }
}
