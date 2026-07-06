using Microsoft.Data.SqlClient;

namespace DenialDatabaseProcessorWorker.Services;

public sealed class ErrorLogger : IErrorLogger
{
	private readonly string _connectionString;

	public ErrorLogger(IConfiguration config)
	{
		_connectionString = config.GetConnectionString("DenialDatabase")
			?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
	}

	public async Task LogAsync(
		string runId,
		string labName,
		string stepName,
		string payerPolicyFile,
		string payerPolicyPath,
		Exception exception,
		CancellationToken ct)
	{
		const string sql = @"
            INSERT INTO dbo.LRN_Error_Log
            (
                RunID,
                LabName,
                ErrorTimeIST,
                Severity,
                StepName,
                ErrorCode,
                ErrorSummary,
                MissingColumns,
                SheetName,
                FileName,
                FilePath,
                RowExample,
                RecommendedAction,
                OwnerTeam,
                TicketID,
                Status,
                SourceSystem
            )
            VALUES
            (
                @RunID,
                @LabName,
                SYSUTCDATETIME(),
                'Medium',
                @StepName,
                'Error',
                @ErrorSummary,
                NULL,
                NULL,
                @FileName,
                @FilePath,
                '',
                '',
                '',
                '',
                'Open',
                'Denial Report analysis system'
            );
        ";

		try
		{
			await using var conn = new SqlConnection(_connectionString);
			await using var cmd = new SqlCommand(sql, conn);

			cmd.Parameters.AddWithValue("@RunID", runId);
			cmd.Parameters.AddWithValue("@LabName", labName);
			cmd.Parameters.AddWithValue("@StepName", stepName);
			cmd.Parameters.AddWithValue("@ErrorSummary", exception.ToString());
			cmd.Parameters.AddWithValue("@FileName", payerPolicyFile);
			cmd.Parameters.AddWithValue("@FilePath", payerPolicyPath);

			// Do NOT let cancellation kill error logging; swallow OperationCanceledException
			await conn.OpenAsync(CancellationToken.None);
			await cmd.ExecuteNonQueryAsync(CancellationToken.None);
		}
		catch (Exception)
		{
			// Last line of defense: never throw from error logger
			// You can optionally write to Windows Event Log here if needed.
		}
	}
}