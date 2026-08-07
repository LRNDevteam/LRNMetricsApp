using System.Data;
using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services.ReportLogging;

/// <summary>One row from dbo.sp_GetRecentSuccessRunByLab.</summary>
public sealed record RecentSuccessRun(
	string RunId,
	string LabName,
	string OverallStatus,
	DateTime? StartTimeIst,
	DateTime? EndTimeIst);

/// <summary>
/// Step 1 of the run-logging contract: the RunId this report attaches itself to.
/// A report never invents a RunId — it works under the lab's most recent successful
/// run in LRNMaster.dbo.LRN_Run_Log, which is what the stored procedure returns.
/// </summary>
public sealed class RecentSuccessRunProvider
{
	private const int CommandTimeoutSeconds = 120;
	private const string SuccessStatus = "SUCCESS";

	private readonly string _connectionString;
	private readonly ProcessorOptions _options;
	private readonly ILogger<RecentSuccessRunProvider> _logger;

	public RecentSuccessRunProvider(
		IConfiguration configuration,
		IOptions<ProcessorOptions> options,
		ILogger<RecentSuccessRunProvider> logger)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
			?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
		_options = options.Value;
		_logger = logger;
	}

	/// <summary>
	/// Returns the newest successful run for the lab, or null when the lab has none yet.
	/// A lab with no successful run is not an error — there is simply nothing to report on.
	/// </summary>
	public async Task<RecentSuccessRun?> GetLatestSuccessRunAsync(string labName, CancellationToken ct)
	{
		var wanted = (labName ?? "").Trim();
		var rows = new List<RecentSuccessRun>();

		await using (var conn = new SqlConnection(_connectionString))
		{
			await using var cmd = new SqlCommand(_options.RecentSuccessRunProcedure, conn)
			{
				CommandType = CommandType.StoredProcedure,
				CommandTimeout = CommandTimeoutSeconds
			};

			cmd.Parameters.Add("@LabName", SqlDbType.NVarChar, 50).Value =
				string.IsNullOrWhiteSpace(wanted) ? DBNull.Value : wanted;

			await conn.OpenAsync(ct).ConfigureAwait(false);
			await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

			while (await reader.ReadAsync(ct).ConfigureAwait(false))
			{
				var runId = (GetString(reader, "RunID") ?? "").Trim();
				var lab = (GetString(reader, "LabName") ?? "").Trim();
				var status = (GetString(reader, "OverallStatus") ?? "").Trim();

				if (string.IsNullOrWhiteSpace(runId))
				{
					_logger.LogWarning("{Procedure} returned a row with a blank RunID for lab {LabName} — skipped.",
						_options.RecentSuccessRunProcedure, lab);
					continue;
				}

				if (!string.Equals(status, SuccessStatus, StringComparison.OrdinalIgnoreCase))
					continue;

				rows.Add(new RecentSuccessRun(
					RunId: runId,
					LabName: lab,
					OverallStatus: status,
					StartTimeIst: GetDateTime(reader, "StartTimeIST"),
					EndTimeIst: GetDateTime(reader, "EndTimeIST")));
			}
		}

		if (rows.Count == 0)
			return null;

		// @LabName is matched with LIKE '%name%', so a short configured name can pull back
		// more than one lab. Prefer the exact name before falling back to the newest match.
		var exact = rows
			.Where(r => string.Equals(r.LabName, wanted, StringComparison.OrdinalIgnoreCase))
			.ToList();

		var candidates = exact.Count > 0 ? exact : rows;

		if (exact.Count == 0 && rows.Count > 1)
		{
			_logger.LogWarning(
				"{Procedure} returned {Count} labs for '{LabName}' and none matched exactly. Using the most recent run.",
				_options.RecentSuccessRunProcedure, rows.Count, wanted);
		}

		return candidates
			.OrderByDescending(r => r.EndTimeIst ?? DateTime.MinValue)
			.ThenByDescending(r => r.RunId, StringComparer.OrdinalIgnoreCase)
			.First();
	}

	private static string? GetString(SqlDataReader reader, string column)
	{
		var ordinal = reader.GetOrdinal(column);
		return reader.IsDBNull(ordinal) ? null : reader.GetValue(ordinal).ToString();
	}

	private static DateTime? GetDateTime(SqlDataReader reader, string column)
	{
		var ordinal = reader.GetOrdinal(column);
		return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
	}
}
