namespace DenialDatabaseProcessorWorker.Services;

public interface IErrorLogger
{
	Task LogAsync(
		string runId,
		string labName,
		string stepName,
		string payerPolicyFile,
		string payerPolicyPath,
		Exception exception,
		CancellationToken ct);
}