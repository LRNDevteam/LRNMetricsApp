namespace DenialDatabaseProcessorWorker.Services;

public sealed class OutputPathBuilder
{
	public string BuildOutputPath(
		string outputRoot,
		string labName,
		string runId,
		string yearFolder,
		string monthFolder,
		string weekFolder)
	{
		var dir = Path.Combine(outputRoot, labName, yearFolder, monthFolder, weekFolder);
		Directory.CreateDirectory(dir);

		var fileName = $"{runId}_{labName}_DenialAnalysisReport_{weekFolder}.xlsx";
		return Path.Combine(dir, fileName);
	}
}