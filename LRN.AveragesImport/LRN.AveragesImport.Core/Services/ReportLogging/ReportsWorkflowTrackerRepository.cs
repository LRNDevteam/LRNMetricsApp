using System.Data;
using LRN.AveragesImport.Core.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace LRN.AveragesImport.Core.Services.ReportLogging;

/// <summary>
/// Steps 2 and 4 of the run-logging contract: the outcome the dashboard reads.
/// Writes LRNMaster.dbo.ReportsWorkflowTracker through dbo.usp_ReportsWorkflowTracker_Upsert.
///
/// The upsert is idempotent — one row per RunId + Lab + Report — so it is called twice by
/// design: InProgress when the report starts, then the final status when it finishes.
/// A missing row is worse than a Skipped one: an absent row is indistinguishable from a
/// crashed process, so an aggregate that decides it has nothing to do still writes Skipped.
/// </summary>
public sealed class ReportsWorkflowTrackerRepository
{
    private const string ProcedureName = "dbo.usp_ReportsWorkflowTracker_Upsert";
    private const int CommandTimeoutSeconds = 60;

    /// <summary>@Remarks is one line, not a stack trace. The full text belongs in the info log.</summary>
    private const int MaxRemarksLength = 400;

    private readonly ISqlConnectionFactory _connectionFactory;
    private readonly ILogger<ReportsWorkflowTrackerRepository> _logger;

    public ReportsWorkflowTrackerRepository(ISqlConnectionFactory connectionFactory, ILogger<ReportsWorkflowTrackerRepository> logger)
    {
        _connectionFactory = connectionFactory;
        _logger = logger;
    }

    /// <summary>
    /// Step 2 — has this report already succeeded for this RunId? Filtering on Status = 'Success'
    /// matters: without it a previous Failed or InProgress row would block the retry that is needed.
    /// A tracker outage returns false so the report still runs; the AverageImportLog and the RunId
    /// stamped on the average tables still guard against writing the same run twice.
    /// </summary>
    public async Task<bool> IsAlreadySuccessfulAsync(string runId, string reportName, CancellationToken ct)
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
            await using var connection = _connectionFactory.Create();
            await using var command = new SqlCommand(sql, connection) { CommandTimeout = CommandTimeoutSeconds };

            command.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId.Trim();
            command.Parameters.Add("@ReportName", SqlDbType.VarChar, 200).Value = reportName;

            await connection.OpenAsync(ct).ConfigureAwait(false);
            var count = Convert.ToInt32(await command.ExecuteScalarAsync(ct).ConfigureAwait(false));

            return count > 0;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex,
                "Could not read dbo.ReportsWorkflowTracker for RunId {RunId}, report {ReportName}. Continuing as if it had not run.",
                runId, reportName);
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
        string reportName,
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
            await using var connection = _connectionFactory.Create();
            await using var command = new SqlCommand(ProcedureName, connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = CommandTimeoutSeconds
            };

            command.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId.Trim();
            command.Parameters.Add("@ReportName", SqlDbType.VarChar, 200).Value = reportName;
            command.Parameters.Add("@Status", SqlDbType.VarChar, 50).Value = status;
            command.Parameters.Add("@RowCount", SqlDbType.BigInt).Value = rowCount ?? (object)DBNull.Value;
            command.Parameters.Add("@StartedOn", SqlDbType.DateTime2, 3).Value = startedOn ?? (object)DBNull.Value;
            command.Parameters.Add("@CompletedOn", SqlDbType.DateTime2, 3).Value = completedOn ?? (object)DBNull.Value;
            command.Parameters.Add("@Remarks", SqlDbType.NVarChar, -1).Value = ShortRemark(remarks) ?? (object)DBNull.Value;
            command.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = ReportRunIdInfoLogger.CreatedBy;

            // @LabId and @WeekFolder are deliberately omitted: the RunId comes from
            // sp_GetRecentSuccessRunByLab (and so from dbo.LRN_Run_Log), which lets the
            // procedure resolve both for us.

            await connection.OpenAsync(ct).ConfigureAwait(false);
            await command.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex,
                "Failed to upsert dbo.ReportsWorkflowTracker (RunId {RunId}, report {ReportName}, Status {Status}).",
                runId, reportName, status);
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
