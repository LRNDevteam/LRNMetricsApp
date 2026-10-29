using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.Snapshots;

public sealed record SnapshotFileInfo(
    string ReportCode,
    string ResultSetName,
    string BlobPath,
    long RowCount,
    long SizeBytes,
    string ContentSha256,
    string SchemaJson,
    int SchemaVersion);

/// <summary>
/// The snapshot index in LRNMaster: <c>dbo.ReportSnapshotRun</c> (one row per lab + RunId) and
/// <c>dbo.ReportSnapshotFile</c> (one row per file). Created by
/// Database/LRN.MasterFileProcessorWorker/Create_ReportSnapshots.sql. The same tables will index
/// the standard report snapshots later; master data uses ReportCode LINELEVEL / CLAIMLEVEL / LIMS.
/// </summary>
public sealed class ReportSnapshotRepository
{
    private readonly string _masterConnectionString;

    public ReportSnapshotRepository(IConfiguration configuration)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");
    }

    /// <summary>
    /// Creates the run row, or resets it when this RunId was snapshotted before (its file rows are
    /// removed; the files themselves are overwritten at the same paths). Returns SnapshotRunId.
    /// </summary>
    public async Task<long> StartRunAsync(
        int labId, string labName, string runId, string weekFolder, DateTime snapshotDate, string blobPrefix, CancellationToken ct)
    {
        const string sql = @"
SET XACT_ABORT ON;
BEGIN TRAN;

DECLARE @Id BIGINT =
(
    SELECT SnapshotRunId FROM dbo.ReportSnapshotRun WITH (UPDLOCK, HOLDLOCK)
    WHERE LabId = @LabId AND RunId = @RunId
);

IF @Id IS NULL
BEGIN
    INSERT dbo.ReportSnapshotRun (LabId, LabName, RunId, WeekFolder, SnapshotDate, BlobPrefix, Status)
    VALUES (@LabId, @LabName, @RunId, @WeekFolder, @SnapshotDate, @BlobPrefix, 'InProgress');
    SET @Id = SCOPE_IDENTITY();
END
ELSE
BEGIN
    UPDATE dbo.ReportSnapshotRun
    SET LabName = @LabName, WeekFolder = @WeekFolder, SnapshotDate = @SnapshotDate, BlobPrefix = @BlobPrefix,
        Status = 'InProgress', ErrorMessage = NULL, CompletedOn = NULL
    WHERE SnapshotRunId = @Id;

    DELETE dbo.ReportSnapshotFile WHERE SnapshotRunId = @Id;
END

COMMIT;
SELECT @Id;";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@LabName", SqlDbType.NVarChar, 100).Value = labName;
        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 64).Value = runId;
        cmd.Parameters.Add("@WeekFolder", SqlDbType.NVarChar, 100).Value = weekFolder;
        cmd.Parameters.Add("@SnapshotDate", SqlDbType.Date).Value = snapshotDate.Date;
        cmd.Parameters.Add("@BlobPrefix", SqlDbType.NVarChar, 500).Value = blobPrefix;

        await conn.OpenAsync(ct).ConfigureAwait(false);
        return Convert.ToInt64(await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false));
    }

    public async Task AddFileAsync(long snapshotRunId, SnapshotFileInfo file, CancellationToken ct)
    {
        const string sql = @"
DELETE dbo.ReportSnapshotFile
WHERE SnapshotRunId = @SnapshotRunId AND ReportCode = @ReportCode AND ResultSetName = @ResultSetName;

INSERT dbo.ReportSnapshotFile
    (SnapshotRunId, ReportCode, ResultSetName, BlobPath, [RowCount], SizeBytes, ContentSha256, SchemaJson, SchemaVersion)
VALUES
    (@SnapshotRunId, @ReportCode, @ResultSetName, @BlobPath, @RowCount, @SizeBytes, @ContentSha256, @SchemaJson, @SchemaVersion);";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@SnapshotRunId", SqlDbType.BigInt).Value = snapshotRunId;
        cmd.Parameters.Add("@ReportCode", SqlDbType.VarChar, 50).Value = file.ReportCode;
        cmd.Parameters.Add("@ResultSetName", SqlDbType.NVarChar, 100).Value = file.ResultSetName;
        cmd.Parameters.Add("@BlobPath", SqlDbType.NVarChar, 500).Value = file.BlobPath;
        cmd.Parameters.Add("@RowCount", SqlDbType.BigInt).Value = file.RowCount;
        cmd.Parameters.Add("@SizeBytes", SqlDbType.BigInt).Value = file.SizeBytes;
        cmd.Parameters.Add("@ContentSha256", SqlDbType.Char, 64).Value = file.ContentSha256;
        cmd.Parameters.Add("@SchemaJson", SqlDbType.NVarChar, -1).Value = file.SchemaJson;
        cmd.Parameters.Add("@SchemaVersion", SqlDbType.Int).Value = file.SchemaVersion;

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    public async Task CompleteRunAsync(long snapshotRunId, string status, string? errorMessage, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.ReportSnapshotRun
SET Status = @Status, ErrorMessage = @ErrorMessage, CompletedOn = SYSUTCDATETIME()
WHERE SnapshotRunId = @SnapshotRunId;";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@SnapshotRunId", SqlDbType.BigInt).Value = snapshotRunId;
        cmd.Parameters.Add("@Status", SqlDbType.VarChar, 20).Value = status;
        cmd.Parameters.Add("@ErrorMessage", SqlDbType.NVarChar, 4000).Value =
            errorMessage is null ? DBNull.Value : errorMessage.Length > 4000 ? errorMessage[..4000] : errorMessage;

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<SnapshotRunRow>> ListRunsAsync(int labId, CancellationToken ct)
    {
        const string sql = @"
SELECT SnapshotRunId, RunId, WeekFolder, SnapshotDate, Status, CreatedOn, BlobPrefix
FROM dbo.ReportSnapshotRun
WHERE LabId = @LabId;";

        var rows = new List<SnapshotRunRow>();

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var r = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        while (await r.ReadAsync(ct).ConfigureAwait(false))
        {
            rows.Add(new SnapshotRunRow(
                r.GetInt64(0),
                r.GetString(1),
                r.GetString(2),
                r.GetDateTime(3),
                r.GetString(4),
                DateTime.SpecifyKind(r.GetDateTime(5), DateTimeKind.Utc),
                r.IsDBNull(6) ? null : r.GetString(6)));
        }

        return rows;
    }

    /// <summary>Deletes the run row; its file rows go with it (ON DELETE CASCADE). Call after its files are deleted.</summary>
    public async Task DeleteRunAsync(long snapshotRunId, CancellationToken ct)
    {
        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand("DELETE dbo.ReportSnapshotRun WHERE SnapshotRunId = @SnapshotRunId;", conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@SnapshotRunId", SqlDbType.BigInt).Value = snapshotRunId;

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }
}
