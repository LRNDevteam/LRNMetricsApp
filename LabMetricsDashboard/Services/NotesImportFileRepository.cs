using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>One stored Key Insights import workbook (the file itself is read separately).</summary>
public sealed class NotesImportFileInfo
{
    public int      ImportFileId     { get; set; }
    public string   ReportName       { get; set; } = string.Empty;
    public string   FileName         { get; set; } = string.Empty;
    public long     FileSize         { get; set; }
    public string?  WeekRangeText    { get; set; }
    public string   ImportMode       { get; set; } = "Append";
    public int      RowsImported     { get; set; }
    public int      RowsReplaced     { get; set; }
    public string   ImportedBy       { get; set; } = string.Empty;
    public DateTime ImportedDateTime { get; set; }
}

public sealed record NotesImportFileContent(string FileName, string ContentType, byte[] Content);

/// <summary>
/// The Key Insights workbooks imported on the LIS, Production and Collection reports, kept in the
/// lab database (dbo.NotesImportFile) so each import can be downloaded again exactly as it was sent.
/// </summary>
public interface INotesImportFileRepository
{
    Task<int> SaveAsync(string connectionString, string reportName, string fileName, string? contentType, byte[] content,
        string? weekRangeText, DateTime? weekRangeStart, string? reportRunId, string importMode,
        int rowsImported, int rowsReplaced, string importedBy, CancellationToken ct);

    /// <summary>The report's imports, newest first.</summary>
    Task<IReadOnlyList<NotesImportFileInfo>> ListAsync(string connectionString, string reportName, int top, CancellationToken ct);

    Task<NotesImportFileContent?> GetAsync(string connectionString, int importFileId, CancellationToken ct);
}

public sealed class SqlNotesImportFileRepository : INotesImportFileRepository
{
    // Same as Database/Shared/NotesInsights/13_NotesImportFile.sql, so the app works whether or not it has been run.
    private const string EnsureTableSql = """
        IF OBJECT_ID('dbo.NotesImportFile', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.NotesImportFile
            (
                ImportFileId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_NotesImportFile PRIMARY KEY,
                ReportName       NVARCHAR(200)  NOT NULL,
                FileName         NVARCHAR(260)  NOT NULL,
                ContentType      NVARCHAR(150)  NULL,
                FileSize         BIGINT         NOT NULL,
                FileContent      VARBINARY(MAX) NOT NULL,
                WeekRangeText    NVARCHAR(100)  NULL,
                WeekRangeStart   DATE           NULL,
                ReportRunId      NVARCHAR(100)  NULL,
                ImportMode       NVARCHAR(20)   NOT NULL CONSTRAINT DF_NotesImportFile_Mode DEFAULT 'Append',
                RowsImported     INT            NOT NULL CONSTRAINT DF_NotesImportFile_Rows DEFAULT 0,
                RowsReplaced     INT            NOT NULL CONSTRAINT DF_NotesImportFile_Replaced DEFAULT 0,
                ImportedBy       NVARCHAR(256)  NOT NULL,
                ImportedDateTime DATETIME2(0)   NOT NULL CONSTRAINT DF_NotesImportFile_At DEFAULT GETDATE()
            );
            CREATE INDEX IX_NotesImportFile_Report_At ON dbo.NotesImportFile (ReportName, ImportedDateTime DESC);
        END
        """;

    private static async Task<SqlConnection> OpenAsync(string connectionString, CancellationToken ct)
    {
        var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(EnsureTableSql, conn) { CommandTimeout = 60 };
        await cmd.ExecuteNonQueryAsync(ct);
        return conn;
    }

    public async Task<int> SaveAsync(string connectionString, string reportName, string fileName, string? contentType, byte[] content,
        string? weekRangeText, DateTime? weekRangeStart, string? reportRunId, string importMode,
        int rowsImported, int rowsReplaced, string importedBy, CancellationToken ct)
    {
        await using var conn = await OpenAsync(connectionString, ct);
        const string sql = """
            INSERT INTO dbo.NotesImportFile
                (ReportName, FileName, ContentType, FileSize, FileContent, WeekRangeText, WeekRangeStart,
                 ReportRunId, ImportMode, RowsImported, RowsReplaced, ImportedBy)
            OUTPUT INSERTED.ImportFileId
            VALUES (@ReportName, @FileName, @ContentType, @FileSize, @FileContent, @WeekRangeText, @WeekRangeStart,
                    @ReportRunId, @ImportMode, @RowsImported, @RowsReplaced, @ImportedBy);
            """;
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@ReportName", reportName);
        cmd.Parameters.AddWithValue("@FileName", Truncate(fileName, 260));
        cmd.Parameters.AddWithValue("@ContentType", (object?)Truncate(contentType, 150) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FileSize", (long)content.Length);
        cmd.Parameters.Add("@FileContent", System.Data.SqlDbType.VarBinary, -1).Value = content;
        cmd.Parameters.AddWithValue("@WeekRangeText", (object?)Truncate(weekRangeText, 100) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@WeekRangeStart", (object?)weekRangeStart?.Date ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ReportRunId", (object?)Truncate(reportRunId, 100) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ImportMode", importMode);
        cmd.Parameters.AddWithValue("@RowsImported", rowsImported);
        cmd.Parameters.AddWithValue("@RowsReplaced", rowsReplaced);
        cmd.Parameters.AddWithValue("@ImportedBy", Truncate(importedBy, 256)!);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    public async Task<IReadOnlyList<NotesImportFileInfo>> ListAsync(string connectionString, string reportName, int top, CancellationToken ct)
    {
        await using var conn = await OpenAsync(connectionString, ct);
        const string sql = """
            SELECT TOP (@Top) ImportFileId, ReportName, FileName, FileSize, WeekRangeText, ImportMode,
                   RowsImported, RowsReplaced, ImportedBy, ImportedDateTime
            FROM dbo.NotesImportFile
            WHERE ReportName = @ReportName
            ORDER BY ImportedDateTime DESC, ImportFileId DESC;
            """;
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@Top", top);
        cmd.Parameters.AddWithValue("@ReportName", reportName);
        var list = new List<NotesImportFileInfo>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new NotesImportFileInfo
            {
                ImportFileId = r.GetInt32(0),
                ReportName = r.GetString(1),
                FileName = r.GetString(2),
                FileSize = r.GetInt64(3),
                WeekRangeText = r.IsDBNull(4) ? null : r.GetString(4),
                ImportMode = r.GetString(5),
                RowsImported = r.GetInt32(6),
                RowsReplaced = r.GetInt32(7),
                ImportedBy = r.GetString(8),
                ImportedDateTime = r.GetDateTime(9)
            });
        }
        return list;
    }

    public async Task<NotesImportFileContent?> GetAsync(string connectionString, int importFileId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(connectionString, ct);
        const string sql = "SELECT FileName, ContentType, FileContent FROM dbo.NotesImportFile WHERE ImportFileId = @Id;";
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@Id", importFileId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new NotesImportFileContent(
            r.GetString(0),
            r.IsDBNull(1) ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : r.GetString(1),
            (byte[])r[2]);
    }

    private static string? Truncate(string? s, int max) => s is null ? null : s.Length <= max ? s : s[..max];
}
