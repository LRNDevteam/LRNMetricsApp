using System.Data;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// The audit column block that is stamped onto every line-level and claim-level row, for every lab.
/// <para>
/// This is the ONE definition. The DDL generator, the bulk-copy reader and the column-mapping
/// validator all read from here, so names, types and order can only change in a single place.
/// </para>
/// <para>
/// Column order matches <c>ClaimLevelLineLevel_Fields.xlsx</c> rows 4-12 (immediately after the
/// <c>RecordId</c> identity), so the generated tables line up with the authoritative spreadsheet.
/// </para>
/// </summary>
public static class AuditColumns
{
    public const string FileLogId = "FileLogId";
    public const string RunId = "RunId";
    public const string WeekFolder = "WeekFolder";
    public const string SourceFullPath = "SourceFullPath";
    public const string FileName = "FileName";
    public const string FileType = "FileType";
    public const string RowHash = "RowHash";
    public const string LabId = "LabID";
    public const string LabName = "LabName";

    /// <summary>Identity surrogate key. Not part of the stamped block - the server assigns it.</summary>
    public const string RecordId = "RecordId";

    /// <summary>Server-defaulted load timestamp. Not stamped by the loader and never hashed.</summary>
    public const string InsertedDateTime = "InsertedDateTime";

    /// <summary>
    /// JSON catch-all for CSV columns the lab mapping does not claim.
    /// <para>
    /// Not part of the stamped block and never hashed: it is built per row from whatever headers the
    /// file carried beyond the mapping, so a lab adding columns no longer needs an ALTER TABLE. Only
    /// written when the destination table actually has the column - see
    /// <c>sql/Labs/_Common/03_AdditionalFields.sql</c>.
    /// </para>
    /// </summary>
    public const string AdditionalFields = "AdditionalFields";

    /// <summary>
    /// Marker column the multi-sheet export stamps onto every row, naming the sheet the row came
    /// from (e.g. NorthWest "Webpm" vs "Daq").
    /// <para>
    /// Unlike the audit block this IS a normal mapped column - labs store it and hash it. What
    /// makes it special is that the exporter writes it on every line it emits, so its presence
    /// says nothing about whether the row carries data. A blank sheet row stamped with a Source
    /// value must still count as empty, or it loads as an all-NULL record.
    /// </para>
    /// </summary>
    public const string SourceStamp = "Source";

    /// <summary>
    /// True for a column whose value never indicates that a row has data. See
    /// <see cref="SourceStamp"/>.
    /// </summary>
    public static bool IsExportStamp(string? columnName) =>
        !string.IsNullOrWhiteSpace(columnName) &&
        string.Equals(columnName.Trim(), SourceStamp, StringComparison.OrdinalIgnoreCase);

    public sealed record AuditColumn(string Name, string SqlType, bool Nullable, Type ClrType);

    /// <summary>
    /// The nine audit columns in fixed order.
    /// <para>
    /// TYPES ARE PROVISIONAL until <c>dbo.LineClaimFileLogs</c> can be read - see
    /// TypeReconciliation.md, item A1. <c>RunId</c> is sized to match
    /// <c>dbo.LRN_Run_Log.RunID varchar(30)</c> from sql/Create_ProcessLogs.sql, which is the only
    /// authoritative RunId type currently in the repo.
    /// </para>
    /// </summary>
    public static readonly IReadOnlyList<AuditColumn> All = new[]
    {
        new AuditColumn(FileLogId,      "BIGINT",          false, typeof(long)),
        new AuditColumn(RunId,          "VARCHAR(30)",     false, typeof(string)),
        new AuditColumn(WeekFolder,     "NVARCHAR(200)",   true,  typeof(string)),
        new AuditColumn(SourceFullPath, "NVARCHAR(1000)",  true,  typeof(string)),
        new AuditColumn(FileName,       "NVARCHAR(400)",   true,  typeof(string)),
        new AuditColumn(FileType,       "VARCHAR(20)",     false, typeof(string)),
        new AuditColumn(RowHash,        "CHAR(64)",        false, typeof(string)),
        new AuditColumn(LabId,          "INT",             false, typeof(int)),
        new AuditColumn(LabName,        "NVARCHAR(200)",   false, typeof(string))
    };

    public static readonly IReadOnlyList<string> Names = All.Select(c => c.Name).ToList();

    private static readonly HashSet<string> NameSet =
        new(Names, StringComparer.OrdinalIgnoreCase)
        {
            RecordId,
            InsertedDateTime,
            AdditionalFields
        };

    /// <summary>
    /// True for columns the pipeline or the server owns. These must never appear in a lab mapping's
    /// Fields list and must never contribute to <see cref="RowHasher"/>.
    /// </summary>
    public static bool IsPipelineOwned(string? columnName) =>
        !string.IsNullOrWhiteSpace(columnName) && NameSet.Contains(columnName.Trim());

    /// <summary>The values stamped onto every row of one file's load.</summary>
    public sealed record AuditValues(
        long FileLogId,
        string RunId,
        string? WeekFolder,
        string? SourceFullPath,
        string? FileName,
        string FileType,
        int LabId,
        string LabName);

    /// <summary>Adds the audit columns to a DataTable in canonical order.</summary>
    public static void AddTo(DataTable table)
    {
        foreach (var column in All)
            table.Columns.Add(column.Name, column.ClrType);
    }
}

/// <summary>Canonical FileType values. Must match <c>dbo.LineClaimFileLogs.FileType</c>.</summary>
public static class FileTypes
{
    public const string LineLevel = "Line Level";
    public const string ClaimLevel = "Claim Level";
}
