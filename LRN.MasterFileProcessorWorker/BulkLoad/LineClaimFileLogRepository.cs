using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Writes <c>dbo.LineClaimFileLogs</c> in the LAB database - one row per copy operation.
/// <para>
/// The existing columns are written exactly as they are; the outcome columns
/// (Status / RowsCopied / ErrorMessage / CompletedDateTime) are an ADDITIVE migration
/// (sql/Labs/_Common/02_LineClaimFileLogs.sql) and are written only when present,
/// so this code runs against both the old and the new table shape.
/// </para>
/// </summary>
public sealed class LineClaimFileLogRepository
{
    private readonly ILogger<LineClaimFileLogRepository> _logger;

    public LineClaimFileLogRepository(ILogger<LineClaimFileLogRepository> logger) => _logger = logger;

    /// <summary>Inserts the file-log row and returns the generated FileLogId.</summary>
    public async Task<long> InsertAsync(
        string labConnectionString,
        string runId,
        string? weekFolder,
        string labName,
        string? sourceFullPath,
        string? fileName,
        string fileType,
        DateTime? fileCreatedDateTime,
        CancellationToken ct)
    {
        const string sql = @"
INSERT INTO dbo.LineClaimFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime, InsertedDateTime)
OUTPUT   INSERTED.FileLogId
VALUES  (@RunId, @WeekFolder, @LabName, @SourceFullPath, @FileName, @FileType, @FileCreatedDateTime, @InsertedDateTime);";

        await using var conn = new SqlConnection(labConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };

        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 50).Value = runId;
        cmd.Parameters.Add("@WeekFolder", SqlDbType.NVarChar, 200).Value = (object?)weekFolder ?? DBNull.Value;
        cmd.Parameters.Add("@LabName", SqlDbType.NVarChar, 200).Value = labName;
        cmd.Parameters.Add("@SourceFullPath", SqlDbType.NVarChar, 1000).Value = (object?)sourceFullPath ?? DBNull.Value;
        cmd.Parameters.Add("@FileName", SqlDbType.NVarChar, 400).Value = (object?)fileName ?? DBNull.Value;
        cmd.Parameters.Add("@FileType", SqlDbType.NVarChar, 50).Value = fileType;
        cmd.Parameters.Add("@FileCreatedDateTime", SqlDbType.DateTime2).Value = (object?)fileCreatedDateTime ?? DBNull.Value;
        cmd.Parameters.Add("@InsertedDateTime", SqlDbType.DateTime2).Value = DateTime.Now;

        await conn.OpenAsync(ct).ConfigureAwait(false);
        var id = await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false);

        return Convert.ToInt64(id);
    }

    /// <summary>
    /// Records the outcome against the file-log row. No-ops (with a warning) when the additive
    /// columns have not been deployed yet, so this never breaks an un-migrated lab.
    /// </summary>
    public async Task TryCompleteAsync(
        string labConnectionString,
        long fileLogId,
        string status,
        long? rowsCopied,
        string? errorMessage,
        CancellationToken ct)
    {
        const string sql = @"
IF COL_LENGTH('dbo.LineClaimFileLogs', 'Status') IS NOT NULL
BEGIN
    UPDATE dbo.LineClaimFileLogs
    SET    Status             = @Status,
           RowsCopied         = @RowsCopied,
           ErrorMessage       = @ErrorMessage,
           CompletedDateTime  = @CompletedDateTime
    WHERE  FileLogId = @FileLogId;
END";

        try
        {
            await using var conn = new SqlConnection(labConnectionString);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };

            cmd.Parameters.Add("@FileLogId", SqlDbType.BigInt).Value = fileLogId;
            cmd.Parameters.Add("@Status", SqlDbType.NVarChar, 50).Value = status;
            cmd.Parameters.Add("@RowsCopied", SqlDbType.BigInt).Value = (object?)rowsCopied ?? DBNull.Value;
            cmd.Parameters.Add("@ErrorMessage", SqlDbType.NVarChar, -1).Value = (object?)errorMessage ?? DBNull.Value;
            cmd.Parameters.Add("@CompletedDateTime", SqlDbType.DateTime2).Value = DateTime.Now;

            await conn.OpenAsync(ct).ConfigureAwait(false);
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Logging must never break the pipeline.
            _logger.LogWarning(ex, "Could not update LineClaimFileLogs outcome for FileLogId {FileLogId}.", fileLogId);
        }
    }
}
