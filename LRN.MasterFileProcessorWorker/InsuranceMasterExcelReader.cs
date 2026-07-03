using ClosedXML.Excel;
using System.Text.RegularExpressions;

public static class InsuranceMasterExcelReader
{
	/// <summary>
	/// Resolves the latest Insurance Master Excel file from the configured seed path.
	/// Example:
	/// Config path  : D:\Master\Consolidated_Lab_Insurance Master_v1.3.xlsx
	/// Actual files : ...v1.3.xlsx, ...v1.7.xlsx
	/// Result       : ...v1.7.xlsx
	/// 
	/// Notes:
	/// - Matches by base file name, ignoring spaces/_/- differences
	/// - Prefers highest version number first
	/// - If same version exists multiple times, latest modified wins
	/// - Supports .xlsx / .xlsm
	/// </summary>
	public static string? ResolveLatestInsuranceMasterPath(string? configuredPath)
	{
		if (string.IsNullOrWhiteSpace(configuredPath))
			return null;

		var fullPath = Path.GetFullPath(configuredPath);
		var directory = Path.GetDirectoryName(fullPath);

		if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
			return null;

		var configuredFileNameWithoutExt = Path.GetFileNameWithoutExtension(fullPath);
		if (string.IsNullOrWhiteSpace(configuredFileNameWithoutExt))
			return null;

		var configuredBaseKey = NormKey(RemoveVersionSuffix(configuredFileNameWithoutExt));

		var candidates = Directory.EnumerateFiles(directory, "*.*", SearchOption.TopDirectoryOnly)
			.Where(IsSupportedExcelFile)
			.Select(path => new
			{
				Path = path,
				FileNameWithoutExt = Path.GetFileNameWithoutExtension(path)
			})
			.Where(x => NormKey(RemoveVersionSuffix(x.FileNameWithoutExt)) == configuredBaseKey)
			.Select(x => new
			{
				x.Path,
				Version = ExtractVersion(x.FileNameWithoutExt),
				LastWriteUtc = File.GetLastWriteTimeUtc(x.Path)
			})
			.OrderByDescending(x => x.Version)
			.ThenByDescending(x => x.LastWriteUtc)
			.FirstOrDefault();

		return candidates?.Path;
	}

	/// <summary>
	/// Loads Insurance Master data from Excel into the same dictionary structure
	/// used by StandardCsvExporter.
	/// Required column:
	/// - Payer_Name_Raw
	///
	/// Optional columns:
	/// - Payer_Name_Normalized
	/// - Global_Payer_ID
	/// - Payer_Code
	/// - Payer_Common_Code
	/// - Payer_Group_Code
	/// </summary>
	public static Dictionary<string, StandardCsvExporter.InsuranceMasterEntry> LoadInsuranceMasterFromExcel(
		string excelPath,
		string? worksheetName = null)
	{
		if (string.IsNullOrWhiteSpace(excelPath))
			throw new ArgumentException("Insurance master Excel path is required.", nameof(excelPath));

		if (!File.Exists(excelPath))
			throw new FileNotFoundException("Insurance master Excel file not found.", excelPath);

		if (!IsSupportedExcelFile(excelPath))
			throw new InvalidOperationException("Insurance master file must be .xlsx or .xlsm.");

		using var workbook = new XLWorkbook(excelPath);

		IXLWorksheet worksheet;
		if (!string.IsNullOrWhiteSpace(worksheetName))
		{
			worksheet = workbook.Worksheet(worksheetName);
		}
		else
		{
			worksheet = workbook.Worksheets.FirstOrDefault(w => w.RangeUsed() != null)
						?? throw new InvalidOperationException("Insurance master Excel file has no used worksheet.");
		}

		var usedRange = worksheet.RangeUsed()
					   ?? throw new InvalidOperationException("Insurance master worksheet is empty.");

		int headerRowNumber = usedRange.FirstRow().RowNumber();
		int lastRowNumber = usedRange.LastRow().RowNumber();
		int lastColumnNumber = usedRange.LastColumn().ColumnNumber();

		var idxByNorm = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

		for (int col = 1; col <= lastColumnNumber; col++)
		{
			var headerText = GetCellText(worksheet, headerRowNumber, col);
			var norm = NormKey(headerText);

			if (!string.IsNullOrWhiteSpace(norm) && !idxByNorm.ContainsKey(norm))
				idxByNorm[norm] = col;
		}

		int idxRaw = idxByNorm.TryGetValue(NormKey("Payer_Name_Raw"), out var iRaw) ? iRaw : -1;
		int idxNorm = idxByNorm.TryGetValue(NormKey("Payer_Name_Normalized"), out var iNorm) ? iNorm : -1;
		int idxLabName = idxByNorm.TryGetValue(NormKey("Lab Name"), out var iLabName) ? iLabName : -1;
		int idxGpid = idxByNorm.TryGetValue(NormKey("Global_Payer_ID"), out var iGpid) ? iGpid : -1;
		int idxPayerCode = idxByNorm.TryGetValue(NormKey("Payer_Code"), out var iPc) ? iPc : -1;
		int idxPayerCommonCode = idxByNorm.TryGetValue(NormKey("Payer_Common_Code"), out var iPcc) ? iPcc : -1;
		int idxPayerGroupCode = idxByNorm.TryGetValue(NormKey("Payer_Group_Code"), out var iPgc) ? iPgc : -1;

		if (idxRaw < 0)
			throw new InvalidOperationException("Insurance master Excel missing required column: Payer_Name_Raw");

		var map = new Dictionary<string, StandardCsvExporter.InsuranceMasterEntry>(StringComparer.OrdinalIgnoreCase);

		for (int row = headerRowNumber + 1; row <= lastRowNumber; row++)
		{
			var raw = idxRaw > 0 ? GetCellText(worksheet, row, idxRaw) : "";
			if (string.IsNullOrWhiteSpace(raw))
				continue;

			var normalized = idxNorm > 0 ? GetCellText(worksheet, row, idxNorm) : "";
			var labNameFromMaster = idxLabName > 0 ? GetCellText(worksheet, row, idxLabName) : "";

			var key = BuildInsuranceLookupKey(labNameFromMaster, raw);
			if (string.IsNullOrWhiteSpace(key))
				continue;
			var globalPayerId = idxGpid > 0 ? GetCellText(worksheet, row, idxGpid) : "";
			var payerCode = idxPayerCode > 0 ? GetCellText(worksheet, row, idxPayerCode) : "";
			var payerCommonCode = idxPayerCommonCode > 0 ? GetCellText(worksheet, row, idxPayerCommonCode) : "";
			var payerGroupCode = idxPayerGroupCode > 0 ? GetCellText(worksheet, row, idxPayerGroupCode) : "";

			// First win
			if (!map.ContainsKey(key))
			{
				map[key] = new StandardCsvExporter.InsuranceMasterEntry(
					globalPayerId,
					normalized,
					payerCode,
					payerCommonCode,
					payerGroupCode,
					labNameFromMaster);

				var payerOnlyKey = BuildInsuranceLookupKey("", raw);
				if (string.IsNullOrWhiteSpace(labNameFromMaster) && !map.ContainsKey(payerOnlyKey))
				{
					map[payerOnlyKey] = new StandardCsvExporter.InsuranceMasterEntry(
						globalPayerId,
						normalized,
						payerCode,
						payerCommonCode,
						payerGroupCode,
						labNameFromMaster);
				}
			}
		}

		return map;
	}

	private static string GetCellText(IXLWorksheet worksheet, int row, int col)
	{
		return worksheet.Cell(row, col).GetFormattedString().Trim();
	}

	private static bool IsSupportedExcelFile(string path)
	{
		var ext = Path.GetExtension(path);
		return ext.Equals(".xlsx", StringComparison.OrdinalIgnoreCase)
			|| ext.Equals(".xlsm", StringComparison.OrdinalIgnoreCase);
	}

	private static string RemoveVersionSuffix(string fileNameWithoutExtension)
	{
		if (string.IsNullOrWhiteSpace(fileNameWithoutExtension))
			return "";

		return Regex.Replace(
			fileNameWithoutExtension.Trim(),
			@"(?:[\s_-])v\d+(?:\.\d+)*$",
			"",
			RegexOptions.IgnoreCase);
	}

	private static Version ExtractVersion(string fileNameWithoutExtension)
	{
		var match = Regex.Match(
			fileNameWithoutExtension ?? "",
			@"(?:[\s_-])v(?<ver>\d+(?:\.\d+)*)$",
			RegexOptions.IgnoreCase);

		if (!match.Success)
			return new Version(0, 0, 0, 0);

		var numbers = match.Groups["ver"].Value
			.Split('.', StringSplitOptions.RemoveEmptyEntries)
			.Select(x => int.TryParse(x, out var n) ? n : 0)
			.ToList();

		while (numbers.Count < 4)
			numbers.Add(0);

		return new Version(numbers[0], numbers[1], numbers[2], numbers[3]);
	}

	private static string BuildInsuranceLookupKey(string? labName, string? payerRaw)
	{
		var payerKey = NormKey(payerRaw ?? "");
		if (string.IsNullOrWhiteSpace(payerKey))
			return "";

		var labKey = NormKey(labName ?? "");
		return string.IsNullOrWhiteSpace(labKey) ? payerKey : $"{labKey}|{payerKey}";
	}

	private static string NormKey(string s)
	{
		if (string.IsNullOrWhiteSpace(s))
			return "";

		s = s.Trim().ToLowerInvariant();
		return Regex.Replace(s, @"[^a-z0-9]+", "");
	}
}