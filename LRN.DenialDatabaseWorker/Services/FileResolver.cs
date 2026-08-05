using DenialDatabaseProcessorWorker.Models;
using System.Globalization;
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

	/// <summary>
	/// Rebuilds the Year / Month / Week output folders when the denial rows come from
	/// PayerValidationReport instead of a workbook on disk.
	/// SourceFullPath is used when it still carries the ...\Year\Month\Week\File.xlsx shape;
	/// otherwise the week folder ("02.06.2026 - 02.12.2026") and the run date are used.
	/// </summary>
	public (string YearFolder, string MonthFolder, string WeekFolder) ExtractFolderStructure(
		string? sourceFullPath,
		string? weekFolder,
		DateTime fallbackDate)
	{
		if (!string.IsNullOrWhiteSpace(sourceFullPath))
		{
			var (year, month, week) = ExtractFolderStructure(sourceFullPath);

			if (!string.IsNullOrWhiteSpace(year) &&
				!string.IsNullOrWhiteSpace(month) &&
				!string.IsNullOrWhiteSpace(week))
			{
				return (year, month, week);
			}
		}

		var week2 = string.IsNullOrWhiteSpace(weekFolder) ? "UnknownDate" : weekFolder.Trim();
		var anchor = ExtractWeekStartDate(week2) ?? fallbackDate;

		var yearFolder = anchor.ToString("yyyy", CultureInfo.InvariantCulture);
		var monthFolder = anchor.ToString("MM.MMMM", CultureInfo.InvariantCulture);

		return (yearFolder, monthFolder, SanitizeSegment(week2));
	}

	/// <summary>Reads the start date out of a "02.06.2026 - 02.12.2026" style week folder.</summary>
	private static DateTime? ExtractWeekStartDate(string weekFolder)
	{
		var match = Regex.Match(weekFolder, @"(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{4})");

		if (!match.Success)
			return null;

		return DateTime.TryParseExact(
			$"{match.Groups[1].Value}/{match.Groups[2].Value}/{match.Groups[3].Value}",
			"M/d/yyyy",
			CultureInfo.InvariantCulture,
			DateTimeStyles.None,
			out var parsed)
			? parsed
			: null;
	}

	private static string SanitizeSegment(string value)
	{
		foreach (var c in Path.GetInvalidFileNameChars())
			value = value.Replace(c, '_');

		return value.Trim();
	}

	private Version ExtractVersion(string fileNameWithoutExtension)
	{
		var match = Regex.Match(fileNameWithoutExtension, @"_v(\d+\.\d+)$");
		return match.Success ? Version.Parse(match.Groups[1].Value) : new Version(0, 0);
	}
}