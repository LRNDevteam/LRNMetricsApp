using System.Data;
using LRN.AveragesImport.Core.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace LRN.AveragesImport.Core.Services.ReportLogging;

/// <summary>
/// Step 3 of the run-logging contract: the progress trail.
/// Writes LRNMaster.dbo.ReportRunIdInfoLog through dbo.usp_ReportRunIdInfoLog_Insert — never
/// directly, so the procedure keeps resolving the lab, week folder and report type.
///
/// Logging must never break the report: every failure is swallowed and written to the
/// worker's own log instead. A logging outage costs a log row, not a night's processing.
///
/// Never log patient data. Counts, table names and durations are fine; patient names, DOBs,
/// addresses, member/policy numbers and SSNs must never appear. Everything this worker logs
/// is aggregate — row counts and table names — so nothing patient-level can reach it.
/// </summary>
public sealed class ReportRunIdInfoLogger
{
    private const string ProcedureName = "dbo.usp_ReportRunIdInfoLog_Insert";
    private const int CommandTimeoutSeconds = 60;

    /// <summary>@CreatedBy is the process identity, never a person.</summary>
    public const string CreatedBy = "LRN Averages Import Service";

    private readonly ISqlConnectionFactory _connectionFactory;
    private readonly ILogger<ReportRunIdInfoLogger> _logger;

    public ReportRunIdInfoLogger(ISqlConnectionFactory connectionFactory, ILogger<ReportRunIdInfoLogger> logger)
    {
        _connectionFactory = connectionFactory;
        _logger = logger;
    }

    /// <summary>The report begins. One per report per run.</summary>
    public Task StartAsync(string runId, string reportName, string sourceSystem, string message, string? sourceName = null, CancellationToken ct = default)
        => WriteAsync(runId, reportName, sourceSystem, RunLogType.Start, message, sourceName, ct);

    /// <summary>A meaningful milestone: source read, N rows produced, table loaded.</summary>
    public Task InfoAsync(string runId, string reportName, string sourceSystem, string message, string? sourceName = null, CancellationToken ct = default)
        => WriteAsync(runId, reportName, sourceSystem, RunLogType.Info, message, sourceName, ct);

    /// <summary>Something is off but the run continues.</summary>
    public Task WarningAsync(string runId, string reportName, string sourceSystem, string message, string? sourceName = null, CancellationToken ct = default)
        => WriteAsync(runId, reportName, sourceSystem, RunLogType.Warning, message, sourceName, ct);

    /// <summary>The failure. The full exception text goes here; the tracker only carries a short remark.</summary>
    public Task ErrorAsync(string runId, string reportName, string sourceSystem, Exception exception, string? sourceName = null, CancellationToken ct = default)
        => WriteAsync(runId, reportName, sourceSystem, RunLogType.Error, exception.ToString(), sourceName, ct);

    /// <summary>
    /// Same as <see cref="ErrorAsync"/> for a failure reported as text rather than as a live
    /// exception — the import path catches its own exceptions and hands back a message.
    /// </summary>
    public Task WriteErrorAsync(string runId, string reportName, string sourceSystem, string errorText, string? sourceName = null, CancellationToken ct = default)
        => WriteAsync(runId, reportName, sourceSystem, RunLogType.Error, errorText, sourceName, ct);

    /// <summary>The report finishes, whether it succeeded or failed. One per report per run.</summary>
    public Task EndAsync(string runId, string reportName, string sourceSystem, string message, string? sourceName = null, CancellationToken ct = default)
        => WriteAsync(runId, reportName, sourceSystem, RunLogType.End, message, sourceName, ct);

    private async Task WriteAsync(
        string runId,
        string reportName,
        string sourceSystem,
        string logType,
        string? message,
        string? sourceName,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(runId))
        {
            // The procedure rejects a blank RunId; say so here rather than raising SQL noise.
            _logger.LogWarning("Skipping {LogType} row for {Procedure}: RunId is blank.", logType, ProcedureName);
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
            command.Parameters.Add("@ReportType", SqlDbType.VarChar, 100).Value = reportName;
            command.Parameters.Add("@SourceSystem", SqlDbType.VarChar, 100).Value = Text(sourceSystem) ?? (object)DBNull.Value;

            // @SourceFileName predates the move off CSV; it now carries the source table
            // the aggregate was computed from, e.g. "Augustus_LRN.dbo.LineLevelData".
            // Sized 800 to match the procedure as deployed — the guide's 400 is out of date.
            command.Parameters.Add("@SourceFileName", SqlDbType.NVarChar, 800).Value = Text(sourceName) ?? (object)DBNull.Value;

            command.Parameters.Add("@LogType", SqlDbType.VarChar, 50).Value = logType;
            command.Parameters.Add("@LogMessage", SqlDbType.NVarChar, -1).Value = Text(message) ?? (object)DBNull.Value;
            command.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = CreatedBy;

            await connection.OpenAsync(ct).ConfigureAwait(false);
            await command.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to write a {LogType} row to dbo.ReportRunIdInfoLog for RunId {RunId}, report {ReportName}.",
                logType, runId, reportName);
        }
    }

    private static string? Text(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
