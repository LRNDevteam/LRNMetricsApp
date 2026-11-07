using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Data Processing > Run Master File Load: queues a LRN.MasterFileProcessorWorker re-run for one lab
/// in LRNMaster.dbo.MasterFileProcessorRerunRequest - the same queue the LRN Metrics Report Audit Log
/// screen writes. The worker claims the row on its next poll, pulls the lab's latest master file from
/// SharePoint, reloads dbo.LineLevelData / dbo.ClaimLevelData with the denial enrichment, runs the AR
/// Workbench sync, and writes the outcome back onto the row.
/// <para>
/// The API never updates a claimed row: only the worker closes a request, so this screen can never
/// show a load as finished while it is still running.
/// </para>
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const string MasterFileRerunApp = "LRN.ARWorkbench";

    public async Task<ArWorkbenchMasterFileQueueResult> QueueMasterFileRunAsync(int labId, string labName, ArWorkbenchMasterFileRequestContext context, CancellationToken ct)
    {
        // One outstanding request per lab (UX_MFPRerun_Lab_Outstanding): a second click while one is
        // queued or running reports the existing one instead of queuing the same full reload twice.
        const string sql = @"
IF OBJECT_ID(N'dbo.MasterFileProcessorRerunRequest', N'U') IS NULL
BEGIN
    SELECT CAST(0 AS bit) AS Installed, CAST(0 AS bit) AS Queued, CAST(NULL AS varchar(20)) AS ExistingStatus, CAST(NULL AS bigint) AS RequestId;
    RETURN;
END
DECLARE @Existing varchar(20), @ExistingId bigint;
SELECT TOP (1) @Existing = Status, @ExistingId = RerunRequestId
FROM dbo.MasterFileProcessorRerunRequest
WHERE LabId = @LabId AND Status IN ('Pending', 'Claimed')
ORDER BY RerunRequestId DESC;
IF @Existing IS NOT NULL
BEGIN
    SELECT CAST(1 AS bit), CAST(0 AS bit), @Existing, @ExistingId;
    RETURN;
END
INSERT INTO dbo.MasterFileProcessorRerunRequest
    (BatchId, LabId, LabName, Status, RequestedBy, RequestedByRole,
     RequestedFromApp, RequestedFromHost, RequestedFromIp, RequestedFromUserAgent, Notes)
VALUES
    (NEWID(), @LabId, @LabName, 'Pending', @RequestedBy, @RequestedByRole,
     @App, @Host, @Ip, @UserAgent, @Notes);
SELECT CAST(1 AS bit), CAST(1 AS bit), CAST(NULL AS varchar(20)), CAST(SCOPE_IDENTITY() AS bigint);";

        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, master) { CommandTimeout = 30 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@LabName", SqlDbType.VarChar, 120).Value = Clip(labName, 120);
        cmd.Parameters.Add("@RequestedBy", SqlDbType.NVarChar, 200).Value = Clip(context.RequestedBy, 200);
        cmd.Parameters.Add("@RequestedByRole", SqlDbType.NVarChar, 100).Value = Clip(context.RequestedByRole, 100);
        cmd.Parameters.Add("@App", SqlDbType.VarChar, 100).Value = MasterFileRerunApp;
        cmd.Parameters.Add("@Host", SqlDbType.NVarChar, 200).Value = Clip(Environment.MachineName, 200);
        cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = Clip(context.ClientIp, 64);
        cmd.Parameters.Add("@UserAgent", SqlDbType.NVarChar, 400).Value = Clip(context.UserAgent, 400);
        cmd.Parameters.Add("@Notes", SqlDbType.NVarChar, 1000).Value = Clip(context.Note, 1000);

        try
        {
            await using var r = await cmd.ExecuteReaderAsync(ct);
            await r.ReadAsync(ct);
            return new ArWorkbenchMasterFileQueueResult
            {
                Installed = r.GetBoolean(0),
                Queued = r.GetBoolean(1),
                ExistingStatus = r.IsDBNull(2) ? null : r.GetString(2),
                RequestId = r.IsDBNull(3) ? null : r.GetInt64(3)
            };
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            // Two clicks raced past the check; the unique index let exactly one of them in.
            return new ArWorkbenchMasterFileQueueResult { Installed = true, Queued = false, ExistingStatus = "Pending" };
        }
    }

    /// <summary>
    /// Upload Master File: stores the validated standard-template workbook in LRNMaster
    /// dbo.MasterFileUpload and queues a Master File Processor request carrying its UploadId, in one
    /// transaction - an upload is never stored without its request, nor a request queued without its
    /// file. The same one-outstanding-request-per-lab rule as Run Master File Load applies, so an
    /// upload never runs on top of a SharePoint load of the same lab.
    /// </summary>
    public async Task<ArWorkbenchMasterFileQueueResult> QueueMasterFileUploadAsync(int labId, string labName, ArWorkbenchMasterFileUpload upload,
        ArWorkbenchMasterFileRequestContext context, CancellationToken ct)
    {
        // Checked in its own batch: a batch naming the UploadId column would fail to compile on an
        // LRNMaster where the column is not there yet, before any IF inside it could run.
        const string installedSql = @"
SELECT CAST(CASE WHEN OBJECT_ID(N'dbo.MasterFileProcessorRerunRequest', N'U') IS NOT NULL
                  AND OBJECT_ID(N'dbo.MasterFileUpload', N'U') IS NOT NULL
                  AND COL_LENGTH(N'dbo.MasterFileProcessorRerunRequest', N'UploadId') IS NOT NULL THEN 1 ELSE 0 END AS bit);";

        const string sql = @"
DECLARE @Existing varchar(20), @ExistingId bigint;
SELECT TOP (1) @Existing = Status, @ExistingId = RerunRequestId
FROM dbo.MasterFileProcessorRerunRequest WITH (UPDLOCK, HOLDLOCK)
WHERE LabId = @LabId AND Status IN ('Pending', 'Claimed')
ORDER BY RerunRequestId DESC;
IF @Existing IS NOT NULL
BEGIN
    SELECT CAST(1 AS bit), CAST(0 AS bit), @Existing, @ExistingId, CAST(NULL AS bigint);
    RETURN;
END
INSERT INTO dbo.MasterFileUpload
    (LabId, LabName, FileName, FileSizeBytes, FileSha256, FileContent, PeriodStart, PeriodEnd,
     ClaimRows, LineRows, TemplateVersion, UploadedBy, UploadedFromApp, Notes)
VALUES
    (@LabId, @LabName, @FileName, DATALENGTH(@Content), @Sha256, @Content, @PeriodStart, @PeriodEnd,
     @ClaimRows, @LineRows, @TemplateVersion, @RequestedBy, @App, @Notes);
DECLARE @UploadId bigint = SCOPE_IDENTITY();
INSERT INTO dbo.MasterFileProcessorRerunRequest
    (BatchId, LabId, LabName, Status, RequestedBy, RequestedByRole,
     RequestedFromApp, RequestedFromHost, RequestedFromIp, RequestedFromUserAgent, Notes, UploadId)
VALUES
    (NEWID(), @LabId, @LabName, 'Pending', @RequestedBy, @RequestedByRole,
     @App, @Host, @Ip, @UserAgent, @Notes, @UploadId);
SELECT CAST(1 AS bit), CAST(1 AS bit), CAST(NULL AS varchar(20)), CAST(SCOPE_IDENTITY() AS bigint), @UploadId;";

        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using (var check = new SqlCommand(installedSql, master) { CommandTimeout = 30 })
        {
            if (!(bool)(await check.ExecuteScalarAsync(ct) ?? false))
                return new ArWorkbenchMasterFileQueueResult { Installed = false };
        }

        await using var tx = (SqlTransaction)await master.BeginTransactionAsync(ct);
        await using var cmd = new SqlCommand(sql, master, tx) { CommandTimeout = 300 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@LabName", SqlDbType.VarChar, 120).Value = Clip(labName, 120);
        cmd.Parameters.Add("@FileName", SqlDbType.NVarChar, 260).Value = Clip(upload.FileName, 260);
        cmd.Parameters.Add("@Sha256", SqlDbType.Char, 64).Value = upload.Sha256;
        cmd.Parameters.Add("@Content", SqlDbType.VarBinary, -1).Value = upload.Content;
        cmd.Parameters.Add("@PeriodStart", SqlDbType.Date).Value = upload.PeriodStart;
        cmd.Parameters.Add("@PeriodEnd", SqlDbType.Date).Value = upload.PeriodEnd;
        cmd.Parameters.Add("@ClaimRows", SqlDbType.Int).Value = upload.ClaimRows;
        cmd.Parameters.Add("@LineRows", SqlDbType.Int).Value = upload.LineRows;
        cmd.Parameters.Add("@TemplateVersion", SqlDbType.VarChar, 20).Value = Clip(upload.TemplateVersion, 20);
        cmd.Parameters.Add("@RequestedBy", SqlDbType.NVarChar, 200).Value = Clip(context.RequestedBy, 200);
        cmd.Parameters.Add("@RequestedByRole", SqlDbType.NVarChar, 100).Value = Clip(context.RequestedByRole, 100);
        cmd.Parameters.Add("@App", SqlDbType.VarChar, 100).Value = MasterFileRerunApp;
        cmd.Parameters.Add("@Host", SqlDbType.NVarChar, 200).Value = Clip(Environment.MachineName, 200);
        cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = Clip(context.ClientIp, 64);
        cmd.Parameters.Add("@UserAgent", SqlDbType.NVarChar, 400).Value = Clip(context.UserAgent, 400);
        cmd.Parameters.Add("@Notes", SqlDbType.NVarChar, 1000).Value = Clip(context.Note, 1000);

        try
        {
            ArWorkbenchMasterFileQueueResult result;
            await using (var r = await cmd.ExecuteReaderAsync(ct))
            {
                await r.ReadAsync(ct);
                result = new ArWorkbenchMasterFileQueueResult
                {
                    Installed = r.GetBoolean(0),
                    Queued = r.GetBoolean(1),
                    ExistingStatus = r.IsDBNull(2) ? null : r.GetString(2),
                    RequestId = r.IsDBNull(3) ? null : r.GetInt64(3),
                    UploadId = r.IsDBNull(4) ? null : r.GetInt64(4)
                };
            }
            await tx.CommitAsync(ct);
            return result;
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            // Two requests raced past the check; the unique index let exactly one of them in.
            await tx.RollbackAsync(CancellationToken.None);
            return new ArWorkbenchMasterFileQueueResult { Installed = true, Queued = false, ExistingStatus = "Pending" };
        }
    }

    /// <summary>The lab's master file load requests, newest first. Installed = false before Create_RerunRequests.sql is run.</summary>
    public async Task<ArWorkbenchMasterFileRunList> GetMasterFileRunsAsync(int labId, int top, CancellationToken ct)
    {
        // The upload columns are read only once Create_MasterFileUploads.sql has been run; before
        // that every request is a SharePoint load.
        const string sql = @"
IF OBJECT_ID(N'dbo.MasterFileProcessorRerunRequest', N'U') IS NULL
BEGIN
    SELECT CAST(0 AS bit), CAST(0 AS bit);
    RETURN;
END
DECLARE @Uploads bit = CASE WHEN OBJECT_ID(N'dbo.MasterFileUpload', N'U') IS NOT NULL
                             AND COL_LENGTH(N'dbo.MasterFileProcessorRerunRequest', N'UploadId') IS NOT NULL THEN 1 ELSE 0 END;
SELECT CAST(1 AS bit), @Uploads;
IF @Uploads = 1
    EXEC sys.sp_executesql N'
SELECT TOP (@Top) r.RerunRequestId, r.Status, r.RequestedBy, r.RequestedOn, r.RequestedFromApp, r.Notes,
       r.ClaimedOn, r.ClaimedByHost, r.CompletedOn, r.RunId, r.ResultStatus, r.ResultMessage,
       u.UploadId, u.FileName, u.PeriodStart, u.PeriodEnd, u.ClaimRows, u.LineRows
FROM dbo.MasterFileProcessorRerunRequest AS r
LEFT JOIN dbo.MasterFileUpload AS u ON u.UploadId = r.UploadId
WHERE r.LabId = @LabId
ORDER BY r.RequestedOn DESC, r.RerunRequestId DESC;', N'@LabId int, @Top int', @LabId = @LabId, @Top = @Top;
ELSE
    SELECT TOP (@Top) RerunRequestId, Status, RequestedBy, RequestedOn, RequestedFromApp, Notes,
           ClaimedOn, ClaimedByHost, CompletedOn, RunId, ResultStatus, ResultMessage,
           CAST(NULL AS bigint), CAST(NULL AS nvarchar(260)), CAST(NULL AS date), CAST(NULL AS date), CAST(NULL AS int), CAST(NULL AS int)
    FROM dbo.MasterFileProcessorRerunRequest
    WHERE LabId = @LabId
    ORDER BY RequestedOn DESC, RerunRequestId DESC;";

        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, master) { CommandTimeout = 30 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@Top", SqlDbType.Int).Value = Math.Clamp(top, 1, 200);

        var list = new ArWorkbenchMasterFileRunList();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        await r.ReadAsync(ct);
        list.Installed = r.GetBoolean(0);
        list.UploadsInstalled = r.GetBoolean(1);
        if (!list.Installed || !await r.NextResultAsync(ct)) return list;

        static string? S(SqlDataReader x, int i) => x.IsDBNull(i) ? null : x.GetString(i);
        static DateTime? D(SqlDataReader x, int i) => x.IsDBNull(i) ? null : x.GetDateTime(i);
        static int? I(SqlDataReader x, int i) => x.IsDBNull(i) ? null : x.GetInt32(i);
        while (await r.ReadAsync(ct))
        {
            list.Runs.Add(new ArWorkbenchMasterFileRun
            {
                RequestId = r.GetInt64(0),
                Status = r.GetString(1),
                RequestedBy = S(r, 2),
                RequestedOn = r.GetDateTime(3),
                RequestedFromApp = S(r, 4),
                Note = S(r, 5),
                ClaimedOn = D(r, 6),
                ClaimedByHost = S(r, 7),
                CompletedOn = D(r, 8),
                RunId = S(r, 9),
                ResultStatus = S(r, 10),
                ResultMessage = S(r, 11),
                UploadId = r.IsDBNull(12) ? null : r.GetInt64(12),
                UploadFileName = S(r, 13),
                PeriodStart = D(r, 14),
                PeriodEnd = D(r, 15),
                UploadClaimRows = I(r, 16),
                UploadLineRows = I(r, 17)
            });
        }
        return list;
    }

    private static object Clip(string? value, int max)
    {
        if (string.IsNullOrWhiteSpace(value)) return DBNull.Value;
        var trimmed = value.Trim();
        return trimmed.Length <= max ? trimmed : trimmed[..max];
    }
}

public sealed class ArWorkbenchMasterFileRequestContext
{
    public string RequestedBy { get; init; } = string.Empty;
    public string? RequestedByRole { get; init; }
    public string? ClientIp { get; init; }
    public string? UserAgent { get; init; }
    public string? Note { get; init; }
}

/// <summary>A validated standard-template workbook, ready to store with its request.</summary>
public sealed class ArWorkbenchMasterFileUpload
{
    public string FileName { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
    public string Sha256 { get; init; } = string.Empty;
    public DateTime PeriodStart { get; init; }
    public DateTime PeriodEnd { get; init; }
    public int ClaimRows { get; init; }
    public int LineRows { get; init; }
    public string? TemplateVersion { get; init; }
}

public sealed class ArWorkbenchMasterFileQueueResult
{
    /// <summary>False when LRNMaster has no dbo.MasterFileProcessorRerunRequest yet (or, for an upload, no dbo.MasterFileUpload).</summary>
    public bool Installed { get; set; }
    public bool Queued { get; set; }
    /// <summary>Pending / Claimed when a request for the lab was already outstanding.</summary>
    public string? ExistingStatus { get; set; }
    public long? RequestId { get; set; }
    /// <summary>The stored upload, for Upload Master File.</summary>
    public long? UploadId { get; set; }
    /// <summary>What the validation found, returned with an upload so the screen can show the warnings.</summary>
    public MasterFileValidationResult? Validation { get; set; }
}

public sealed class ArWorkbenchMasterFileRunList
{
    public bool Installed { get; set; }
    /// <summary>False before Create_MasterFileUploads.sql is run: Upload Master File is not available yet.</summary>
    public bool UploadsInstalled { get; set; }
    public List<ArWorkbenchMasterFileRun> Runs { get; set; } = [];
}

/// <summary>One row of dbo.MasterFileProcessorRerunRequest. Status: Pending -> Claimed -> Completed | Failed.</summary>
public sealed class ArWorkbenchMasterFileRun
{
    public long RequestId { get; set; }
    public string Status { get; set; } = string.Empty;
    public string? RequestedBy { get; set; }
    public DateTime RequestedOn { get; set; }
    public string? RequestedFromApp { get; set; }
    public string? Note { get; set; }
    public DateTime? ClaimedOn { get; set; }
    public string? ClaimedByHost { get; set; }
    public DateTime? CompletedOn { get; set; }
    /// <summary>The worker RunID (LRN_Run_Log) this load produced.</summary>
    public string? RunId { get; set; }
    /// <summary>The worker's overall status: SUCCESS, FAILED, SKIPPED, ...</summary>
    public string? ResultStatus { get; set; }
    public string? ResultMessage { get; set; }
    /// <summary>Set when the load is an Upload Master File (dbo.MasterFileUpload); null = SharePoint.</summary>
    public long? UploadId { get; set; }
    public string? UploadFileName { get; set; }
    public DateTime? PeriodStart { get; set; }
    public DateTime? PeriodEnd { get; set; }
    public int? UploadClaimRows { get; set; }
    public int? UploadLineRows { get; set; }
}
