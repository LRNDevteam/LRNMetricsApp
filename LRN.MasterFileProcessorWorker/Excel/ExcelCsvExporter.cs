using ExcelDataReader;
using System.Globalization;
using System.Text;

public static class ExcelCsvExporter
{
    static ExcelCsvExporter()
    {
        // Required for some Excel encodings.
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public static async Task<string> ExportSingleSheetToCsvAsync(
        string xlsxPath,
        string sheetNameCandidatesCsv,
        string outputCsvPath,
        CancellationToken ct)
    {
        var availableSheets = ListSheetNames(xlsxPath);
        var sheet = PickFirstAvailable(availableSheets, sheetNameCandidatesCsv);

        if (sheet == null)
            throw new InvalidOperationException($"None of the candidate sheets were found. Candidates='{sheetNameCandidatesCsv}'. Available='{string.Join(", ", availableSheets)}'.");

        Directory.CreateDirectory(Path.GetDirectoryName(outputCsvPath)!);
        await ExportSheetToCsvAsync(xlsxPath, sheet, outputCsvPath, ct);
        return sheet;
    }

    /// <summary>
    /// Exports multiple named sheets from a single workbook into one combined CSV file.
    /// A "Source" column (named by <paramref name="sourceColumnName"/>) is appended to every row,
    /// filled with the <c>SourceValue</c> paired with each sheet name.
    /// <para>
    /// The sheets may have DIFFERENT column layouts (e.g. NorthWest "Webpm LineLevel" vs
    /// "Daq Line Level" come from different billing systems). Columns are therefore aligned by
    /// HEADER NAME, not by position: the output header is the union of every sheet's headers
    /// (in order of first appearance), and each row's cells are placed under their own sheet's
    /// header names. A column that exists in only one sheet is left blank for rows from the
    /// other sheet, rather than shifting/misaligning the data.
    /// </para>
    /// Returns the sheet names that were actually found and exported.
    /// </summary>
    public static async Task<IReadOnlyList<string>> ExportMultiSheetCombinedToCsvAsync(
        string xlsxPath,
        IReadOnlyList<(string SheetName, string SourceValue)> sheets,
        string sourceColumnName,
        string outputCsvPath,
        CancellationToken ct)
    {
        var availableSheets = ListSheetNames(xlsxPath);
        var matched = sheets.Where(s => availableSheets.Contains(s.SheetName)).ToList();

        if (matched.Count == 0)
            throw new InvalidOperationException(
                $"None of the configured sheets were found. Configured=[{string.Join(", ", sheets.Select(s => s.SheetName))}]. Available=[{string.Join(", ", availableSheets)}].");

        // Pass 1: build the union of header names across all matched sheets (first-appearance order).
        var unionHeaders = new List<string>();
        var unionIndexByName = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        foreach (var (sheetName, _) in matched)
        {
            var headers = ReadSheetHeaderRow(xlsxPath, sheetName);
            foreach (var h in headers)
            {
                var name = (h ?? string.Empty).Trim();
                if (string.IsNullOrWhiteSpace(name)) continue;
                if (!unionIndexByName.ContainsKey(name))
                {
                    unionIndexByName[name] = unionHeaders.Count;
                    unionHeaders.Add(name);
                }
            }
        }

        Directory.CreateDirectory(Path.GetDirectoryName(outputCsvPath)!);

        await using var fs = new FileStream(outputCsvPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        await using var sw = new StreamWriter(fs, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

        // Write the unified header row + Source column once.
        await sw.WriteAsync(string.Join(",", unionHeaders.Select(CsvEscape)));
        if (unionHeaders.Count > 0) await sw.WriteAsync(",");
        await sw.WriteAsync(CsvEscape(sourceColumnName));
        await sw.WriteLineAsync();

        // Pass 2: stream each sheet's data rows, aligning cells by their own header names.
        foreach (var (sheetName, sourceValue) in matched)
        {
            using var stream = File.Open(xlsxPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = ExcelReaderFactory.CreateReader(stream);

            bool found = false;
            do
            {
                if (string.Equals(reader.Name, sheetName, StringComparison.OrdinalIgnoreCase))
                {
                    found = true;
                    break;
                }
            }
            while (reader.NextResult());

            if (!found) continue;

            string[]? sheetHeaders = null;
            bool isHeaderRow = true;

            while (reader.Read())
            {
                ct.ThrowIfCancellationRequested();

                int cols = reader.FieldCount;

                if (isHeaderRow)
                {
                    sheetHeaders = new string[cols];
                    for (int i = 0; i < cols; i++)
                        sheetHeaders[i] = ConvertCellToString(reader.GetValue(i), null, isHeaderRow: true);
                    isHeaderRow = false;
                    continue; // header row consumed; do not emit as data
                }

                // Map this sheet's cells into the union column positions by header name.
                var outFields = new string[unionHeaders.Count];
                for (int u = 0; u < outFields.Length; u++)
                    outFields[u] = string.Empty;

                for (int i = 0; i < cols; i++)
                {
                    var headerName = sheetHeaders != null && i < sheetHeaders.Length ? (sheetHeaders[i] ?? string.Empty).Trim() : string.Empty;
                    if (string.IsNullOrWhiteSpace(headerName)) continue;
                    if (!unionIndexByName.TryGetValue(headerName, out var target)) continue;

                    // First non-empty wins if a sheet repeats a header name.
                    if (!string.IsNullOrEmpty(outFields[target])) continue;

                    outFields[target] = ConvertCellToString(reader.GetValue(i), headerName, isHeaderRow: false);
                }

                // Trailing/blank rows in the sheet carry no data. The Source stamp below would
                // otherwise make them look populated, and they would load as all-NULL rows.
                if (outFields.All(string.IsNullOrWhiteSpace))
                    continue;

                for (int u = 0; u < outFields.Length; u++)
                {
                    if (u > 0) await sw.WriteAsync(",");
                    await sw.WriteAsync(CsvEscape(outFields[u]));
                }
                if (outFields.Length > 0) await sw.WriteAsync(",");
                await sw.WriteAsync(CsvEscape(sourceValue));
                await sw.WriteLineAsync();
            }
        }

        await sw.FlushAsync();
        return matched.Select(s => s.SheetName).ToList();
    }

    private static string[] ReadSheetHeaderRow(string xlsxPath, string sheetName)
    {
        using var stream = File.Open(xlsxPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = ExcelReaderFactory.CreateReader(stream);

        bool found = false;
        do
        {
            if (string.Equals(reader.Name, sheetName, StringComparison.OrdinalIgnoreCase))
            {
                found = true;
                break;
            }
        }
        while (reader.NextResult());

        if (!found || !reader.Read())
            return Array.Empty<string>();

        var headers = new string[reader.FieldCount];
        for (int i = 0; i < reader.FieldCount; i++)
            headers[i] = ConvertCellToString(reader.GetValue(i), null, isHeaderRow: true);

        return headers;
    }

    public static async Task<(string? claimSheetUsed, string? lineSheetUsed)> ExportClaimAndLineCsvAsync(
        string xlsxPath,
        string claimCsvPath,
        string lineCsvPath,
        string? claimSheetCandidatesCsv,
        string? lineSheetCandidatesCsv,
        CancellationToken ct)
    {
        var availableSheets = ListSheetNames(xlsxPath);

        string? claimSheet = PickFirstAvailable(availableSheets, claimSheetCandidatesCsv);
        string? lineSheet = PickFirstAvailable(availableSheets, lineSheetCandidatesCsv);

        if (claimSheet != null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(claimCsvPath)!);
            await ExportSheetToCsvAsync(xlsxPath, claimSheet, claimCsvPath, ct);
        }

        if (lineSheet != null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(lineCsvPath)!);
            await ExportSheetToCsvAsync(xlsxPath, lineSheet, lineCsvPath, ct);
        }

        return (claimSheet, lineSheet);
    }

    /// <summary>
    /// Sheet names in workbook order. Use when the caller needs to decide which sheets to read
    /// based on what the file actually contains (e.g. labs whose sheet naming varies per delivery).
    /// </summary>
    public static List<string> ListSheetNamesInOrder(string xlsxPath)
    {
        using var stream = File.Open(xlsxPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = ExcelReaderFactory.CreateReader(stream);

        var names = new List<string>();

        do
        {
            if (!string.IsNullOrWhiteSpace(reader.Name))
                names.Add(reader.Name);
        }
        while (reader.NextResult());

        return names;
    }

    private static HashSet<string> ListSheetNames(string xlsxPath)
    {
        using var stream = File.Open(xlsxPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = ExcelReaderFactory.CreateReader(stream);

        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        do
        {
            if (!string.IsNullOrWhiteSpace(reader.Name))
                set.Add(reader.Name);
        }
        while (reader.NextResult());

        return set;
    }

    private static string? PickFirstAvailable(HashSet<string> availableSheets, string? candidatesCsv)
    {
        var candidates = SplitCandidates(candidatesCsv);
        foreach (var c in candidates)
        {
            if (availableSheets.Contains(c))
                return c;
        }
        return null;
    }

    private static string[] SplitCandidates(string? csv)
    {
        if (string.IsNullOrWhiteSpace(csv)) return Array.Empty<string>();
        return csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }

    private static async Task ExportSheetToCsvAsync(string xlsxPath, string sheetName, string csvPath, CancellationToken ct)
    {
        using var stream = File.Open(xlsxPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = ExcelReaderFactory.CreateReader(stream);

        // Move to the requested sheet
        bool found = false;
        do
        {
            if (string.Equals(reader.Name, sheetName, StringComparison.OrdinalIgnoreCase))
            {
                found = true;
                break;
            }
        }
        while (reader.NextResult());

        if (!found)
            throw new InvalidOperationException($"Sheet '{sheetName}' not found in '{xlsxPath}'.");

        await using var fs = new FileStream(csvPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        await using var sw = new StreamWriter(fs, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
		string[]? headers = null;
		var isHeaderRow = true;

		while (reader.Read())
		{
			ct.ThrowIfCancellationRequested();

			int cols = reader.FieldCount;
			var rowValues = new string[cols];

			for (int i = 0; i < cols; i++)
			{
				var val = reader.GetValue(i);
				var headerName = headers != null && i < headers.Length ? headers[i] : null;
				rowValues[i] = ConvertCellToString(val, headerName, isHeaderRow);
			}

			if (isHeaderRow)
			{
				headers = rowValues;
				isHeaderRow = false;
			}
			else if (rowValues.All(string.IsNullOrWhiteSpace))
			{
				// Trailing/blank sheet row: nothing to export.
				continue;
			}

			for (int i = 0; i < cols; i++)
			{
				if (i > 0) await sw.WriteAsync(",");
				await sw.WriteAsync(CsvEscape(rowValues[i]));
			}

			await sw.WriteLineAsync();
		}

		await sw.FlushAsync();
    }

	private static string ConvertCellToString(object? val, string? headerName = null, bool isHeaderRow = false)
	{
		if (val == null || val == DBNull.Value)
			return "";

		if (isHeaderRow)
			return Convert.ToString(val, CultureInfo.InvariantCulture) ?? "";

		return val switch
		{
			DateTime dt => dt.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),

			double d => FormatNumericCell(d, headerName),
			float f => FormatNumericCell((double)f, headerName),
			decimal m => FormatNumericCell((double)m, headerName),

			bool b => b ? "true" : "false",
			_ => Convert.ToString(val, CultureInfo.InvariantCulture) ?? ""
		};
	}

	private static string FormatNumericCell(double value, string? headerName)
	{
		// Keep amount / payment / balance / charge style columns as decimal
		if (IsDecimalAmountColumn(headerName))
			return value.ToString("0.00", CultureInfo.InvariantCulture);

		// For identifier-like integer values, do not append .00
		if (Math.Abs(value % 1) < 0.0000001)
			return value.ToString("0", CultureInfo.InvariantCulture);

		// For genuine non-integer numeric values, preserve actual value without forcing 2 decimals
		return value.ToString("0.###############", CultureInfo.InvariantCulture);
	}

	private static bool IsDecimalAmountColumn(string? headerName)
	{
		if (string.IsNullOrWhiteSpace(headerName))
			return false;

		var h = headerName.Trim().ToLowerInvariant();

		return h.Contains("amount")
			|| h.Contains("payment")
			|| h.Contains("balance")
			|| h.Contains("charge")
			|| h.Contains("allowed")
			|| h.Contains("paid")
			|| h.Contains("coinsurance")
			|| h.Contains("copay")
			|| h.Contains("deductible")
			|| h.Contains("adjustment")
			|| h.Contains("reimbursement")
			|| h.Contains("rate")
			|| h.Contains("fee")
			|| h.Contains("billed");
	}
	private static string CsvEscape(string value)
    {
		if (string.IsNullOrEmpty(value))
			return "";

		bool mustQuote =
			value.Contains(',')
			|| value.Contains('"')
			|| value.Contains('\n')
			|| value.Contains('\r');

		if (value.Contains('"'))
			value = value.Replace("\"", "\"\"");

		return mustQuote ? $"\"{value}\"" : value;
	}
}
