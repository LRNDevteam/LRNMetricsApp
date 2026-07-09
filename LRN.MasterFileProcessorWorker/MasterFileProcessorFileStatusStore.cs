using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;

public sealed class MasterFileProcessorFileStatusStore
{
    private readonly string _connStr;
    private readonly string _tableName;

    public MasterFileProcessorFileStatusStore(IConfiguration config, IOptions<ImportOptions> opt)
    {
        _connStr = config.GetConnectionString("DefaultConnection")
                  ?? throw new InvalidOperationException("Missing DefaultConnection connection string.");
        _tableName = opt.Value.FileStatusTable;
    }

    public async Task<bool> IsProcessedAsync(int labId, string driveId, string itemId, string eTagKey, CancellationToken ct)
    {
        string sql = $@"
SELECT 1
FROM {_tableName}
WHERE LabId=@LabId AND DriveId=@DriveId AND ItemId=@ItemId AND ETagKey=@ETagKey AND Status='PROCESSED';";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);

        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@DriveId", driveId);
        cmd.Parameters.AddWithValue("@ItemId", itemId);
        cmd.Parameters.AddWithValue("@ETagKey", eTagKey ?? string.Empty);

        var obj = await cmd.ExecuteScalarAsync(ct);
        return obj != null;
    }

    /// <summary>
    /// Returns true when a file with the same content (SHA-256 hash) was already PROCESSED
    /// for this lab, even if SharePoint reports a different eTag / modified date
    /// (e.g. a user opened and closed the file without changing anything).
    /// No-op (returns false) until the ContentHash column exists on the status table.
    /// </summary>
    public async Task<bool> IsContentProcessedAsync(int labId, string contentHash, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(contentHash))
            return false;

        string sql = $@"
IF COL_LENGTH('{_tableName}', 'ContentHash') IS NOT NULL
BEGIN
    EXEC sp_executesql
        N'SELECT TOP (1) 1 FROM {_tableName} WHERE LabId=@LabId AND ContentHash=@ContentHash AND Status=''PROCESSED'';',
        N'@LabId int, @ContentHash nvarchar(200)',
        @LabId=@LabId, @ContentHash=@ContentHash;
END";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);

        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@ContentHash", contentHash);

        var obj = await cmd.ExecuteScalarAsync(ct);
        return obj != null;
    }

    /// <summary>
    /// Upsert status row for a SharePoint file. If your table contains a column named "ErrorLogInfo",
    /// it will be updated/inserted automatically; otherwise it's ignored.
    /// </summary>
    public async Task UpsertStatusAsync(
        int labId,
        string driveId,
        string itemId,
        string eTagKey,
        string fileName,
        string sharePointPath,
        DateTimeOffset? lastModifiedUtc,
        string status,
        string? statusMessage,
        DateTimeOffset? processedAtUtc,
        CancellationToken ct,
        string? errorLogInfo = null,
        string? contentHash = null)
    {
        // NOTE: This SQL safely updates ErrorLogInfo only if the column exists.
        string sql = $@"
DECLARE @HasErrorLogInfo BIT = CASE WHEN COL_LENGTH('{_tableName}', 'ErrorLogInfo') IS NULL THEN 0 ELSE 1 END;

IF EXISTS (SELECT 1 FROM {_tableName} WHERE LabId=@LabId AND ItemId=@ItemId AND ETagKey=@ETagKey)
BEGIN
    UPDATE {_tableName}
    SET DriveId=@DriveId,
        FileName=@FileName,
        SharePointPath=@SharePointPath,
        LastModifiedUtc=@LastModifiedUtc,
        Status=@Status,
        StatusMessage=@StatusMessage,
        Attempts = Attempts + 1,
        LastAttemptUtc = SYSUTCDATETIME(),
        ProcessedAtUtc = COALESCE(@ProcessedAtUtc, ProcessedAtUtc),
        ErrorLogInfo = CASE WHEN @HasErrorLogInfo = 1 THEN @ErrorLogInfo ELSE ErrorLogInfo END
    WHERE LabId=@LabId AND ItemId=@ItemId AND ETagKey=@ETagKey;
END
ELSE
BEGIN
    IF (@HasErrorLogInfo = 1)
    BEGIN
        INSERT INTO {_tableName}
        (LabId, DriveId, ItemId, ETagKey, FileName, SharePointPath, LastModifiedUtc, Status, StatusMessage, ErrorLogInfo, Attempts, FirstSeenUtc, LastAttemptUtc, ProcessedAtUtc)
        VALUES
        (@LabId, @DriveId, @ItemId, @ETagKey, @FileName, @SharePointPath, @LastModifiedUtc, @Status, @StatusMessage, @ErrorLogInfo, 1, SYSUTCDATETIME(), SYSUTCDATETIME(), @ProcessedAtUtc);
    END
    ELSE
    BEGIN
        INSERT INTO {_tableName}
        (LabId, DriveId, ItemId, ETagKey, FileName, SharePointPath, LastModifiedUtc, Status, StatusMessage, Attempts, FirstSeenUtc, LastAttemptUtc, ProcessedAtUtc)
        VALUES
        (@LabId, @DriveId, @ItemId, @ETagKey, @FileName, @SharePointPath, @LastModifiedUtc, @Status, @StatusMessage, 1, SYSUTCDATETIME(), SYSUTCDATETIME(), @ProcessedAtUtc);
    END
END

IF (COL_LENGTH('{_tableName}', 'ContentHash') IS NOT NULL AND @ContentHash IS NOT NULL)
BEGIN
    EXEC sp_executesql
        N'UPDATE {_tableName} SET ContentHash=@ContentHash WHERE LabId=@LabId AND ItemId=@ItemId AND ETagKey=@ETagKey;',
        N'@ContentHash nvarchar(200), @LabId int, @ItemId nvarchar(200), @ETagKey nvarchar(300)',
        @ContentHash=@ContentHash, @LabId=@LabId, @ItemId=@ItemId, @ETagKey=@ETagKey;
END";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);

        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@DriveId", driveId);
        cmd.Parameters.AddWithValue("@ItemId", itemId);
        cmd.Parameters.AddWithValue("@ETagKey", eTagKey ?? string.Empty);
        cmd.Parameters.AddWithValue("@FileName", fileName);
        cmd.Parameters.AddWithValue("@SharePointPath", sharePointPath);
        cmd.Parameters.AddWithValue("@LastModifiedUtc", (object?)lastModifiedUtc?.UtcDateTime ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Status", status);
        cmd.Parameters.AddWithValue("@StatusMessage", (object?)statusMessage ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ProcessedAtUtc", (object?)processedAtUtc?.UtcDateTime ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ErrorLogInfo", (object?)errorLogInfo ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ContentHash", (object?)contentHash ?? DBNull.Value);

        await cmd.ExecuteNonQueryAsync(ct);
    }
}
