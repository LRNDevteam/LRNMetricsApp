using DenialDatabaseProcessorWorker.Models;
using System.Text.RegularExpressions;

namespace DenialDatabaseProcessorWorker.Services;

public sealed class FileResolver
{
	public string GetLatestPayerPolicyFile(LabConfig lab)
	{
		var root = lab.PayerPolicyFile; // treated as folder root

		if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
			throw new DirectoryNotFoundException($"PayerPolicy root not found: {root}");

		var yearDir = Directory.GetDirectories(root)
			.OrderByDescending(Path.GetFileName)
			.FirstOrDefault() ?? throw new InvalidOperationException("No year folder found.");

		var monthDir = Directory.GetDirectories(yearDir)
			.OrderByDescending(Path.GetFileName)
			.FirstOrDefault() ?? throw new InvalidOperationException("No month folder found.");

		var weekDir = Directory.GetDirectories(monthDir)
			.OrderByDescending(Path.GetFileName)
			.FirstOrDefault() ?? throw new InvalidOperationException("No week folder found.");

		var payerFile = Directory.GetFiles(weekDir, "*_Payer_Policy_ValidationReport.xlsx")
			.OrderByDescending(File.GetCreationTimeUtc)
			.FirstOrDefault() ?? throw new InvalidOperationException("No Payer Policy file found.");

		return payerFile;
	}

	public string GetLatestClaimActionMapper(LabConfig lab)
	{
		var root = lab.ClaimActionMapper; // treated as folder root

		if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
			throw new DirectoryNotFoundException($"ClaimActionMapper root not found: {root}");

		var files = Directory.GetFiles(root, "*Denial_Action_Classifier_v*.xlsx");
		if (files.Length == 0)
			throw new InvalidOperationException("No Claim Action Mapper files found.");

		string latest = files
			.OrderByDescending(f => ExtractVersion(Path.GetFileNameWithoutExtension(f)))
			.First();

		return latest;
	}

	public string ExtractRunId(string payerPolicyFilePath)
	{
		var file = Path.GetFileName(payerPolicyFilePath);
		return file.Split('_')[0];
	}

	public (string YearFolder, string MonthFolder, string WeekFolder) ExtractFolderStructure(string payerPolicyFile)
	{
		var weekFolder = Path.GetFileName(Path.GetDirectoryName(payerPolicyFile));
		var monthFolder = Path.GetFileName(Path.GetDirectoryName(Path.GetDirectoryName(payerPolicyFile)));
		var yearFolder = Path.GetFileName(Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(payerPolicyFile))));

		return (yearFolder, monthFolder, weekFolder);
	}

	private Version ExtractVersion(string fileNameWithoutExtension)
	{
		var match = Regex.Match(fileNameWithoutExtension, @"_v(\d+\.\d+)$");
		return match.Success ? Version.Parse(match.Groups[1].Value) : new Version(0, 0);
	}
}