using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services;

public sealed class DenialAnalysisRunLogRepository
{
	private readonly string _connectionString;
	private readonly int _commandTimeoutSeconds;

	public DenialAnalysisRunLogRepository(IConfiguration configuration, IOptions<ProcessorOptions> options)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
							?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");

		// Both statements are small, but the insert lands right after the bulk copies and can
		// queue behind their locks, so it uses the same timeout as the rest of the copy path.
		_commandTimeoutSeconds = options.Value.SqlCommandTimeoutSeconds;
	}

	public async Task<bool> ExistsAsync(string runId)
	{
		const string sql = "SELECT COUNT(1) FROM dbo.DenialAnalysisRunLog WHERE RunId = @RunId";

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		cmd.Parameters.AddWithValue("@RunId", runId);
		await conn.OpenAsync().ConfigureAwait(false);

		var count = (int)await cmd.ExecuteScalarAsync().ConfigureAwait(false);
		return count > 0;
	}

	public async Task InsertAsync(string runId, int labId,string outputfilepath)
	{
		const string sql = @"INSERT INTO dbo.DenialAnalysisRunLog (RunId, LabId, CreatedOn,OutputFileName)
                             VALUES (@RunId, @LabId, SYSUTCDATETIME(),@outputfilepath)";

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		cmd.Parameters.AddWithValue("@RunId", runId);
		cmd.Parameters.AddWithValue("@LabId", labId);
		cmd.Parameters.AddWithValue("@outputfilepath", outputfilepath);
		await conn.OpenAsync().ConfigureAwait(false);
		await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
	}
}