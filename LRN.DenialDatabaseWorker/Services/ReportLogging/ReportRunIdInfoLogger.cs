using System.Data;
using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services.ReportLogging;

/// <summary>
/// Step 3 of the run-logging contract: the progress trail.
/// Writes LRNMaster.dbo.ReportRunIdInfoLog through dbo.usp_ReportRunIdInfoLog_Insert — never
/// directly, so the procedure keeps resolving the lab, week folder and report type.
///
/// Logging must never break the report: every failure is swallowed and written to the
/// worker's own log instead. A logging outage costs a log row, not a night's processing.
///
/// Never log patient data. Counts, file names, table names and durations are fine;
/// patient names, DOBs, addresses, member/policy numbers and SSNs must never appear.
/// </summary>
public sealed class ReportRunIdInfoLogger
{
	private const string ProcedureName = "dbo.usp_ReportRunIdInfoLog_Insert";
	private const int CommandTimeoutSeconds = 60;

	private readonly string _connectionString;
	private readonly ProcessorOptions _options;
	private readonly ILogger<ReportRunIdInfoLogger> _logger;

	public ReportRunIdInfoLogger(
		IConfiguration configuration,
		IOptions<ProcessorOptions> options,
		ILogger<ReportRunIdInfoLogger> logger)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
			?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
		_options = options.Value;
		_logger = logger;
	}

	/// <summary>The report begins. One per report per run.</summary>
	public Task StartAsync(string runId, string sourceSystem, string message, string? sourceFileName = null, CancellationToken ct = default)
		=> WriteAsync(runId, sourceSystem, RunLogType.Start, message, sourceFileName, ct);

	/// <summary>A meaningful milestone: source read, N rows produced, table loaded.</summary>
	public Task InfoAsync(string runId, string sourceSystem, string message, string? sourceFileName = null, CancellationToken ct = default)
		=> WriteAsync(runId, sourceSystem, RunLogType.Info, message, sourceFileName, ct);

	/// <summary>Something is off but the run continues.</summary>
	public Task WarningAsync(string runId, string sourceSystem, string message, string? sourceFileName = null, CancellationToken ct = default)
		=> WriteAsync(runId, sourceSystem, RunLogType.Warning, message, sourceFileName, ct);

	/// <summary>The failure. The full exception text goes here; the tracker only carries a short remark.</summary>
	public Task ErrorAsync(string runId, string sourceSystem, Exception exception, string? sourceFileName = null, CancellationToken ct = default)
		=> WriteAsync(runId, sourceSystem, RunLogType.Error, exception.ToString(), sourceFileName, ct);

	/// <summary>The report finishes, whether it succeeded or failed. One per report per run.</summary>
	public Task EndAsync(string runId, string sourceSystem, string message, string? sourceFileName = null, CancellationToken ct = default)
		=> WriteAsync(runId, sourceSystem, RunLogType.End, message, sourceFileName, ct);

	private async Task WriteAsync(
		string runId,
		string sourceSystem,
		string logType,
		string? message,
		string? sourceFileName,
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
			await using var conn = new SqlConnection(_connectionString);
			await using var cmd = new SqlCommand(ProcedureName, conn)
			{
				CommandType = CommandType.StoredProcedure,
				CommandTimeout = CommandTimeoutSeconds
			};

			cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId.Trim();
			cmd.Parameters.Add("@ReportType", SqlDbType.VarChar, 100).Value = _options.ReportName;
			cmd.Parameters.Add("@SourceSystem", SqlDbType.VarChar, 100).Value = Text(sourceSystem) ?? (object)DBNull.Value;
			cmd.Parameters.Add("@SourceFileName", SqlDbType.NVarChar, 400).Value = Text(sourceFileName) ?? (object)DBNull.Value;
			cmd.Parameters.Add("@LogType", SqlDbType.VarChar, 50).Value = logType;
			cmd.Parameters.Add("@LogMessage", SqlDbType.NVarChar, -1).Value = Text(message) ?? (object)DBNull.Value;
			cmd.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = _options.ReportLogCreatedBy;

			await conn.OpenAsync(ct).ConfigureAwait(false);
			await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
		}
		catch (Exception ex)
		{
			_logger.LogError(ex, "Failed to write a {LogType} row to dbo.ReportRunIdInfoLog for RunId {RunId}.", logType, runId);
		}
	}

	private static string? Text(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
