using ClosedXML.Excel;
using Microsoft.VisualBasic.FileIO;
using System.Globalization;

public static class ModeMedianPaymentReportWriter
{
	public static void Generate(string lineLevelStandardCsvPath, string outputWorkbookPath)
	{
		GenerateMedianFile(lineLevelStandardCsvPath, outputWorkbookPath);
	}

	public static void GenerateSeparateFiles(
		string lineLevelStandardCsvPath,
		string medianOutputWorkbookPath,
		string modeOutputWorkbookPath)
	{
		var reportRows = BuildReport(lineLevelStandardCsvPath);
		WriteSeparateFiles(reportRows, medianOutputWorkbookPath, modeOutputWorkbookPath);
	}

	public static IReadOnlyList<PaymentReportRow> BuildReport(string lineLevelStandardCsvPath)
	{
		if (string.IsNullOrWhiteSpace(lineLevelStandardCsvPath))
			throw new ArgumentException("LineLevel standard CSV path is required.", nameof(lineLevelStandardCsvPath));

		if (!File.Exists(lineLevelStandardCsvPath))
			throw new FileNotFoundException("LineLevel standard CSV not found.", lineLevelStandardCsvPath);

		var allRows = ReadRows(lineLevelStandardCsvPath);

		return BuildReportRows(allRows)
			.OrderBy(x => x.PayerName, StringComparer.OrdinalIgnoreCase)
			.ThenBy(x => x.Panel, StringComparer.OrdinalIgnoreCase)
			.ThenBy(x => x.CPTCode, StringComparer.OrdinalIgnoreCase)
			.ThenBy(x => x.RollingDays, StringComparer.OrdinalIgnoreCase)
			.ThenBy(x => x.AllowedAmount ?? decimal.MinValue)
			.ThenBy(x => x.InsurancePaymentAmount ?? decimal.MinValue)
			.ToList();
	}

	public static void WriteSeparateFiles(
		IReadOnlyList<PaymentReportRow> reportRows,
		string medianOutputWorkbookPath,
		string modeOutputWorkbookPath)
	{
		if (!string.IsNullOrWhiteSpace(medianOutputWorkbookPath))
		{
			EnsureDirectory(medianOutputWorkbookPath);
			using var medianWorkbook = new XLWorkbook();
			WriteMedianSheet(medianWorkbook, reportRows);
			medianWorkbook.SaveAs(medianOutputWorkbookPath);
		}

		if (!string.IsNullOrWhiteSpace(modeOutputWorkbookPath))
		{
			EnsureDirectory(modeOutputWorkbookPath);
			using var modeWorkbook = new XLWorkbook();
			WriteModeSheet(modeWorkbook, reportRows);
			modeWorkbook.SaveAs(modeOutputWorkbookPath);
		}
	}

	public static void GenerateMedianFile(string lineLevelStandardCsvPath, string medianOutputWorkbookPath)
	{
		GenerateSeparateFiles(lineLevelStandardCsvPath, medianOutputWorkbookPath, string.Empty);
	}

	public static void GenerateModeFile(string lineLevelStandardCsvPath, string modeOutputWorkbookPath)
	{
		GenerateSeparateFiles(lineLevelStandardCsvPath, string.Empty, modeOutputWorkbookPath);
	}

	private static void EnsureDirectory(string outputWorkbookPath)
	{
		var outputDirectory = Path.GetDirectoryName(outputWorkbookPath);
		if (!string.IsNullOrWhiteSpace(outputDirectory))
			Directory.CreateDirectory(outputDirectory);
	}

	//public static void Generate(string lineLevelStandardCsvPath, string outputWorkbookPath)
	//{
	//	if (string.IsNullOrWhiteSpace(lineLevelStandardCsvPath))
	//		throw new ArgumentException("LineLevel standard CSV path is required.", nameof(lineLevelStandardCsvPath));

	//	if (!File.Exists(lineLevelStandardCsvPath))
	//		throw new FileNotFoundException("LineLevel standard CSV not found.", lineLevelStandardCsvPath);

	//	var outputDirectory = Path.GetDirectoryName(outputWorkbookPath);
	//	if (!string.IsNullOrWhiteSpace(outputDirectory))
	//		Directory.CreateDirectory(outputDirectory);

	//	var allRows = ReadRows(lineLevelStandardCsvPath);

	//	var reportRows = BuildReportRows(allRows)
	//		.OrderBy(x => x.PayerName, StringComparer.OrdinalIgnoreCase)
	//		.ThenBy(x => x.Panel, StringComparer.OrdinalIgnoreCase)
	//		.ThenBy(x => x.CPTCode, StringComparer.OrdinalIgnoreCase)
	//		.ThenBy(x => x.AllowedAmount ?? decimal.MinValue)
	//		.ThenBy(x => x.InsurancePaymentAmount ?? decimal.MinValue)
	//		.ToList();

	//	using var workbook = new XLWorkbook();
	//	WriteMedianSheet(workbook, reportRows);
	//	WriteModeSheet(workbook, reportRows);
	//	workbook.SaveAs(outputWorkbookPath);
	//}

	private static List<PaymentRow> ReadRows(string csvPath)
	{
		using var parser = new TextFieldParser(csvPath);
		parser.SetDelimiters(",");
		parser.HasFieldsEnclosedInQuotes = true;
		parser.TrimWhiteSpace = false;

		var header = parser.ReadFields() ?? Array.Empty<string>();
		if (header.Length == 0)
			return new List<PaymentRow>();

		int payerIdx = FindHeaderIndex(header, "PayerName");
		int panelIdx = FindHeaderIndex(header, "Panel", "Panelname", "PanelName", "Panel Name", "Panel Group");
		int cptIdx = FindHeaderIndex(header, "CPTCode", "CPT Code");
		int allowedIdx = FindHeaderIndex(header, "AllowedAmount", "Allowed Amount");
		int insuranceIdx = FindHeaderIndex(header, "InsurancePayment", "InsurancePaymentAmount", "Insurance Payment", "Insurance Payment Amount");

		int allowedPerUnitIdx = FindHeaderIndexOptional(
			header,
			"AllowedAmountPerUnit",
			"Allowed Amount Per Unit",
			"AllowedPerUnit",
			"Allowed Amt Per Unit");

		int insurancePerUnitIdx = FindHeaderIndexOptional(
			header,
			"InsurancePaymentPerUnit",
			"Insurance Payment Per Unit",
			"InsurancePaymentAmountPerUnit",
			"Insurance Payment Amount Per Unit",
			"PaidAmountPerUnit",
			"Paid Amount Per Unit",
			"Insurance Paid Per Unit");

		int rollingDaysIdx = FindHeaderIndexOptional(header, "RollingDays", "Rolling Days");
		int dateOfServiceIdx = FindHeaderIndexOptional(header, "DateofService", "Date of Service", "DateOfService", "DOS");

		if (payerIdx < 0 || panelIdx < 0 || cptIdx < 0 || allowedIdx < 0 || insuranceIdx < 0)
		{
			throw new InvalidOperationException(
				$"Required columns not found in LineLevel standard CSV. " +
				$"PayerName={payerIdx}, Panel={panelIdx}, CPTCode={cptIdx}, AllowedAmount={allowedIdx}, InsurancePayment={insuranceIdx}.");
		}

		var rows = new List<PaymentRow>();

		while (!parser.EndOfData)
		{
			var fields = parser.ReadFields();
			if (fields == null || fields.All(string.IsNullOrWhiteSpace))
				continue;

			var payerName = ReadField(fields, payerIdx).Trim();
			var panel = ReadField(fields, panelIdx).Trim();
			var cptCode = NormalizeCptCode(ReadField(fields, cptIdx));
			var allowedAmount = ParseNullableDecimal(ReadField(fields, allowedIdx));
			var insurancePaymentAmount = ParseNullableDecimal(ReadField(fields, insuranceIdx));
			var allowedAmountPerUnit = ParseNullableDecimal(ReadField(fields, allowedPerUnitIdx));
			var insurancePaymentPerUnit = ParseNullableDecimal(ReadField(fields, insurancePerUnitIdx));
			var rollingDays = ReadField(fields, rollingDaysIdx).Trim();
			var dateOfService = ParseNullableDate(ReadField(fields, dateOfServiceIdx));

			rows.Add(new PaymentRow(
				payerName,
				panel,
				cptCode,
				allowedAmount,
				insurancePaymentAmount,
				allowedAmountPerUnit,
				insurancePaymentPerUnit,
				rollingDays,
				dateOfService));
		}

		return rows;
	}

	private static int FindHeaderIndexOptional(string[] header, params string[] aliases)
	{
		for (int i = 0; i < header.Length; i++)
		{
			var current = NormalizeHeader(header[i]);
			foreach (var alias in aliases)
			{
				if (current == NormalizeHeader(alias))
					return i;
			}
		}

		return -1;
	}

	private static decimal? GetHighestValue(IReadOnlyList<decimal> values)
	{
		if (values == null || values.Count == 0)
			return null;

		return values.Max();
	}

	private static decimal? CalculatePaymentModeForSelectedAllowed(
		IReadOnlyList<PaymentRow> rows,
		decimal? selectedAllowedValue,
		Func<PaymentRow, decimal?> allowedSelector,
		Func<PaymentRow, decimal?> paymentSelector)
	{
		if (!selectedAllowedValue.HasValue)
			return null;

		var candidatePayments = rows
			.Where(r => allowedSelector(r).HasValue && allowedSelector(r)!.Value == selectedAllowedValue.Value)
			.Select(paymentSelector)
			.Where(v => v.HasValue)
			.Select(v => v!.Value)
			.ToList();

		if (candidatePayments.Count == 0)
			return null;

		return candidatePayments
			.GroupBy(x => x)
			.Select(g => new { Value = g.Key, Count = g.Count() })
			.OrderByDescending(x => x.Count)
			.ThenByDescending(x => x.Value)
			.Select(x => (decimal?)x.Value)
			.FirstOrDefault();
	}
	private static IEnumerable<PaymentReportRow> BuildReportRows(IEnumerable<PaymentRow> rows)
	{
		var filteredRows = rows
			.Where(r =>
				(!string.IsNullOrWhiteSpace(r.PayerName)
				 || !string.IsNullOrWhiteSpace(r.Panel)
				 || !string.IsNullOrWhiteSpace(r.CPTCode))
				&& r.InsurancePaymentAmount.HasValue
				&& r.InsurancePaymentAmount.Value > 0)
			.ToList();

		return filteredRows
			.GroupBy(BuildGroupKey)
			.SelectMany(group =>
			{
				var rawGroupRows = group.ToList();

				var distinctOutputRows = rawGroupRows
					.GroupBy(BuildDistinctRowKey)
					.Select(g => g.First())
					.OrderBy(x => x.AllowedAmount ?? decimal.MinValue)
					.ThenBy(x => x.InsurancePaymentAmount ?? decimal.MinValue)
					.ToList();

				// exact count for each AllowedAmount + InsurancePaymentAmount combination
				var exactCombinationCountMap = rawGroupRows
					.GroupBy(BuildDistinctRowKey)
					.ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);

				var allowedValues = rawGroupRows
					.Where(x => x.AllowedAmount.HasValue)
					.Select(x => x.AllowedAmount!.Value)
					.ToList();

				var paymentValues = rawGroupRows
					.Where(x => x.InsurancePaymentAmount.HasValue)
					.Select(x => x.InsurancePaymentAmount!.Value)
					.ToList();

				var allowedPerUnitValues = rawGroupRows
					.Where(x => x.AllowedAmountPerUnit.HasValue)
					.Select(x => x.AllowedAmountPerUnit!.Value)
					.ToList();

				var paymentPerUnitValues = rawGroupRows
					.Where(x => x.InsurancePaymentPerUnit.HasValue)
					.Select(x => x.InsurancePaymentPerUnit!.Value)
					.ToList();

				// Median stays exactly the same
				var medianAllowedAmount = CalculateMedian(allowedValues);
				var medianInsurancePaymentAmount = CalculateMedian(paymentValues);
				var medianAllowedAmountPerUnit = CalculateMedian(allowedPerUnitValues);
				var medianInsurancePaymentPerUnit = CalculateMedian(paymentPerUnitValues);

				// NEW MODE RULE:
				// 1) take the combination with the highest count
				// 2) if counts tie, take the higher AllowedAmount
				// 3) if still tie, take the higher InsurancePaymentAmount
				var amountMode = SelectWinningAmountPaymentMode(rawGroupRows);

				// Same rule for per-unit columns
				var perUnitMode = SelectWinningPerUnitMode(rawGroupRows);

				// Group-level date range from the line-level DateofService values
				var serviceDates = rawGroupRows
					.Where(x => x.DateOfService.HasValue)
					.Select(x => x.DateOfService!.Value)
					.ToList();

				var minDateOfService = serviceDates.Count > 0 ? serviceDates.Min() : (DateTime?)null;
				var maxDateOfService = serviceDates.Count > 0 ? serviceDates.Max() : (DateTime?)null;
				var rollingDays = rawGroupRows[0].RollingDays;

				return distinctOutputRows.Select(r =>
				{
					var rowKey = BuildDistinctRowKey(r);
					var exactCombinationCount = exactCombinationCountMap.TryGetValue(rowKey, out var count)
						? count
						: 0;

					return new PaymentReportRow(
						PayerName: r.PayerName,
						Panel: r.Panel,
						CPTCode: r.CPTCode,
						AllowedAmount: r.AllowedAmount,
						InsurancePaymentAmount: r.InsurancePaymentAmount,
						DistinctAllowedPaymentCount: exactCombinationCount,
						MedianAllowedAmount: medianAllowedAmount,
						MedianInsurancePaymentAmount: medianInsurancePaymentAmount,
						ModeAllowedAmount: amountMode.AllowedAmount,
						ModeInsurancePaymentAmount: amountMode.InsurancePaymentAmount,
						MedianAllowedAmountPerUnit: medianAllowedAmountPerUnit,
						MedianInsurancePaymentPerUnit: medianInsurancePaymentPerUnit,
						ModeAllowedAmountPerUnit: perUnitMode.AllowedAmountPerUnit,
						ModeInsurancePaymentPerUnit: perUnitMode.InsurancePaymentPerUnit,
						RollingDays: rollingDays,
						MinDateOfService: minDateOfService,
						MaxDateOfService: maxDateOfService);
				});
			});
	}

	private static (decimal? AllowedAmount, decimal? InsurancePaymentAmount) SelectWinningAmountPaymentMode(
	IReadOnlyList<PaymentRow> rows)
	{
		var winner = rows
			.Where(x => x.InsurancePaymentAmount.HasValue)
			.GroupBy(x => string.Join("|",
				NormalizeKey(x.PayerName),
				NormalizeKey(x.Panel),
				NormalizeKey(x.CPTCode),
				x.AllowedAmount?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty,
				x.InsurancePaymentAmount?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty))
			.Select(g =>
			{
				var first = g.First();
				return new
				{
					AllowedAmount = first.AllowedAmount,
					InsurancePaymentAmount = first.InsurancePaymentAmount,
					Count = g.Count()
				};
			})
			.OrderByDescending(x => x.Count)
			.ThenByDescending(x => x.AllowedAmount ?? decimal.MinValue)
			.ThenByDescending(x => x.InsurancePaymentAmount ?? decimal.MinValue)
			.FirstOrDefault();

		return winner == null
			? (null, null)
			: (winner.AllowedAmount, winner.InsurancePaymentAmount);
	}

	private static (decimal? AllowedAmountPerUnit, decimal? InsurancePaymentPerUnit) SelectWinningPerUnitMode(
	IReadOnlyList<PaymentRow> rows)
	{
		var winner = rows
			.Where(x => x.InsurancePaymentPerUnit.HasValue)
			.GroupBy(x => string.Join("|",
				NormalizeKey(x.PayerName),
				NormalizeKey(x.Panel),
				NormalizeKey(x.CPTCode),
				x.AllowedAmountPerUnit?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty,
				x.InsurancePaymentPerUnit?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty))
			.Select(g =>
			{
				var first = g.First();
				return new
				{
					AllowedAmountPerUnit = first.AllowedAmountPerUnit,
					InsurancePaymentPerUnit = first.InsurancePaymentPerUnit,
					Count = g.Count()
				};
			})
			.OrderByDescending(x => x.Count)
			.ThenByDescending(x => x.AllowedAmountPerUnit ?? decimal.MinValue)
			.ThenByDescending(x => x.InsurancePaymentPerUnit ?? decimal.MinValue)
			.FirstOrDefault();

		return winner == null
			? (null, null)
			: (winner.AllowedAmountPerUnit, winner.InsurancePaymentPerUnit);
	}

	private static string BuildPerUnitDistinctRowKey(PaymentRow row)
		=> string.Join("|",
			NormalizeKey(row.PayerName),
			NormalizeKey(row.Panel),
			NormalizeKey(row.CPTCode),
			row.AllowedAmountPerUnit?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty,
			row.InsurancePaymentPerUnit?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty);

	private static void WriteMedianSheet(XLWorkbook workbook, IReadOnlyList<PaymentReportRow> rows)
	{
		var ws = workbook.Worksheets.Add("Median Payment");
		WriteHeaderRow(
			ws,
			"MedianAllowedAmount",
			"MedianInsurancePaymentAmount",
			"AllowedAmountPerUnit Median",
			"InsurancePaymentPerUnit Median");

		var asOfDate = DateTime.Today;
		var rowNo = 2;
		foreach (var row in rows)
		{
			WriteCommonRow(ws, rowNo, row);

			WriteDecimal(ws, rowNo, 7, row.MedianAllowedAmount);
			WriteDecimal(ws, rowNo, 8, row.MedianInsurancePaymentAmount);
			WriteDecimal(ws, rowNo, 9, row.MedianAllowedAmountPerUnit);
			WriteDecimal(ws, rowNo, 10, row.MedianInsurancePaymentPerUnit);

			WriteGroupDateColumns(ws, rowNo, row, asOfDate);

			rowNo++;
		}

		FormatWorksheet(ws, rowNo - 1);
	}

	private static void WriteModeSheet(XLWorkbook workbook, IReadOnlyList<PaymentReportRow> rows)
	{
		var ws = workbook.Worksheets.Add("Mode Payment");
		WriteHeaderRow(
			ws,
			"ModeAllowedAmount",
			"ModeInsurancePaymentAmount",
			"AllowedAmountPerUnit Mode",
			"InsurancePaymentPerUnit Mode");

		var asOfDate = DateTime.Today;
		var rowNo = 2;
		foreach (var row in rows)
		{
			WriteCommonRow(ws, rowNo, row);

			WriteDecimal(ws, rowNo, 7, row.ModeAllowedAmount);
			WriteDecimal(ws, rowNo, 8, row.ModeInsurancePaymentAmount);
			WriteDecimal(ws, rowNo, 9, row.ModeAllowedAmountPerUnit);
			WriteDecimal(ws, rowNo, 10, row.ModeInsurancePaymentPerUnit);

			WriteGroupDateColumns(ws, rowNo, row, asOfDate);

			rowNo++;
		}

		FormatWorksheet(ws, rowNo - 1);
	}

	private static void WriteGroupDateColumns(IXLWorksheet ws, int rowNo, PaymentReportRow row, DateTime asOfDate)
	{
		ws.Cell(rowNo, 11).Value = row.RollingDays ?? string.Empty;
		WriteDate(ws, rowNo, 12, row.MinDateOfService);
		WriteDate(ws, rowNo, 13, row.MaxDateOfService);
		WriteDate(ws, rowNo, 14, asOfDate);
	}

	private static void WriteDate(IXLWorksheet ws, int rowNo, int colNo, DateTime? value)
	{
		if (!value.HasValue)
			return;

		ws.Cell(rowNo, colNo).Value = value.Value;
		ws.Cell(rowNo, colNo).Style.NumberFormat.Format = "MM/dd/yyyy";
	}

	private static void WriteDecimal(IXLWorksheet ws, int rowNo, int colNo, decimal? value)
	{
		if (!value.HasValue)
			return;

		ws.Cell(rowNo, colNo).Value = value.Value;
		ws.Cell(rowNo, colNo).Style.NumberFormat.Format = "0.00";
	}
	private static void WriteCommonRow(IXLWorksheet ws, int rowNo, PaymentReportRow row)
	{
		ws.Cell(rowNo, 1).Value = row.PayerName ?? string.Empty;
		ws.Cell(rowNo, 2).Value = row.Panel ?? string.Empty;
		ws.Cell(rowNo, 3).Value = NormalizeCptCode(row.CPTCode);

		if (row.AllowedAmount.HasValue)
		{
			ws.Cell(rowNo, 4).Value = row.AllowedAmount.Value;
			ws.Cell(rowNo, 4).Style.NumberFormat.Format = "0.00";
		}

		if (row.InsurancePaymentAmount.HasValue)
		{
			ws.Cell(rowNo, 5).Value = row.InsurancePaymentAmount.Value;
			ws.Cell(rowNo, 5).Style.NumberFormat.Format = "0.00";
		}

		ws.Cell(rowNo, 6).Value = row.DistinctAllowedPaymentCount;
	}

	private static string NormalizeCptCode(string? cptCode)
	{
		if (string.IsNullOrWhiteSpace(cptCode))
			return string.Empty;

		var value = cptCode.Trim();

		if (decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
		{
			if (d == decimal.Truncate(d))
				return d.ToString("0", CultureInfo.InvariantCulture);
		}

		return value;
	}

	private static void WriteHeaderRow(
		IXLWorksheet ws,
		string metricHeader1,
		string metricHeader2,
		string metricHeader3,
		string metricHeader4)
	{
		ws.Cell(1, 1).Value = "PayerName";
		ws.Cell(1, 2).Value = "Panel";
		ws.Cell(1, 3).Value = "CPTCode";
		ws.Cell(1, 4).Value = "AllowedAmount";
		ws.Cell(1, 5).Value = "InsurancePaymentAmount";
		ws.Cell(1, 6).Value = "DistinctAllowedPaymentCount";
		ws.Cell(1, 7).Value = metricHeader1;
		ws.Cell(1, 8).Value = metricHeader2;
		ws.Cell(1, 9).Value = metricHeader3;
		ws.Cell(1, 10).Value = metricHeader4;
		ws.Cell(1, 11).Value = "RollingDays";
		ws.Cell(1, 12).Value = "MinDateofService";
		ws.Cell(1, 13).Value = "MaxDateofService";
		ws.Cell(1, 14).Value = "AsOfDate";
		ws.Row(1).Style.Font.Bold = true;
	}

	private static void FormatWorksheet(IXLWorksheet ws, int lastRow)
	{
		if (lastRow >= 1)
		{
			var range = ws.Range(1, 1, Math.Max(lastRow, 1), 14);
			range.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
			range.Style.Alignment.WrapText = false;
			range.SetAutoFilter();
		}

		ws.Column(3).Style.NumberFormat.Format = "@";
		ws.Columns().AdjustToContents();
	}

	private static string BuildGroupKey(PaymentRow row)
		=> string.Join("|",
			NormalizeKey(row.PayerName),
			NormalizeKey(row.Panel),
			NormalizeKey(row.CPTCode),
			NormalizeKey(row.RollingDays));

	private static string BuildDistinctRowKey(PaymentRow row)
		=> string.Join("|",
			NormalizeKey(row.PayerName),
			NormalizeKey(row.Panel),
			NormalizeKey(row.CPTCode),
			row.AllowedAmount?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty,
			row.InsurancePaymentAmount?.ToString("0.##############", CultureInfo.InvariantCulture) ?? string.Empty);

	private static string NormalizeKey(string? value)
		=> (value ?? string.Empty).Trim().ToUpperInvariant();

	private static int FindHeaderIndex(string[] header, params string[] aliases)
	{
		for (int i = 0; i < header.Length; i++)
		{
			var current = NormalizeHeader(header[i]);
			foreach (var alias in aliases)
			{
				if (current == NormalizeHeader(alias))
					return i;
			}
		}

		return -1;
	}

	private static string NormalizeHeader(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return string.Empty;

		return new string(value.Where(c => !char.IsWhiteSpace(c) && c != '_' && c != '-').ToArray())
			.Trim()
			.ToUpperInvariant();
	}

	private static string ReadField(string[] fields, int index)
		=> index >= 0 && index < fields.Length ? fields[index] ?? string.Empty : string.Empty;

	private static decimal? ParseNullableDecimal(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return null;

		var cleaned = value.Trim()
			.Replace("$", string.Empty)
			.Replace(",", string.Empty)
			.Replace("(", "-")
			.Replace(")", string.Empty);

		if (decimal.TryParse(cleaned, NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
			return parsed;

		if (decimal.TryParse(cleaned, NumberStyles.Any, CultureInfo.CurrentCulture, out parsed))
			return parsed;

		return null;
	}

	private static DateTime? ParseNullableDate(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return null;

		var cleaned = value.Trim();

		// Standard CSV dates are normalized to MM/dd/yyyy, but accept common variants.
		string[] formats =
		{
			"MM/dd/yyyy", "M/d/yyyy",
			"yyyy-MM-dd", "yyyy/MM/dd",
			"MM/dd/yyyy HH:mm:ss", "M/d/yyyy H:mm:ss"
		};

		if (DateTime.TryParseExact(cleaned, formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var exact))
			return exact.Date;

		if (DateTime.TryParse(cleaned, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
			return parsed.Date;

		return null;
	}

	private static decimal? CalculateMedian(IReadOnlyList<decimal> values)
	{
		if (values.Count == 0)
			return null;

		var ordered = values.OrderBy(x => x).ToList();
		var mid = ordered.Count / 2;

		if (ordered.Count % 2 == 1)
			return ordered[mid];

		return (ordered[mid - 1] + ordered[mid]) / 2m;
	}

	private static decimal? CalculateMode(IReadOnlyList<decimal> values)
	{
		if (values.Count == 0)
			return null;

		return values
			.GroupBy(x => x)
			.Select(g => new { Value = g.Key, Count = g.Count() })
			.OrderByDescending(x => x.Count)
			.ThenByDescending(x => x.Value)
			.Select(x => (decimal?)x.Value)
			.FirstOrDefault();
	}

	private sealed record PaymentRow(
	string PayerName,
	string Panel,
	string CPTCode,
	decimal? AllowedAmount,
	decimal? InsurancePaymentAmount,
	decimal? AllowedAmountPerUnit,
	decimal? InsurancePaymentPerUnit,
	string RollingDays,
	DateTime? DateOfService);

	public sealed record PaymentReportRow(
		string PayerName,
		string Panel,
		string CPTCode,
		decimal? AllowedAmount,
		decimal? InsurancePaymentAmount,
		int DistinctAllowedPaymentCount,
		decimal? MedianAllowedAmount,
		decimal? MedianInsurancePaymentAmount,
		decimal? ModeAllowedAmount,
		decimal? ModeInsurancePaymentAmount,
		decimal? MedianAllowedAmountPerUnit,
		decimal? MedianInsurancePaymentPerUnit,
		decimal? ModeAllowedAmountPerUnit,
		decimal? ModeInsurancePaymentPerUnit,
		string RollingDays,
		DateTime? MinDateOfService,
		DateTime? MaxDateOfService);
}