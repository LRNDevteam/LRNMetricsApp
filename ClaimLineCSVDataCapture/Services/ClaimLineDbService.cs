using System.Data;
using Microsoft.Data.SqlClient;
using ClaimLineCSVDataCapture.Models;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Persists CSV data to SQL Server using TVP bulk insert.
/// Fully driven by <see cref="FileTypeMapping"/> — no hardcoded column lists.
/// Adding/removing fields only requires a FieldMappings.json change
/// (plus matching SQL TVP/table/SP updates).
/// </summary>
public sealed class ClaimLineDbService
{
    private readonly string _connectionString;

    public ClaimLineDbService(string connectionString)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        _connectionString = connectionString;
    }

    /// <summary>
    /// Returns the latest <c>SourceFullPath</c> from <c>LineClaimFileLogs</c>
    /// for the given lab and file type, or null if no rows exist.
    /// </summary>
    public string? GetLatestSourcePath(string labName, string fileType)
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var cmd = new SqlCommand(
            """
            SELECT TOP 1 SourceFullPath
            FROM   dbo.LineClaimFileLogs
            WHERE  LabName = @LabName AND FileType = @FileType
            ORDER  BY InsertedDateTime DESC
            """, conn);
        cmd.Parameters.AddWithValue("@LabName", labName);
        cmd.Parameters.AddWithValue("@FileType", fileType);
        var result = cmd.ExecuteScalar();
        return result is DBNull or null ? null : (string)result;
    }

    /// <summary>
    /// Bulk-inserts rows via the stored procedure specified in the mapping.
    /// Builds the TVP dynamically from the field mapping configuration.
    /// Returns the number of rows inserted (0 = skipped/already loaded).
    /// </summary>
    public int InsertRows(List<CsvDataRow> rows, string labName, string weekFolder, FileTypeMapping mapping)
    {
        if (rows.Count == 0) return 0;
        ArgumentNullException.ThrowIfNull(mapping);

        var sourceFilePath = rows[0].SourceFullPath;
        var runId          = ExtractRunId(sourceFilePath);
        var fileName       = Path.GetFileName(sourceFilePath);
        var fileCreated    = File.Exists(sourceFilePath)
                             ? (object)File.GetCreationTime(sourceFilePath)
                             : DBNull.Value;

        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        using var cmd = new SqlCommand(mapping.SprocName, conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 1200
        };

        var tvp = BuildTvp(rows, mapping);
        cmd.Parameters.Add(new SqlParameter("@Rows", SqlDbType.Structured)
        {
            TypeName = mapping.TvpTypeName,
            Value    = tvp,
        });
        cmd.Parameters.AddWithValue("@LabName",        labName);
        cmd.Parameters.AddWithValue("@WeekFolder",     weekFolder);
        cmd.Parameters.AddWithValue("@SourceFilePath", sourceFilePath);
        cmd.Parameters.AddWithValue("@RunId",          runId);
        cmd.Parameters.AddWithValue("@FileName",       fileName);
        cmd.Parameters.Add(new SqlParameter("@FileCreatedDateTime", SqlDbType.DateTime)
        {
            Value = fileCreated
        });

        var result = cmd.ExecuteScalar();
        return result is int count ? count : 0;
    }

    /// <summary>
    /// Builds a DataTable matching the TVP structure dynamically from the field mapping.
    /// System columns (FileLogId, RunId, WeekFolder, etc.) are added first,
    /// then all configured CSV?SQL field mappings in order.
    /// </summary>
    private static DataTable BuildTvp(List<CsvDataRow> rows, FileTypeMapping mapping)
    {
        var dt = new DataTable();

        // System columns (always present in every TVP)
        dt.Columns.Add("FileLogId");
        dt.Columns.Add("RunId");
        dt.Columns.Add("WeekFolder");
        dt.Columns.Add("SourceFullPath");
        dt.Columns.Add("FileName");
        dt.Columns.Add("FileType");
        dt.Columns.Add("RowHash");

        // Dynamic columns from field mapping (order must match TVP definition)
        foreach (var fm in mapping.Fields)
        {
            dt.Columns.Add(fm.SqlColumn);
        }

        foreach (var r in rows)
        {
            var values = new object[7 + mapping.Fields.Count];
            values[0] = r.FileLogId;
            values[1] = r.RunId;
            values[2] = r.WeekFolder;
            values[3] = r.SourceFullPath;
            values[4] = r.FileName;
            values[5] = r.FileType;
            values[6] = r.RowHash;

            for (int i = 0; i < mapping.Fields.Count; i++)
            {
                values[7 + i] = r.Get(mapping.Fields[i].SqlColumn);
            }

            dt.Rows.Add(values);
        }

        return dt;
    }

    /// <summary>
    /// Extracts RunId from a file path by taking the prefix before the first underscore
    /// in the filename (e.g., "20260226R0029_Cove_Claim Level_...csv" ? "20260226R0029").
    /// Falls back to the full filename without extension if no underscore is found or on error.
    /// </summary>
    internal static string ExtractRunId(string filePath)
    {
        var fileNameWithoutExt = Path.GetFileNameWithoutExtension(filePath);
        if (string.IsNullOrWhiteSpace(fileNameWithoutExt))
            return fileNameWithoutExt ?? string.Empty;

        var underscoreIndex = fileNameWithoutExt.IndexOf('_');
        return underscoreIndex > 0
            ? fileNameWithoutExt[..underscoreIndex]
            : fileNameWithoutExt;
    }
}
