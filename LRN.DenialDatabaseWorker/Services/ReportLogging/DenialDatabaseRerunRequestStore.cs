using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace DenialDatabaseProcessorWorker.Services.ReportLogging;

/// <summary>One re-run asked for from the Report Audit Log screen, already claimed by this worker.</summary>
public sealed record RerunRequest(
	long RerunRequestId,
	int LabId,
	string? LabName,
	string RequestedBy,
	DateTime RequestedOn,
	string? Notes);

/// <summary>
/// Reads and completes LRNMaster.dbo.DenialDatabaseRerunRequest - the Denial Database Service
/// equivalent of LRN.MasterFileProcessorWorker's RerunRequestStore.
///
/// A re-run differs from a scheduled run in exactly two gates, both bypassed for a claimed lab:
/// ReportsWorkflowTracker's "already succeeded for this RunId" check, and DenialAnalysisRunLog's
/// "already recorded" check. Everything after those gates is the same code on the same path.
///
/// Every method swallows its own failures - a database hiccup reading the queue must never take the
/// scheduled run down.
/// </summary>
public sealed class DenialDatabaseRerunRequestStore
{
	private readonly string _connectionString;
	private readonly ILogger<DenialDatabaseRerunRequestStore> _logger;
	private readonly string _host;

	public DenialDatabaseRerunRequestStore(IConfiguration configuration, ILogger<DenialDatabaseRerunRequestStore> logger)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
			?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
		_logger = logger;
		_host = Environment.MachineName;
	}

	/// <summary>
	/// Takes every Pending request and marks it Claimed, in one statement, so two worker instances
	/// (or one overrunning poll) can never both claim the same row.
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
FROM   dbo.DenialDatabaseRerunRequest AS r WITH (UPDLOCK, READPAST)
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
				_logger.LogInformation("Claimed {Count} denial database re-run request(s): lab(s) {Labs}.",
					claimed.Count, string.Join(", ", claimed.Select(c => c.LabId)));
			}
		}
		catch (Exception ex)
		{
			// Including a missing table: the migration may not be deployed yet, and a worker that
			// refuses to run its schedule because an optional feature is absent is worse than one
			// that logs and carries on.
			_logger.LogWarning(ex, "Could not read the denial database re-run request queue; continuing with the scheduled run.");
			return Array.Empty<RerunRequest>();
		}

		return claimed;
	}

	/// <summary>Writes the outcome back onto the request so the screen can show what happened.</summary>
	public async Task CompleteAsync(
		long rerunRequestId, string? runId, string resultStatus, string? message, CancellationToken ct)
	{
		const string sql = @"
UPDATE dbo.DenialDatabaseRerunRequest
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
			_logger.LogWarning(ex,
				"Denial database re-run request {Id} finished as {Status} but the outcome could not be recorded.",
				rerunRequestId, resultStatus);
		}
	}
}
