using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LRN.MasterFileProcessorWorker.ProcessLogging;

/// <summary>
/// One re-run asked for from the Report Audit Log screen (or the AR Workbench), already claimed by
/// this worker. UploadId is set when the request carries a master file uploaded in the AR Workbench
/// (dbo.MasterFileUpload): the run reads that workbook instead of looking on SharePoint.
/// </summary>
public sealed record RerunRequest(
    long RerunRequestId,
    int LabId,
    string? LabName,
    string RequestedBy,
    DateTime RequestedOn,
    string? Notes,
    long? UploadId = null);

/// <summary>
/// Reads and completes <c>LRNMaster.dbo.MasterFileProcessorRerunRequest</c>.
///
/// <para>
/// A re-run differs from a scheduled run in exactly two ways, and both are gates rather than
/// processing: the "already processed this file" ETag check in <c>BillingFrequencyFileStatus</c>,
/// and the "already ingested this upstream RunID" marker for a LabDatabase lab. A re-run exists
/// precisely because somebody wants the work done again, so both are bypassed for a claimed lab.
/// Everything after those gates - validation, standardization, hashing, the bulk load, the logs -
/// is the same code on the same path.
/// </para>
/// <para>
/// Every method swallows its own failures. The queue is a convenience on top of a worker that
/// already runs on a timer; a database hiccup reading it must never take the scheduled work down.
/// </para>
/// </summary>
public sealed class RerunRequestStore
{
    private const string Table = "dbo.MasterFileProcessorRerunRequest";

    private readonly string _connectionString;
    private readonly ILogger<RerunRequestStore> _logger;
    private readonly string _host;

    public RerunRequestStore(IConfiguration configuration, ILogger<RerunRequestStore> logger)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");

        _logger = logger;
        _host = Environment.MachineName;
    }

    /// <summary>
    /// Takes every Pending request and marks it Claimed, in one statement.
    ///
    /// <para>
    /// The UPDATE ... OUTPUT is deliberate: reading first and updating after would let two worker
    /// instances - or one instance whose previous poll overran - both see the same Pending row and
    /// both start a full truncate-and-reload of the same lab. Claiming inside the same statement
    /// that selects makes that impossible without holding a transaction open across the whole run.
    /// </para>
    /// <para>
    /// A claimed row that never completes (the worker was killed mid-run) stays Claimed and blocks
    /// new requests for that lab, which is the safe direction: it is visible on the screen and
    /// needs a person to look, rather than silently re-queuing work whose outcome nobody knows.
    /// </para>
    /// </summary>
    /// <param name="labIds">
    /// The labs THIS worker instance runs. Only their requests are claimed: a request for a lab that
    /// another instance runs is left Pending for that instance, instead of being claimed here and
    /// closed as "not configured" - which is how a re-run used to vanish without ever running.
    /// </param>
    public async Task<IReadOnlyList<RerunRequest>> ClaimPendingAsync(IReadOnlyCollection<int> labIds, CancellationToken ct)
    {
        if (labIds.Count == 0) return Array.Empty<RerunRequest>();

        // UploadId arrives with Create_MasterFileUploads.sql. Before that script is run the column
        // does not exist, and OUTPUT naming it would fail the whole claim, so it is read as NULL.
        const string sql = @"
UPDATE r
SET    Status        = 'Claimed',
       ClaimedOn     = SYSUTCDATETIME(),
       ClaimedByHost = @Host
OUTPUT inserted.RerunRequestId, inserted.LabId, inserted.LabName,
       inserted.RequestedBy, inserted.RequestedOn, inserted.Notes, {0}
FROM   dbo.MasterFileProcessorRerunRequest AS r WITH (UPDLOCK, READPAST)
WHERE  r.Status = 'Pending'
  AND  r.LabId IN ({1});";

        var claimed = new List<RerunRequest>();

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            bool hasUploadId;
            await using (var probe = new SqlCommand(
                "SELECT CAST(CASE WHEN COL_LENGTH('dbo.MasterFileProcessorRerunRequest', 'UploadId') IS NULL THEN 0 ELSE 1 END AS bit);", conn))
            {
                hasUploadId = (bool)(await probe.ExecuteScalarAsync(ct).ConfigureAwait(false) ?? false);
            }

            await using var cmd = new SqlCommand(
                string.Format(sql, hasUploadId ? "inserted.UploadId" : "CAST(NULL AS bigint)", LabIdPlaceholders(labIds)),
                conn) { CommandTimeout = 30 };
            AddLabIdParameters(cmd, labIds);
            cmd.Parameters.Add("@Host", SqlDbType.NVarChar, 200).Value = _host;

            await using var rd = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
            while (await rd.ReadAsync(ct).ConfigureAwait(false))
            {
                claimed.Add(new RerunRequest(
                    RerunRequestId: rd.GetInt64(0),
                    LabId: rd.GetInt32(1),
                    LabName: rd.IsDBNull(2) ? null : rd.GetString(2),
                    RequestedBy: rd.IsDBNull(3) ? "unknown" : rd.GetString(3),
                    RequestedOn: rd.GetDateTime(4),
                    Notes: rd.IsDBNull(5) ? null : rd.GetString(5),
                    UploadId: rd.IsDBNull(6) ? null : rd.GetInt64(6)));
            }

            if (claimed.Count > 0)
            {
                _logger.LogInformation("Claimed {Count} re-run request(s): lab(s) {Labs}.",
                    claimed.Count, string.Join(", ", claimed.Select(c => c.LabId)));
            }
        }
        catch (Exception ex)
        {
            // Including a missing table: the migration may not be deployed yet, and a worker that
            // refuses to run its schedule because an optional feature is absent is worse than one
            // that logs and carries on.
            _logger.LogWarning(ex, "Could not read the re-run request queue; continuing with the scheduled run.");
            return Array.Empty<RerunRequest>();
        }

        return claimed;
    }

    /// <summary>
    /// True when a request for one of this instance's labs is waiting. A cheap read used between
    /// scheduled passes so a re-run starts within seconds of being asked for, rather than after the
    /// full PollSeconds sleep (20 minutes in production).
    /// </summary>
    public async Task<bool> HasPendingAsync(IReadOnlyCollection<int> labIds, CancellationToken ct)
    {
        if (labIds.Count == 0) return false;

        var sql = $@"
SELECT CAST(CASE WHEN EXISTS (
           SELECT 1 FROM dbo.MasterFileProcessorRerunRequest WITH (READPAST)
           WHERE Status = 'Pending' AND LabId IN ({LabIdPlaceholders(labIds)}))
       THEN 1 ELSE 0 END AS bit);";

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
            AddLabIdParameters(cmd, labIds);
            return (bool)(await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false) ?? false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Could not check the re-run request queue.");
            return false;
        }
    }

    /// <summary>
    /// Closes requests this host claimed but never finished - the service was stopped or crashed
    /// mid-run. Called once at startup, when by definition nothing on this host is running them.
    ///
    /// <para>
    /// Without this, a Claimed row lives forever and every later request for that lab comes back
    /// "Already in progress, not queued again", so the lab can never be re-run from the screen.
    /// They are marked Failed (not re-queued): what the interrupted run already did is unknown, and
    /// the requester should decide whether to ask again.
    /// </para>
    /// </summary>
    public async Task ReleaseAbandonedClaimsAsync(CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.MasterFileProcessorRerunRequest
SET    Status        = 'Failed',
       CompletedOn   = SYSUTCDATETIME(),
       ResultStatus  = 'ABANDONED',
       ResultMessage = CONCAT('The Master File Processor on ', @Host,
                              ' was restarted while this re-run was in progress, so it did not finish. Request the re-run again.')
WHERE  Status = 'Claimed'
  AND  ClaimedByHost = @Host;";

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
            cmd.Parameters.Add("@Host", SqlDbType.NVarChar, 200).Value = _host;

            var rows = await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            if (rows > 0)
                _logger.LogWarning("Released {Count} re-run request(s) left Claimed by a previous run of this worker on {Host}.", rows, _host);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not release abandoned re-run claims for {Host}.", _host);
        }
    }

    /// <summary>
    /// Closes Pending requests for labs this instance does not run, once they have waited long
    /// enough that no other instance can be expected to pick them up. Returns the UploadIds of
    /// closed requests so the caller can purge stored upload content.
    /// </summary>
    public async Task<IReadOnlyList<long>> CloseUnclaimedOrphansAsync(
        IReadOnlyCollection<int> labIds, TimeSpan olderThan, CancellationToken ct)
    {
        var notMine = labIds.Count == 0 ? "" : $" AND LabId NOT IN ({LabIdPlaceholders(labIds)})";

        var sql = $@"
UPDATE dbo.MasterFileProcessorRerunRequest
SET    Status        = 'Completed',
       CompletedOn   = SYSUTCDATETIME(),
       ResultStatus  = 'SKIPPED',
       ResultMessage = CONCAT('No Master File Processor picked this request up within ', @Minutes,
                              ' minutes. Lab ', LabId, ' is not configured in this Master File Processor (', @Host,
                              '). Add it under MasterFileProcessor:Labs (MasterDataSource ""Upload"" for a lab with no SharePoint master folder).')
OUTPUT {{0}}
WHERE  Status = 'Pending'
  AND  RequestedOn < DATEADD(MINUTE, -@Minutes, SYSUTCDATETIME()){notMine};";

        var uploads = new List<long>();

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            bool hasUploadId;
            await using (var probe = new SqlCommand(
                "SELECT CAST(CASE WHEN COL_LENGTH('dbo.MasterFileProcessorRerunRequest', 'UploadId') IS NULL THEN 0 ELSE 1 END AS bit);", conn))
            {
                hasUploadId = (bool)(await probe.ExecuteScalarAsync(ct).ConfigureAwait(false) ?? false);
            }

            await using var cmd = new SqlCommand(
                string.Format(sql, hasUploadId ? "inserted.UploadId" : "CAST(NULL AS bigint)"), conn) { CommandTimeout = 30 };
            AddLabIdParameters(cmd, labIds);
            cmd.Parameters.Add("@Minutes", SqlDbType.Int).Value = (int)Math.Max(1, olderThan.TotalMinutes);
            cmd.Parameters.Add("@Host", SqlDbType.NVarChar, 200).Value = _host;

            await using var rd = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
            var closed = 0;
            while (await rd.ReadAsync(ct).ConfigureAwait(false))
            {
                closed++;
                if (!rd.IsDBNull(0)) uploads.Add(rd.GetInt64(0));
            }

            if (closed > 0)
                _logger.LogWarning("Closed {Count} re-run request(s) for labs no Master File Processor runs.", closed);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not close unclaimed re-run requests.");
        }

        return uploads;
    }

    private static string LabIdPlaceholders(IReadOnlyCollection<int> labIds)
        => string.Join(", ", Enumerable.Range(0, labIds.Count).Select(i => "@Lab" + i));

    private static void AddLabIdParameters(SqlCommand cmd, IReadOnlyCollection<int> labIds)
    {
        var i = 0;
        foreach (var id in labIds)
            cmd.Parameters.Add("@Lab" + i++, SqlDbType.Int).Value = id;
    }

    /// <summary>Writes the outcome back onto the request so the screen can show what happened.</summary>
    public async Task CompleteAsync(
        long rerunRequestId, string? runId, string resultStatus, string? message, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.MasterFileProcessorRerunRequest
SET    Status        = CASE WHEN @ResultStatus = 'FAILED' THEN 'Failed' ELSE 'Completed' END,
       CompletedOn   = SYSUTCDATETIME(),
       RunId         = @RunId,
       ResultStatus  = @ResultStatus,
       ResultMessage = @Message
WHERE  RerunRequestId = @Id;";

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
            cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = rerunRequestId;
            cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = (object?)runId ?? DBNull.Value;
            cmd.Parameters.Add("@ResultStatus", SqlDbType.VarChar, 30).Value = resultStatus;
            cmd.Parameters.Add("@Message", SqlDbType.NVarChar, -1).Value = (object?)LRN.MasterFileProcessorWorker.Security.PhiRedactor.Scrub(message) ?? DBNull.Value;

            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // The data is already loaded at this point. Losing the marker leaves a Claimed row for
            // somebody to clear by hand, which is a reporting gap and not a data problem.
            _logger.LogWarning(ex,
                "Re-run request {Id} finished as {Status} but the outcome could not be recorded.",
                rerunRequestId, resultStatus);
        }
    }

    /// <summary>
    /// Clears the ETag gate so the lab's current SharePoint file is treated as unseen.
    ///
    /// <para>
    /// Deleting rather than updating: <c>BillingFrequencyFileStatus</c> is keyed on the file's ETag,
    /// so the row describes one specific version of one specific file. Setting its Status to
    /// something other than PROCESSED would leave a row claiming an attempt that did not happen.
    /// Deleting lets the run insert a truthful one.
    /// </para>
    /// </summary>
    public async Task<int> ClearProcessedMarkerAsync(string fileStatusTable, int labId, CancellationToken ct)
    {
        // The table name comes from this worker's own configuration, never from a request, but it
        // is still bracket-quoted and validated rather than concatenated raw.
        if (!IsPlainTableName(fileStatusTable))
        {
            _logger.LogWarning("Refusing to clear the processed marker: '{Table}' is not a plain table name.", fileStatusTable);
            return 0;
        }

        var sql = $"DELETE FROM {QuoteTableName(fileStatusTable)} WHERE LabId = @LabId;";

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;

            var rows = await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            _logger.LogInformation("Lab {LabId}: cleared {Rows} processed-file marker(s) for the re-run.", labId, rows);
            return rows;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Lab {LabId}: could not clear the processed-file marker.", labId);
            return 0;
        }
    }

    private static bool IsPlainTableName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return false;

        foreach (var part in name.Split('.'))
        {
            var bare = part.Trim().Trim('[', ']');
            if (bare.Length == 0) return false;
            if (!bare.All(ch => char.IsLetterOrDigit(ch) || ch == '_')) return false;
            if (!bare.Any(char.IsLetterOrDigit)) return false;
        }

        return name.Split('.').Length is 1 or 2;
    }

    private static string QuoteTableName(string name) =>
        string.Join('.', name.Split('.').Select(p => "[" + p.Trim().Trim('[', ']') + "]"));
}
