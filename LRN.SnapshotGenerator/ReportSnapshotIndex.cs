using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.SnapshotGenerator;

/// <summary>A report that turned Success for a RunId in ReportsWorkflowTracker.</summary>
/// <param name="Stamp">
/// The tracker row's own timestamp as stored (time zone unknown - writers use IST and UTC), or null
/// when the table has none. Never compared with a clock: only with the stamp of the last capture, so a
/// re-run of the report (a new stamp) is captured again.
/// </param>
public sealed record TrackerSuccess(string RunId, int LabId, string? LabName, string? WeekFolder, string ReportName, DateTime? Stamp)
{
    /// <summary>The stamp as text, as stored with a capture (ReportPageSnapshot.TrackerStamp).</summary>
    public string? StampText => Stamp?.ToString("yyyy-MM-ddTHH:mm:ss.fffffff", System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>A Pending row of dbo.ReportSnapshotRequest (a Denial Insight upload or edit).</summary>
/// <param name="LabKey">Set by LabMetricsDashboard (the lab's LRN Metrics key).</param>
/// <param name="LabId">Set by the master file processor when a re-run replaced the week's run.</param>
public sealed record SnapshotRequest(long RequestId, string? LabKey, int? LabId, string ReportCode, string RequestedBy, string? Reason, DateTime RequestedOnUtc, int Attempts);

/// <summary>The snapshot run row a report's files belong to.</summary>
public sealed record SnapshotRunInfo(long SnapshotRunId, string? BlobPrefix, string Status, bool Created);

/// <summary>
/// LRNMaster reads and writes this service needs beyond the shared <c>ReportSnapshotRepository</c>:
/// the tracker poll, and run rows that are joined - never reset - because the master file processor
/// may already have written the run's LINELEVEL / CLAIMLEVEL / LIMS files into the same row.
/// </summary>
public sealed class ReportSnapshotIndex
{
    private readonly string _masterConnectionString;

    public ReportSnapshotIndex(IConfiguration configuration)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster). Add the Key Vault secret ConnectionStrings--DefaultConnection.");
    }

    // The tracker's timestamp column, in order of preference. The table's definition is not in this
    // repository, so the service looks it up once instead of assuming one (it has no UpdatedOn).
    private static readonly string[] TrackerStampColumns =
        ["UpdatedOn", "ModifiedOn", "LastUpdatedOn", "UpdatedDate", "CompletedOn", "EndTime", "CreatedOn", "CreatedDate"];
    private string? _trackerStampColumn;
    private bool _trackerStampResolved;

    /// <summary>The tracker's timestamp column (null when it has none), looked up once.</summary>
    public async Task<string?> GetTrackerStampColumnAsync(CancellationToken ct)
    {
        if (_trackerStampResolved) return _trackerStampColumn;

        const string sql = @"
SELECT c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(N'dbo.ReportsWorkflowTracker')
  AND TYPE_NAME(c.system_type_id) IN ('datetime', 'datetime2', 'smalldatetime', 'datetimeoffset');";
        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (await r.ReadAsync(ct)) present.Add(r.GetString(0));

        // Only a name from the fixed list ever goes into the statement text.
        _trackerStampColumn = TrackerStampColumns.FirstOrDefault(present.Contains);
        _trackerStampResolved = true;
        return _trackerStampColumn;
    }

    /// <summary>
    /// Success rows of the given labs and report names, newest first; with a timestamp column, only those
    /// of the last <paramref name="lookbackDays"/> days (a day of slack for the column's time zone).
    /// LabName / WeekFolder are the tracker's, falling back to dbo.LRN_Run_Log.
    /// </summary>
    public async Task<IReadOnlyList<TrackerSuccess>> GetTrackerSuccessesAsync(
        IReadOnlyCollection<int> labIds, IReadOnlyCollection<string> reportNames, int lookbackDays, CancellationToken ct)
    {
        if (labIds.Count == 0 || reportNames.Count == 0) return [];

        var stamp = await GetTrackerStampColumnAsync(ct);
        var stampExpr = stamp is null ? "CAST(NULL AS datetime2)" : $"CAST(t.[{stamp}] AS datetime2)";
        var window = stamp is null ? "" : $"\n  AND t.[{stamp}] >= DATEADD(DAY, -(@LookbackDays + 1), SYSUTCDATETIME())";
        var order = stamp is null ? "t.RunId DESC" : $"t.[{stamp}] DESC, t.RunId DESC";

        // Lab ids and report names are passed as delimited lists and split server-side (STRING_SPLIT),
        // so the statement text never carries values.
        var sql = $@"
SELECT t.RunId, t.LabId, COALESCE(NULLIF(t.LabName, ''), rl.LabName) AS LabName,
       COALESCE(NULLIF(t.WeekFolder, ''), rl.WeekFolder) AS WeekFolder, t.ReportName, {stampExpr} AS Stamp
FROM dbo.ReportsWorkflowTracker t
OUTER APPLY (SELECT TOP (1) r.LabName, r.WeekFolder FROM dbo.LRN_Run_Log r WHERE r.RunID = t.RunId) rl
WHERE t.Status = 'Success'
  AND t.LabId IN (SELECT TRY_CAST(value AS int) FROM STRING_SPLIT(@LabIds, ','))
  AND t.ReportName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@ReportNames, '|')){window}
ORDER BY {order};";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.Add("@LabIds", SqlDbType.NVarChar, 4000).Value = string.Join(",", labIds);
        cmd.Parameters.Add("@ReportNames", SqlDbType.NVarChar, 4000).Value = string.Join("|", reportNames);
        cmd.Parameters.Add("@LookbackDays", SqlDbType.Int).Value = Math.Max(1, lookbackDays);

        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var rows = new List<TrackerSuccess>();
        while (await r.ReadAsync(ct))
        {
            rows.Add(new TrackerSuccess(
                Convert.ToString(r.GetValue(0))!.Trim(),
                Convert.ToInt32(r.GetValue(1)),
                r.IsDBNull(2) ? null : Convert.ToString(r.GetValue(2)),
                r.IsDBNull(3) ? null : Convert.ToString(r.GetValue(3)),
                Convert.ToString(r.GetValue(4))!,
                r.IsDBNull(5) ? null : r.GetDateTime(5)));
        }
        return rows;
    }

    /// <summary>
    /// Whether the report is already captured for the run, and the tracker stamp it was captured for
    /// (from its PageModel entry; null when the capture has no display copy or predates the stamp).
    /// </summary>
    public async Task<(bool Captured, string? TrackerStamp)> GetCaptureAsync(int labId, string runId, string reportCode, CancellationToken ct)
    {
        const string sql = @"
SELECT COUNT(*),
       MAX(CASE WHEN f.ResultSetName = @PageModel THEN f.SchemaJson END)
FROM dbo.ReportSnapshotRun r
JOIN dbo.ReportSnapshotFile f ON f.SnapshotRunId = r.SnapshotRunId
WHERE r.LabId = @LabId AND r.RunId = @RunId AND f.ReportCode = @ReportCode;";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 64).Value = runId;
        cmd.Parameters.Add("@ReportCode", SqlDbType.VarChar, 50).Value = reportCode;
        cmd.Parameters.Add("@PageModel", SqlDbType.NVarChar, 100).Value = ReportPageSnapshot.ResultSetName;
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct) || r.GetInt32(0) == 0) return (false, null);
        return (true, PageModelIndexInfo.Parse(r.IsDBNull(1) ? null : r.GetString(1))?.TrackerStamp);
    }

    /// <summary>When this report was last snapshotted for the run (UTC), or null when it never was.</summary>
    public async Task<DateTime?> GetLastSnapshotAsync(int labId, string runId, string reportCode, CancellationToken ct)
    {
        const string sql = @"
SELECT MAX(f.CreatedOn)
FROM dbo.ReportSnapshotRun r
JOIN dbo.ReportSnapshotFile f ON f.SnapshotRunId = r.SnapshotRunId
WHERE r.LabId = @LabId AND r.RunId = @RunId AND f.ReportCode = @ReportCode;";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 64).Value = runId;
        cmd.Parameters.Add("@ReportCode", SqlDbType.VarChar, 50).Value = reportCode;
        await conn.OpenAsync(ct);
        var value = await cmd.ExecuteScalarAsync(ct);
        return value is DateTime d ? DateTime.SpecifyKind(d, DateTimeKind.Utc) : null;
    }

    /// <summary>
    /// The lab + RunId run row: the existing one as it is (the master file processor's, with its prefix and
    /// files), or a new one with <paramref name="blobPrefix"/> when the run has no master data snapshot.
    /// </summary>
    public async Task<SnapshotRunInfo> EnsureRunAsync(
        int labId, string labName, string runId, string weekFolder, DateTime snapshotDate, string blobPrefix, CancellationToken ct)
    {
        const string sql = @"
SET XACT_ABORT ON;
BEGIN TRAN;
DECLARE @Id bigint, @Prefix nvarchar(500), @Status varchar(20), @Created bit = 0;
SELECT @Id = SnapshotRunId, @Prefix = BlobPrefix, @Status = Status
FROM dbo.ReportSnapshotRun WITH (UPDLOCK, HOLDLOCK)
WHERE LabId = @LabId AND RunId = @RunId;
IF @Id IS NULL
BEGIN
    INSERT dbo.ReportSnapshotRun (LabId, LabName, RunId, WeekFolder, SnapshotDate, BlobPrefix, Status)
    VALUES (@LabId, @LabName, @RunId, @WeekFolder, @SnapshotDate, @BlobPrefix, 'InProgress');
    SELECT @Id = SCOPE_IDENTITY(), @Prefix = @BlobPrefix, @Status = 'InProgress', @Created = 1;
END
COMMIT;
SELECT @Id, @Prefix, @Status, @Created;";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@LabName", SqlDbType.NVarChar, 100).Value = labName;
        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 64).Value = runId;
        cmd.Parameters.Add("@WeekFolder", SqlDbType.NVarChar, 100).Value = weekFolder;
        cmd.Parameters.Add("@SnapshotDate", SqlDbType.Date).Value = snapshotDate.Date;
        cmd.Parameters.Add("@BlobPrefix", SqlDbType.NVarChar, 500).Value = blobPrefix;
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        await r.ReadAsync(ct);
        return new SnapshotRunInfo(r.GetInt64(0), r.IsDBNull(1) ? null : r.GetString(1), r.GetString(2), r.GetBoolean(3));
    }

    /// <summary>Removes a report's file rows for the run before it is rewritten, so a section the page no longer has does not linger.</summary>
    public async Task DeleteReportFilesAsync(long snapshotRunId, string reportCode, CancellationToken ct)
    {
        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(
            "DELETE dbo.ReportSnapshotFile WHERE SnapshotRunId = @Id AND ReportCode = @ReportCode;", conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = snapshotRunId;
        cmd.Parameters.Add("@ReportCode", SqlDbType.VarChar, 50).Value = reportCode;
        await conn.OpenAsync(ct);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>The page report snapshots the lab's run holds (master data codes excluded), and how many files.</summary>
    public async Task<(IReadOnlyList<string> Codes, int Files)> GetRunReportsAsync(int labId, string runId, CancellationToken ct)
    {
        const string sql = @"
SELECT f.ReportCode, COUNT(*)
FROM dbo.ReportSnapshotRun r
JOIN dbo.ReportSnapshotFile f ON f.SnapshotRunId = r.SnapshotRunId
WHERE r.LabId = @LabId AND r.RunId = @RunId AND f.ReportCode NOT IN ('LINELEVEL', 'CLAIMLEVEL', 'LIMS')
GROUP BY f.ReportCode
ORDER BY f.ReportCode;";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 64).Value = runId;
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var codes = new List<string>();
        int files = 0;
        while (await r.ReadAsync(ct))
        {
            codes.Add(r.GetString(0));
            files += r.GetInt32(1);
        }
        return (codes, files);
    }

    /// <summary>
    /// The PageModel index entry of the lab's most recent snapshot of this report for another run (the
    /// previous week), so this week's report logic can be compared with it; null when there is none.
    /// </summary>
    public async Task<PageModelIndexInfo?> GetPreviousPageModelAsync(int labId, string runId, string reportCode, CancellationToken ct)
    {
        const string sql = @"
SELECT TOP (1) f.SchemaJson
FROM dbo.ReportSnapshotRun r
JOIN dbo.ReportSnapshotFile f ON f.SnapshotRunId = r.SnapshotRunId
WHERE r.LabId = @LabId AND r.RunId <> @RunId AND f.ReportCode = @ReportCode AND f.ResultSetName = @PageModel
ORDER BY r.SnapshotDate DESC, f.CreatedOn DESC;";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 64).Value = runId;
        cmd.Parameters.Add("@ReportCode", SqlDbType.VarChar, 50).Value = reportCode;
        cmd.Parameters.Add("@PageModel", SqlDbType.NVarChar, 100).Value = ReportPageSnapshot.ResultSetName;
        await conn.OpenAsync(ct);
        return PageModelIndexInfo.Parse(await cmd.ExecuteScalarAsync(ct) as string);
    }

    /// <summary>Pending rows of dbo.ReportSnapshotRequest, oldest first; empty when the table does not exist yet.</summary>
    public async Task<IReadOnlyList<SnapshotRequest>> GetPendingRequestsAsync(CancellationToken ct)
    {
        const string sql = @"
IF OBJECT_ID(N'dbo.ReportSnapshotRequest', N'U') IS NULL RETURN;
EXEC sp_executesql N'
SELECT RequestId, LabKey, LabId, ReportCode, RequestedBy, Reason, RequestedOn, Attempts
FROM dbo.ReportSnapshotRequest
WHERE Status = ''Pending''
ORDER BY RequestedOn;';";

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var rows = new List<SnapshotRequest>();
        while (await r.ReadAsync(ct))
        {
            rows.Add(new SnapshotRequest(
                r.GetInt64(0), r.IsDBNull(1) ? null : r.GetString(1), r.IsDBNull(2) ? null : r.GetInt32(2),
                r.GetString(3), r.GetString(4), r.IsDBNull(5) ? null : r.GetString(5),
                DateTime.SpecifyKind(r.GetDateTime(6), DateTimeKind.Utc), r.GetInt32(7)));
        }
        return rows;
    }

    /// <summary>
    /// Closes a request as Done / Skipped / Failed - only if no change arrived since it was read (RequestedOn
    /// unchanged). Otherwise it stays Pending and the newer change is captured on a later poll.
    /// </summary>
    public async Task CloseRequestAsync(SnapshotRequest request, string status, string? runId, string? message, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.ReportSnapshotRequest
SET Status = @Status, ProcessedOn = SYSUTCDATETIME(), RunId = @RunId, Message = @Message, Attempts = Attempts + 1
WHERE RequestId = @Id AND Status = 'Pending' AND RequestedOn = @RequestedOn;";
        await ExecuteRequestUpdateAsync(sql, request, status, runId, message, ct);
    }

    /// <summary>A failed try: the request stays Pending for the next poll, with the error and one more attempt counted.</summary>
    public async Task RecordRequestFailureAsync(SnapshotRequest request, string message, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.ReportSnapshotRequest
SET Attempts = Attempts + 1, Message = @Message
WHERE RequestId = @Id AND Status = 'Pending';";
        await ExecuteRequestUpdateAsync(sql, request, status: null, runId: null, message, ct);
    }

    private async Task ExecuteRequestUpdateAsync(string sql, SnapshotRequest request, string? status, string? runId, string? message, CancellationToken ct)
    {
        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = request.RequestId;
        cmd.Parameters.Add("@Status", SqlDbType.VarChar, 20).Value = (object?)status ?? DBNull.Value;
        cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 64).Value = (object?)runId ?? DBNull.Value;
        cmd.Parameters.Add("@Message", SqlDbType.NVarChar, 4000).Value =
            message is null ? DBNull.Value : message.Length > 4000 ? message[..4000] : message;
        cmd.Parameters.Add("@RequestedOn", SqlDbType.DateTime2, 3).Value = request.RequestedOnUtc;
        await conn.OpenAsync(ct);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// A run that now holds complete report files is available: Success. A failure message the master
    /// file processor left (e.g. its own upload failed) stays on the row, so the reason is not lost.
    /// A row another writer still has InProgress - other than one this service created - is left alone.
    /// </summary>
    public async Task MarkAvailableAsync(long snapshotRunId, bool createdHere, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.ReportSnapshotRun
SET Status = 'Success', CompletedOn = COALESCE(CompletedOn, SYSUTCDATETIME())
WHERE SnapshotRunId = @Id AND (Status <> 'InProgress' OR @CreatedHere = 1);";
        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = snapshotRunId;
        cmd.Parameters.Add("@CreatedHere", SqlDbType.Bit).Value = createdHere;
        await conn.OpenAsync(ct);
        await cmd.ExecuteNonQueryAsync(ct);
    }
}
