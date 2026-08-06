using System.Data;
using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services.ReportLogging;

/// <summary>
/// Steps 2 and 4 of the run-logging contract: the outcome the dashboard reads.
/// Writes LRNMaster.dbo.ReportsWorkflowTracker through dbo.usp_ReportsWorkflowTracker_Upsert.
///
/// The upsert is idempotent — one row per RunId + Lab + Report — so it is called twice by
/// design: InProgress when the report starts, then the final status when it finishes.
/// A missing row is worse than a Skipped one: an absent row is indistinguishable from a
/// crashed process, so a report that decides it has nothing to do still writes Skipped.
/// </summary>
public sealed class ReportsWorkflowTrackerRepository
{
	private const string ProcedureName = "dbo.usp_ReportsWorkflowTracker_Upsert";
	private const int CommandTimeoutSeconds = 60;

	/// <summary>@Remarks is one line, not a stack trace. The full text belongs in the info log.</summary>
	private const int MaxRemarksLength = 400;

	private readonly string _connectionString;
	private readonly ProcessorOptions _options;
	private readonly ILogger<ReportsWorkflowTrackerRepository> _logger;

	public ReportsWorkflowTrackerRepository(
		IConfiguration configuration,
		IOptions<ProcessorOptions> options,
		ILogger<ReportsWorkflowTrackerRepository> logger)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
			?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
		_options = options.Value;
		_logger = logger;
	}

	/// <summary>
	/// Step 2 — has this report already succeeded for this RunId? Filtering on Status = 'Success'
	/// matters: without it a previous Failed or InProgress row would block the retry that is needed.
	/// A tracker outage returns false so the report still runs; the run log guards against a repeat.
	/// </summary>
	public async Task<bool> IsAlreadySuccessfulAsync(string runId, CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(runId))
			return false;

		const string sql = @"
SELECT COUNT(1)
FROM   dbo.ReportsWorkflowTracker
WHERE  RunId      = @RunId
  AND  ReportName = @ReportName
  AND  Status     = 'Success';";

		try
		{
			await using var conn = new SqlConnection(_connectionString);
			await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = CommandTimeoutSeconds };

			cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId.Trim();
			cmd.Parameters.Add("@ReportName", SqlDbType.VarChar, 200).Value = _options.ReportName;

			await conn.OpenAsync(ct).ConfigureAwait(false);
			var count = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false));

			return count > 0;
		}
		catch (Exception ex)
		{
			_logger.LogError(ex,
				"Could not read dbo.ReportsWorkflowTracker for RunId {RunId}. Continuing as if the report had not run.",
				runId);
			return false;
		}
	}

	/// <summary>
	/// Step 4 — record the outcome. Status must be one of <see cref="WorkflowStatus"/>.
	/// Leave <paramref name="completedOn"/> null on the opening InProgress call.
	/// Never throws: a tracker outage must not abort the run.
	/// </summary>
	public async Task UpsertAsync(
		string runId,
		string status,
		long? rowCount = null,
		DateTime? startedOn = null,
		DateTime? completedOn = null,
		string? remarks = null,
		CancellationToken ct = default)
	{
		if (string.IsNullOrWhiteSpace(runId))
		{
			_logger.LogWarning("Skipping {Status} upsert to {Procedure}: RunId is blank.", status, ProcedureName);
			return;
		}

		try
		{
			await using var conn = new SqlConnection(_connectionString);
			await using var cmd = new SqlCommand(ProcedureName, conn)
			{
				CommandType = CommandType.StoredProcedure,
				CommandTimeout = CommandTimeoutSeconds
			};

			cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId.Trim();
			cmd.Parameters.Add("@ReportName", SqlDbType.VarChar, 200).Value = _options.ReportName;
			cmd.Parameters.Add("@Status", SqlDbType.VarChar, 50).Value = status;
			cmd.Parameters.Add("@RowCount", SqlDbType.BigInt).Value = rowCount ?? (object)DBNull.Value;
			cmd.Parameters.Add("@StartedOn", SqlDbType.DateTime2, 3).Value = startedOn ?? (object)DBNull.Value;
			cmd.Parameters.Add("@CompletedOn", SqlDbType.DateTime2, 3).Value = completedOn ?? (object)DBNull.Value;
			cmd.Parameters.Add("@Remarks", SqlDbType.NVarChar, -1).Value = ShortRemark(remarks) ?? (object)DBNull.Value;
			cmd.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = _options.ReportLogCreatedBy;

			// @LabId and @WeekFolder are deliberately omitted: the RunId comes from
			// dbo.LRN_Run_Log, so the procedure resolves both for us.

			await conn.OpenAsync(ct).ConfigureAwait(false);
			await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
		}
		catch (Exception ex)
		{
			_logger.LogError(ex,
				"Failed to upsert dbo.ReportsWorkflowTracker (RunId {RunId}, Status {Status}).", runId, status);
		}
	}

	private static string? ShortRemark(string? remarks)
	{
		if (string.IsNullOrWhiteSpace(remarks))
			return null;

		var oneLine = remarks
			.Replace("\r", " ", StringComparison.Ordinal)
			.Replace("\n", " ", StringComparison.Ordinal)
			.Trim();

		return oneLine.Length <= MaxRemarksLength ? oneLine : oneLine[..MaxRemarksLength];
	}
}
