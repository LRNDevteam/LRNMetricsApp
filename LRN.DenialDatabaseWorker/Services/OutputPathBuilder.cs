namespace DenialDatabaseProcessorWorker.Services;

public sealed class OutputPathBuilder
{
	public string BuildOutputPath(
		string outputRoot,
		string labName,
		string runId,
		string yearFolder,
		string monthFolder,
		string weekFolder,
		bool createDirectory = true)
	{
		var dir = Path.Combine(outputRoot, labName, yearFolder, monthFolder, weekFolder);

		// Skipped when file generation is turned off; ExcelWriter creates the folder itself when it writes.
		if (createDirectory)
			Directory.CreateDirectory(dir);

		var fileName = $"{runId}_{labName}_DenialAnalysisReport_{weekFolder}.xlsx";
		return Path.Combine(dir, fileName);
	}
}