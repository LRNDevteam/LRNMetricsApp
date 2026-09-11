using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LRN.MasterFileProcessorWorker.ProcessLogging;

/// <summary>One re-run asked for from the Report Audit Log screen, already claimed by this worker.</summary>
public sealed record RerunRequest(
    long RerunRequestId,
    int LabId,
    string? LabName,
    string RequestedBy,
    DateTime RequestedOn,
    string? Notes);

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
    public async Task<IReadOnlyList<RerunRequest>> ClaimPendingAsync(CancellationToken ct)
    {
        const string sql = @"
UPDATE r
SET    Status        = 'Claimed',
       ClaimedOn     = SYSUTCDATETIME(),
       ClaimedByHost = @Host
OUTPUT inserted.RerunRequestId, inserted.LabId, inserted.LabName,
       inserted.RequestedBy, inserted.RequestedOn, inserted.Notes
FROM   dbo.MasterFileProcessorRerunRequest AS r WITH (UPDLOCK, READPAST)
WHERE  r.Status = 'Pending';";

        var claimed = new List<RerunRequest>();

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
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
                    Notes: rd.IsDBNull(5) ? null : rd.GetString(5)));
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
            cmd.Parameters.Add("@Message", SqlDbType.NVarChar, -1).Value = (object?)message ?? DBNull.Value;

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
