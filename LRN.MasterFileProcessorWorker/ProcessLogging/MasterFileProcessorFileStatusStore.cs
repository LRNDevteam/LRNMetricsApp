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
        string? errorLogInfo = null)
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

        await cmd.ExecuteNonQueryAsync(ct);
    }
}
