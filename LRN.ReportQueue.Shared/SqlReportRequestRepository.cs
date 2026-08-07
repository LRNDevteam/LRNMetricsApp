using System.Collections.Concurrent;
using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace LRN.ReportQueue.Shared;

/// <summary>ADO.NET implementation over the UserReqReports objects deployed per lab DB.</summary>
public sealed class SqlReportRequestRepository : IReportRequestRepository
{
    /// <summary>
    /// Per-DB cache: whether dbo.UserReqReports.ProgressPercent exists.
    /// Avoids throwing SqlException 207 on every My Reports / badge poll when a lab
    /// has not yet run the ProgressPercent migration.
    /// </summary>
    private static readonly ConcurrentDictionary<string, bool> ProgressColumnCache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Per-DB cache: whether dbo.UserReqReports itself exists.
    /// COL_LENGTH returns NULL when the table is missing (no exception), so without this
    /// every badge poll re-queries and throws SqlException 208 — flooding the VS debugger
    /// Output window and often looking like the app "closed" while debugging.
    /// </summary>
    private static readonly ConcurrentDictionary<string, bool> TableExistsCache = new(StringComparer.OrdinalIgnoreCase);

    private readonly ILogger<SqlReportRequestRepository> _logger;

    public SqlReportRequestRepository(ILogger<SqlReportRequestRepository> logger)
        => _logger = logger;

    // ── Queue (web) ────────────────────────────────────────────────────────────

    public async Task<long> QueueAsync(string connectionString, NewReportRequest request, CancellationToken ct = default)
    {
        // OUTPUT ... INTO — the audit trigger on UserReqReports forbids bare OUTPUT (SQL error 334).
        const string sql = """
            EXEC sp_set_session_context @key = N'AppUser', @value = @RequestedBy;
            DECLARE @new TABLE (ReportId BIGINT);
            INSERT dbo.UserReqReports
                (ReportType, LabName, RequestedBy, RequestedByUserId, FilterDetails, FilterHash)
            OUTPUT inserted.ReportId INTO @new
            VALUES (@ReportType, @LabName, @RequestedBy, @RequestedByUserId, @FilterDetails, @FilterHash);
            SELECT ReportId FROM @new;
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
        cmd.Parameters.AddWithValue("@ReportType",        request.ReportType);
        cmd.Parameters.AddWithValue("@LabName",           request.LabName);
        cmd.Parameters.AddWithValue("@RequestedBy",       request.RequestedBy);
        cmd.Parameters.AddWithValue("@RequestedByUserId", (object?)request.RequestedByUserId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterDetails",     (object?)request.FilterDetailsJson ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterHash",        request.ComputeFilterHash());

        try
        {
            var id = (long)(await cmd.ExecuteScalarAsync(ct))!;
            _logger.LogInformation("Queued report {ReportId} ({Type}) for {User} on {Lab}.",
                id, request.ReportType, request.RequestedBy, request.LabName);
            return id;
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627) // unique index violation
        {
            throw new DuplicateReportRequestException();
        }
    }

    // ── Worker lifecycle ───────────────────────────────────────────────────────

    public async Task<ClaimedReport?> ClaimNextAsync(string connectionString, string workerName, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = StoredProc(conn, "dbo.usp_ClaimNextUserReqReport", 30);
        cmd.Parameters.AddWithValue("@WorkerName", workerName);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return null;

        return new ClaimedReport(
            ReportId:          reader.GetInt64(0),
            ReportType:        reader.GetString(1),
            LabName:           reader.GetString(2),
            RequestedBy:       reader.GetString(3),
            FilterDetailsJson: reader.IsDBNull(4) ? null : reader.GetString(4),
            RetryCount:        reader.GetByte(5));
    }

    public async Task CompleteAsync(string connectionString, long reportId, GeneratedReportFile file,
        int retentionDays, string workerName, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = StoredProc(conn, "dbo.usp_CompleteUserReqReport", 30);
        cmd.Parameters.AddWithValue("@ReportId",       reportId);
        cmd.Parameters.AddWithValue("@FileName",       file.FileName);
        cmd.Parameters.AddWithValue("@FilePath",       file.FilePath);
        cmd.Parameters.AddWithValue("@FileSizeBytes",  file.FileSizeBytes);
        cmd.Parameters.AddWithValue("@ReportRowCount", file.RowCount);
        cmd.Parameters.AddWithValue("@RetentionDays",  retentionDays);
        cmd.Parameters.AddWithValue("@WorkerName",     workerName);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task FailAsync(string connectionString, long reportId, string errorMessage,
        bool isTransient, byte maxRetries, string workerName, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = StoredProc(conn, "dbo.usp_FailUserReqReport", 30);
        cmd.Parameters.AddWithValue("@ReportId",     reportId);
        cmd.Parameters.AddWithValue("@ErrorMessage", errorMessage);
        cmd.Parameters.AddWithValue("@IsTransient",  isTransient);
        cmd.Parameters.AddWithValue("@MaxRetries",   maxRetries);
        cmd.Parameters.AddWithValue("@WorkerName",   workerName);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<bool> UpdateProgressAsync(string connectionString, long reportId, byte percent, CancellationToken ct = default)
    {
        if (!await HasProgressPercentAsync(connectionString, ct))
            return true; // schema not migrated — treat as cooperative continue (do not fail the job)

        const string sql = """
            UPDATE dbo.UserReqReports
               SET ProgressPercent = @Pct, UpdatedDate = SYSDATETIME()
             WHERE ReportId = @Id AND GenerationStatus = 2;
            SELECT @@ROWCOUNT;
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 10 };
            cmd.Parameters.AddWithValue("@Id",  reportId);
            cmd.Parameters.AddWithValue("@Pct", Math.Min(percent, (byte)100));
            return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0) > 0;
        }
        catch (SqlException ex) when (ex.Number == 207)
        {
            MarkProgressColumnMissing(connectionString);
            return true;
        }
    }

    public async Task<bool> CancelAsync(string connectionString, long reportId, string userName, CancellationToken ct = default)
    {
        const string sql = """
            EXEC sp_set_session_context @key = N'AppUser', @value = @User;
            UPDATE dbo.UserReqReports
               SET GenerationStatus = 8,               -- Cancelled
                   ErrorMessage     = N'Cancelled by user.',
                   UpdatedDate      = SYSDATETIME()
             WHERE ReportId = @Id
               AND RequestedBy = @User
               AND GenerationStatus IN (1, 2);         -- Queued / Processing
            SELECT @@ROWCOUNT;
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Id",   reportId);
        cmd.Parameters.AddWithValue("@User", userName.Trim());
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0) > 0;
    }

    public async Task<bool> IsStillProcessingAsync(string connectionString, long reportId, CancellationToken ct = default)
    {
        const string sql = """
            SELECT CASE WHEN EXISTS (
                SELECT 1 FROM dbo.UserReqReports
                WHERE ReportId = @Id AND GenerationStatus = 2
            ) THEN 1 ELSE 0 END;
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 10 };
        cmd.Parameters.AddWithValue("@Id", reportId);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0) == 1;
    }

    public async Task RequeueInterruptedAsync(string connectionString, long reportId, string workerName,
        CancellationToken ct = default)
    {
        const string sql = """
            EXEC sp_set_session_context @key = N'AppUser', @value = @WorkerName;
            UPDATE dbo.UserReqReports
               SET GenerationStatus = 1,
                   StartedDate      = NULL,
                   WorkerName       = NULL,
                   ErrorMessage     = N'Requeued after report worker restart.',
                   UpdatedDate      = SYSDATETIME()
             WHERE ReportId = @Id
               AND GenerationStatus = 2
               AND WorkerName = @WorkerName;
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Id", reportId);
        cmd.Parameters.AddWithValue("@WorkerName", workerName);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<int> ResetStuckAsync(string connectionString, int stuckAfterMinutes, byte maxRetries,
        string workerName, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        // On service startup, no job owned by this exact worker instance can still be
        // running. Recover those rows immediately instead of waiting StuckAfterMinutes.
        const string recoverOwnedSql = """
            EXEC sp_set_session_context @key = N'AppUser', @value = @WorkerName;
            UPDATE dbo.UserReqReports
               SET GenerationStatus = 1,
                   StartedDate      = NULL,
                   WorkerName       = NULL,
                   ErrorMessage     = N'Recovered immediately after report worker restart.',
                   UpdatedDate      = SYSDATETIME()
             WHERE GenerationStatus = 2
               AND WorkerName = @WorkerName;
            SELECT @@ROWCOUNT;
            """;
        int recoveredOwned;
        await using (var recoverCmd = new SqlCommand(recoverOwnedSql, conn) { CommandTimeout = 30 })
        {
            recoverCmd.Parameters.AddWithValue("@WorkerName", workerName);
            recoveredOwned = Convert.ToInt32(await recoverCmd.ExecuteScalarAsync(ct) ?? 0);
        }

        await using var cmd = StoredProc(conn, "dbo.usp_ResetStuckUserReqReports", 30);
        cmd.Parameters.AddWithValue("@StuckAfterMinutes", stuckAfterMinutes);
        cmd.Parameters.AddWithValue("@MaxRetries",        maxRetries);
        cmd.Parameters.AddWithValue("@WorkerName",        workerName);
        var result = await cmd.ExecuteScalarAsync(ct);
        return recoveredOwned + (result is int n ? n : 0);
    }

    public async Task<List<ExpiredReportFile>> ExpireAsync(string connectionString, string workerName, CancellationToken ct = default)
    {
        var files = new List<ExpiredReportFile>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = StoredProc(conn, "dbo.usp_ExpireUserReqReports", 60);
        cmd.Parameters.AddWithValue("@WorkerName", workerName);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            files.Add(new ExpiredReportFile(reader.GetInt64(0), reader.IsDBNull(1) ? null : reader.GetString(1)));
        return files;
    }

    public async Task PurgeAsync(string connectionString, int purgeAfterDays, int auditRetentionDays, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = StoredProc(conn, "dbo.usp_PurgeUserReqReports", 120);
        cmd.Parameters.AddWithValue("@PurgeAfterDays",     purgeAfterDays);
        cmd.Parameters.AddWithValue("@AuditRetentionDays", auditRetentionDays);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    // ── User panel / download (web) ────────────────────────────────────────────

    private const string UserRowColumns = """
        ReportId, ReportType, LabName, RequestedBy, RequestedDate, GenerationStatus,
        [FileName], FileSizeBytes, ReportRowCount, CompletedDate, ExpiryDate,
        ErrorMessage, DownloadToken, ProgressPercent
        """;

    public async Task<List<UserReportRow>> GetUserReportsAsync(string connectionString, string userName,
        int top = 20, CancellationToken ct = default)
    {
        userName = (userName ?? string.Empty).Trim();
        if (!await UserReqReportsExistsAsync(connectionString, ct))
            return [];

        var includeProgress = await HasProgressPercentAsync(connectionString, ct);
        try
        {
            return await ReadUserReportsAsync(connectionString, userName, top, includeProgress, ct);
        }
        catch (SqlException ex) when (ex.Number == 207) // Invalid column name (e.g. ProgressPercent not migrated)
        {
            MarkProgressColumnMissing(connectionString);
            _logger.LogInformation(
                "UserReqReports.ProgressPercent missing on this lab DB; using schema without progress until migration is applied.");
            return await ReadUserReportsAsync(connectionString, userName, top, includeProgress: false, ct);
        }
        catch (SqlException ex) when (ex.Number == 208) // Invalid object name — table vanished / never deployed
        {
            MarkTableMissing(connectionString);
            _logger.LogWarning(
                "dbo.UserReqReports is missing on {Db}; skipping until the UserReqReports scripts are deployed. {Message}",
                CacheKey(connectionString), ex.Message);
            return [];
        }
    }

    private static async Task<List<UserReportRow>> ReadUserReportsAsync(
        string connectionString, string userName, int top, bool includeProgress, CancellationToken ct)
    {
        var columns = includeProgress
            ? UserRowColumns
            : """
              ReportId, ReportType, LabName, RequestedBy, RequestedDate, GenerationStatus,
              [FileName], FileSizeBytes, ReportRowCount, CompletedDate, ExpiryDate,
              ErrorMessage, DownloadToken
              """;

        var sql = $"""
            SELECT TOP (@Top) {columns}
            FROM dbo.UserReqReports WITH (READPAST)
            WHERE RequestedBy = @User
              AND GenerationStatus IN (1, 2, 3, 4, 5)
            ORDER BY ReportId DESC;
            """;

        var rows = new List<UserReportRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Top",  top);
        cmd.Parameters.AddWithValue("@User", userName);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            rows.Add(MapUserRow(reader, includeProgress));
        return rows;
    }

    public async Task<UserReportRow?> GetForDownloadAsync(string connectionString, long reportId,
        string userName, Guid token, CancellationToken ct = default)
    {
        var includeProgress = await HasProgressPercentAsync(connectionString, ct);
        try
        {
            return await ReadForDownloadAsync(connectionString, reportId, userName, token, includeProgress, ct);
        }
        catch (SqlException ex) when (ex.Number == 207) // Invalid column name (e.g. ProgressPercent not migrated)
        {
            MarkProgressColumnMissing(connectionString);
            return await ReadForDownloadAsync(connectionString, reportId, userName, token, includeProgress: false, ct);
        }
    }

    private static async Task<UserReportRow?> ReadForDownloadAsync(string connectionString, long reportId,
        string userName, Guid token, bool includeProgress, CancellationToken ct)
    {
        var columns = includeProgress
            ? UserRowColumns
            : """
              ReportId, ReportType, LabName, RequestedBy, RequestedDate, GenerationStatus,
              [FileName], FileSizeBytes, ReportRowCount, CompletedDate, ExpiryDate,
              ErrorMessage, DownloadToken
              """;

        var sql = $"""
            SELECT {columns}
            FROM dbo.UserReqReports
            WHERE ReportId = @Id AND RequestedBy = @User AND DownloadToken = @Token
              AND GenerationStatus IN (3, 5);
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Id",    reportId);
        cmd.Parameters.AddWithValue("@User",  userName);
        cmd.Parameters.AddWithValue("@Token", token);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapUserRow(reader, includeProgress) : null;
    }

    /// <summary>File path for a verified download row (kept separate so UserReportRow never leaks paths to the UI).</summary>
    public async Task<string?> GetFilePathAsync(string connectionString, long reportId,
        string userName, Guid token, CancellationToken ct = default)
    {
        const string sql = """
            SELECT FilePath
            FROM dbo.UserReqReports
            WHERE ReportId = @Id AND RequestedBy = @User AND DownloadToken = @Token
              AND GenerationStatus IN (3, 5);
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Id",    reportId);
        cmd.Parameters.AddWithValue("@User",  userName);
        cmd.Parameters.AddWithValue("@Token", token);
        return await cmd.ExecuteScalarAsync(ct) as string;
    }

    public async Task<DeletedReportInfo?> MarkDeletedAsync(string connectionString, long reportId, string userName, CancellationToken ct = default)
    {
        const string sql = """
            EXEC sp_set_session_context @key = N'AppUser', @value = @User;
            DECLARE @old TABLE (FilePath NVARCHAR(1024) NULL);
            UPDATE dbo.UserReqReports
               SET GenerationStatus = 7, UpdatedDate = SYSDATETIME()
            OUTPUT deleted.FilePath INTO @old
             WHERE ReportId = @Id AND RequestedBy = @User
               AND GenerationStatus IN (3, 4, 5);
            SELECT FilePath FROM @old;
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Id",   reportId);
        cmd.Parameters.AddWithValue("@User", userName);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return null; // no row updated → not found / not owned / wrong state
        return new DeletedReportInfo(reader.IsDBNull(0) ? null : reader.GetString(0));
    }

    public async Task<bool> RetryAsync(string connectionString, long reportId, string userName, CancellationToken ct = default)
    {
        var includeProgress = await HasProgressPercentAsync(connectionString, ct);
        try
        {
            return await ExecuteRetryAsync(connectionString, reportId, userName, includeProgress, ct);
        }
        catch (SqlException ex) when (ex.Number == 207) // Invalid column name (e.g. ProgressPercent not migrated)
        {
            MarkProgressColumnMissing(connectionString);
            return await ExecuteRetryAsync(connectionString, reportId, userName, includeProgress: false, ct);
        }
    }

    private static async Task<bool> ExecuteRetryAsync(string connectionString, long reportId, string userName,
        bool includeProgress, CancellationToken ct)
    {
        var progressSet = includeProgress ? "ProgressPercent = NULL, " : "";
        var sql = $"""
            EXEC sp_set_session_context @key = N'AppUser', @value = @User;
            UPDATE dbo.UserReqReports
               SET GenerationStatus = 1, ErrorMessage = NULL, WorkerName = NULL,
                   StartedDate = NULL, {progressSet}UpdatedDate = SYSDATETIME()
             WHERE ReportId = @Id AND RequestedBy = @User AND GenerationStatus = 4;
            SELECT @@ROWCOUNT;
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Id",   reportId);
        cmd.Parameters.AddWithValue("@User", userName);
        var affected = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
        return affected > 0;
    }

    public async Task MarkDownloadedAsync(string connectionString, long reportId, CancellationToken ct = default)
    {
        const string sql = """
            UPDATE dbo.UserReqReports
               SET GenerationStatus   = 5,
                   DownloadCount      = DownloadCount + 1,
                   FirstDownloadedDate = COALESCE(FirstDownloadedDate, SYSDATETIME()),
                   LastDownloadedDate = SYSDATETIME(),
                   UpdatedDate        = SYSDATETIME()
             WHERE ReportId = @Id AND GenerationStatus IN (3, 5);
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
        cmd.Parameters.AddWithValue("@Id", reportId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    private static string CacheKey(string connectionString)
    {
        // Prefer DataSource+Initial Catalog so pool/password differences don't fragment the cache.
        try
        {
            var b = new SqlConnectionStringBuilder(connectionString);
            return $"{b.DataSource}|{b.InitialCatalog}";
        }
        catch
        {
            return connectionString;
        }
    }

    private async Task<bool> UserReqReportsExistsAsync(string connectionString, CancellationToken ct)
    {
        var key = CacheKey(connectionString);
        if (TableExistsCache.TryGetValue(key, out var cached))
            return cached;

        const string sql = "SELECT CASE WHEN OBJECT_ID(N'dbo.UserReqReports', N'U') IS NULL THEN 0 ELSE 1 END;";
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 10 };
            var present = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0) == 1;
            TableExistsCache[key] = present;
            if (!present)
            {
                _logger.LogWarning(
                    "dbo.UserReqReports is missing on {Db}. Deploy SQL_Scripts/UserReqReports before the Reports badge can load this lab.",
                    key);
            }
            return present;
        }
        catch (SqlException ex)
        {
            // Connectivity / permission issues — do not cache forever; treat as absent this call.
            _logger.LogDebug(ex, "UserReqReports existence check failed for {Db}", key);
            return false;
        }
    }

    private async Task<bool> HasProgressPercentAsync(string connectionString, CancellationToken ct)
    {
        var key = CacheKey(connectionString);
        if (ProgressColumnCache.TryGetValue(key, out var cached))
            return cached;

        if (!await UserReqReportsExistsAsync(connectionString, ct))
        {
            ProgressColumnCache[key] = false;
            return false;
        }

        const string sql = "SELECT CASE WHEN COL_LENGTH('dbo.UserReqReports', 'ProgressPercent') IS NULL THEN 0 ELSE 1 END;";
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 10 };
            var present = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0) == 1;
            ProgressColumnCache[key] = present;
            if (!present)
            {
                _logger.LogWarning(
                    "dbo.UserReqReports.ProgressPercent is missing on {Db}. Run SQL_Scripts/UserReqReports/03_Add_ProgressPercent.sql. Progress % will be hidden until then.",
                    CacheKey(connectionString));
            }
            return present;
        }
        catch (SqlException ex) when (ex.Number is 208 or 207) // table/column missing
        {
            if (ex.Number == 208) MarkTableMissing(connectionString);
            ProgressColumnCache[key] = false;
            return false;
        }
    }

    private static void MarkProgressColumnMissing(string connectionString) =>
        ProgressColumnCache[CacheKey(connectionString)] = false;

    private static void MarkTableMissing(string connectionString)
    {
        var key = CacheKey(connectionString);
        TableExistsCache[key] = false;
        ProgressColumnCache[key] = false;
    }

    private static SqlCommand StoredProc(SqlConnection conn, string name, int timeoutSeconds) =>
        new(name, conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = timeoutSeconds };

    private static UserReportRow MapUserRow(SqlDataReader r, bool includeProgress = true) => new(
        ReportId:       r.GetInt64(0),
        ReportType:     r.GetString(1),
        LabName:        r.GetString(2),
        RequestedBy:    r.GetString(3),
        RequestedDate:  r.GetDateTime(4),
        Status:         (ReportStatus)Convert.ToByte(r.GetValue(5)),
        FileName:       r.IsDBNull(6)  ? null : r.GetString(6),
        FileSizeBytes:  r.IsDBNull(7)  ? null : r.GetInt64(7),
        ReportRowCount: r.IsDBNull(8)  ? null : Convert.ToInt32(r.GetValue(8)),
        CompletedDate:  r.IsDBNull(9)  ? null : r.GetDateTime(9),
        ExpiryDate:     r.IsDBNull(10) ? null : r.GetDateTime(10),
        ErrorMessage:   r.IsDBNull(11) ? null : r.GetString(11),
        DownloadToken:  r.GetGuid(12),
        ProgressPercent: includeProgress && r.FieldCount > 13 && !r.IsDBNull(13)
            ? Convert.ToByte(r.GetValue(13))
            : null);
}
