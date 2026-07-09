using ClosedXML.Excel;
using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

/// <summary>
/// Thrown when the resolved source file has already been processed
/// (its path matches LabConfig.LastProcessedFile).
/// </summary>
public sealed class AlreadyProcessedException : Exception
{
    public string FilePath { get; }
    public AlreadyProcessedException(string filePath)
        : base($"Source file already processed — skipping: {filePath}")
        => FilePath = filePath;
}

public class ExcelReaderService
{
    /// <summary>
    /// Resolves the latest source file, checks against LastProcessedFile in the
    /// lab config, and loads records. Throws AlreadyProcessedException when the
    /// file was already processed. Throws FileNotFoundException when no source
    /// files exist.
    /// </summary>
    public (List<ClaimRecord> records, string filePath, string runId, string weekFolderName)
        LoadLatestReport(AnalysisSettings settings, LabConfig labConfig)
    {
        var rootFolder = settings.InputFolderPath;
        if (!Directory.Exists(rootFolder))
            throw new DirectoryNotFoundException($"Input folder not found: {rootFolder}");

        // ── Resolve the target folder (Year / Month / WeekFolder structure) ────
        var (targetFolder, weekFolderName, resolutionNote) = ResolveLatestFolder(rootFolder);
        Console.WriteLine($"[Step 1] Folder resolution : {resolutionNote}");
        Console.WriteLine($"[Step 1] Target folder     : {targetFolder}");
        Console.WriteLine($"[Step 1] Week folder name  : {weekFolderName}");

        // ── Build candidate file list (.xlsx and .csv) ────────────────────────
        // Exclusions:
        //   1. Previously generated output files  → contain "_Prediction_vs_NonPayment_Analysis_"
        //   2. Temporary files                    → name ends with "_temp" (before extension)
        const string outputMarker = "_Prediction_vs_NonPayment_Analysis_";
        const string tempSuffix   = "_temp";

        var files = Directory.GetFiles(targetFolder)
            .Where(IsSourceExtension)
            .Select(f => new FileInfo(f))
            .Where(f => !f.Name.Contains(outputMarker, StringComparison.OrdinalIgnoreCase)
                     && !Path.GetFileNameWithoutExtension(f.Name)
                             .EndsWith(tempSuffix, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(f => f.CreationTime)
            .ToList();

        if (files.Count == 0)
            throw new FileNotFoundException(
                $"No source .xlsx/.csv files found in: {targetFolder}  " +
                $"(temp and generated output files are excluded)");

        // ── Try each candidate in order until one opens successfully ─────────
        // If a file is locked, corrupt, or unreadable → log and try the next one.
        FileInfo?      latestFile = null;
        XLWorkbook?    workbook   = null;
        IXLWorksheet?  sheet      = null;
        CsvTable?      csvTable   = null;

        foreach (var candidate in files)
        {
            // Skip if already processed
            if (!string.IsNullOrWhiteSpace(labConfig.LastProcessedFile) &&
                string.Equals(labConfig.LastProcessedFile, candidate.FullName,
                              StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine($"[Step 1] SKIP — already processed: {candidate.FullName}");
                throw new AlreadyProcessedException(candidate.FullName);
            }

            try
            {
                Console.WriteLine($"[Step 1] Trying file       : {candidate.FullName}");
                Console.WriteLine($"[Step 1] File created      : {candidate.CreationTime:yyyy-MM-dd HH:mm:ss}");

                if (candidate.Extension.Equals(".csv", StringComparison.OrdinalIgnoreCase))
                {
                    var table = CsvTable.Load(candidate.FullName);
                    Console.WriteLine($"[Step 1] CSV parsed        : {table.Rows.Count} data rows | {table.Headers.Count} columns.");

                    latestFile = candidate;
                    csvTable   = table;
                    break; // successfully parsed — stop trying
                }

                var wb = new XLWorkbook(candidate.FullName);

                // Use configured SheetName; fall back to first sheet if not found
                IXLWorksheet ws;
                if (wb.Worksheets.TryGetWorksheet(settings.SheetName, out var namedSheet))
                {
                    ws = namedSheet;
                    Console.WriteLine($"[Step 1] Sheet resolved    : '{ws.Name}' (matched configured name)");
                }
                else
                {
                    ws = wb.Worksheets.First();
                    Console.WriteLine($"[Step 1] Sheet resolved    : '{ws.Name}' ('{settings.SheetName}' not found — using first sheet)");
                }

                latestFile = candidate;
                workbook   = wb;
                sheet      = ws;
                break; // successfully opened — stop trying
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Step 1] [ERROR] Cannot open '{candidate.Name}': {ex.Message} — trying next file.");
            }
        }

        if (latestFile is null || (csvTable is null && (workbook is null || sheet is null)))
            throw new FileNotFoundException(
                $"All candidate .xlsx/.csv files in '{targetFolder}' failed to open. Check logs above.");

        Console.WriteLine($"[Step 1] Using report      : {latestFile.FullName}");

        // ── Extract RunId: text before first '_' in the file name ─────────────
        var fileNameOnly  = Path.GetFileNameWithoutExtension(latestFile.Name);
        var underscoreIdx = fileNameOnly.IndexOf('_');
        var runId         = underscoreIdx > 0 ? fileNameOnly[..underscoreIdx] : fileNameOnly;
        Console.WriteLine($"[Step 1] RunId extracted   : {runId}  (source: '{latestFile.Name}')");

        // ── CSV path ──────────────────────────────────────────────────────────
        if (csvTable is not null)
        {
            var csvRecords = BuildRecordsFromCsv(csvTable, settings);
            return (csvRecords, latestFile.FullName, runId, weekFolderName);
        }

        // ── XLSX path (unchanged) ─────────────────────────────────────────────
        if (workbook is null || sheet is null)
            throw new InvalidOperationException(
                "Internal error: workbook/sheet not initialised for xlsx source.");

        using (workbook)
        {
            var colMap = BuildColumnMap(sheet);

            // ── Ordered header list (preserves source column order) ───────────
            var orderedHeaders = colMap
                .OrderBy(kv => kv.Value)
                .Select(kv => kv.Key)
                .ToList();

            Console.WriteLine($"\n[Diag] Columns found in sheet '{sheet.Name}' ({orderedHeaders.Count} total):");
            foreach (var kv in colMap.OrderBy(k => k.Value))
                Console.WriteLine($"         Col {kv.Value,3}: {kv.Key}");

            Console.WriteLine("\n[Diag] Analysis column mapping check:");
            CheckColumn(colMap, settings.Columns.AccessionNumber,     nameof(settings.Columns.AccessionNumber));
            CheckColumn(colMap, settings.Columns.VisitNumber,         nameof(settings.Columns.VisitNumber));
            CheckColumn(colMap, settings.Columns.PayerName,           nameof(settings.Columns.PayerName));
            CheckColumn(colMap, settings.Columns.PanelName,           nameof(settings.Columns.PanelName));
            CheckColumn(colMap, settings.Columns.ForecastingP,        nameof(settings.Columns.ForecastingP));
            CheckColumn(colMap, settings.Columns.PayStatus,           nameof(settings.Columns.PayStatus));
            CheckColumn(colMap, settings.Columns.DenialCode,          nameof(settings.Columns.DenialCode));
            CheckColumn(colMap, settings.Columns.DenialDescription,   nameof(settings.Columns.DenialDescription));
            CheckColumn(colMap, settings.Columns.ExpectedPaymentDate, nameof(settings.Columns.ExpectedPaymentDate));
            CheckColumn(colMap, settings.Columns.FirstBilledDate,     nameof(settings.Columns.FirstBilledDate));
            CheckColumn(colMap, settings.Columns.ModeAllowedAmount,   nameof(settings.Columns.ModeAllowedAmount));
            CheckColumn(colMap, settings.Columns.ModeInsurancePaid,   nameof(settings.Columns.ModeInsurancePaid));
            CheckColumn(colMap, settings.Columns.AllowedAmount,       nameof(settings.Columns.AllowedAmount));
            CheckColumn(colMap, settings.Columns.InsurancePayment,    nameof(settings.Columns.InsurancePayment));
            Console.WriteLine();

            var records = new List<ClaimRecord>();
            var lastRow = sheet.LastRowUsed()?.RowNumber() ?? 1;

            for (int row = 2; row <= lastRow; row++)
            {
                var rawColumns = new Dictionary<string, string>(orderedHeaders.Count,
                    StringComparer.OrdinalIgnoreCase);
                foreach (var header in orderedHeaders)
                    rawColumns[header] = GetCell(sheet, row, colMap, header);

                var record = new ClaimRecord
                {
                    AccessionNumber     = GetCell(sheet, row, colMap, settings.Columns.AccessionNumber),
                    VisitNumber         = GetCell(sheet, row, colMap, settings.Columns.VisitNumber),
                    PayerName           = GetCell(sheet, row, colMap, settings.Columns.PayerName),
                    PanelName           = GetCell(sheet, row, colMap, settings.Columns.PanelName),
                    ForecastingP        = GetCell(sheet, row, colMap, settings.Columns.ForecastingP),
                    PayStatus           = GetCell(sheet, row, colMap, settings.Columns.PayStatus),
                    DenialCode          = GetCell(sheet, row, colMap, settings.Columns.DenialCode),
                    DenialDescription   = GetCell(sheet, row, colMap, settings.Columns.DenialDescription),
                    ExpectedPaymentDate = ParseDate(sheet, row, colMap, settings.Columns.ExpectedPaymentDate),
                    FirstBilledDate     = ParseDate(sheet, row, colMap, settings.Columns.FirstBilledDate),
                    ModeAllowedAmount   = ParseDecimal(sheet, row, colMap, settings.Columns.ModeAllowedAmount),
                    ModeInsurancePaid   = ParseDecimal(sheet, row, colMap, settings.Columns.ModeInsurancePaid),
                    AllowedAmount       = ParseDecimal(sheet, row, colMap, settings.Columns.AllowedAmount),
                    InsurancePayment    = ParseDecimal(sheet, row, colMap, settings.Columns.InsurancePayment),
                    RawColumns          = rawColumns,
                    SourceHeaders       = row == 2 ? orderedHeaders : []
                };

                records.Add(record);
            }

            // Propagate SourceHeaders to all records from the first record
            if (records.Count > 1)
            {
                var headers = records[0].SourceHeaders;
                for (int i = 1; i < records.Count; i++)
                    records[i].SourceHeaders = headers;
            }

            Console.WriteLine($"[Step 1] Loaded {records.Count} rows | {orderedHeaders.Count} columns per row.");
            PrintDistinctSample(records, "ForecastingP", r => r.ForecastingP);
            PrintDistinctSample(records, "PayStatus",    r => r.PayStatus);
            PrintDistinctSample(records, "ExpectedPaymentDate (null?)",
                r => r.ExpectedPaymentDate.HasValue ? "has value" : "NULL");

            return (records, latestFile.FullName, runId, weekFolderName);
        }
    }

    // ── Folder resolution ─────────────────────────────────────────────────────

    internal static (string folder, string weekFolderName, string note) ResolveLatestFolder(string rootFolder)
    {
        var now         = DateTime.Today;
        var yearPrefix  = now.Year.ToString();
        var monthPrefix = now.Month.ToString("D2");

        var yearFolder = Directory
            .GetDirectories(rootFolder)
            .Select(d => new DirectoryInfo(d))
            .Where(d => d.Name.StartsWith(yearPrefix, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(d => FolderSortKey(d.Name))
            .FirstOrDefault();

        if (yearFolder is null)
        {
            Console.WriteLine($"[Step 1] [Fallback] No year folder matching '{yearPrefix}'.");
            return FallbackToLatestFolder(rootFolder);
        }

        var monthFolder = Directory
            .GetDirectories(yearFolder.FullName)
            .Select(d => new DirectoryInfo(d))
            .Where(d => d.Name.StartsWith(monthPrefix, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(d => FolderSortKey(d.Name))
            .FirstOrDefault();

        if (monthFolder is null)
        {
            Console.WriteLine($"[Step 1] [Fallback] No month folder matching '{monthPrefix}.*'.")
;
            return FallbackToLatestFolder(rootFolder);
        }

        var weekFolder = Directory
            .GetDirectories(monthFolder.FullName)
            .Select(d => new DirectoryInfo(d))
            .OrderByDescending(d => WeekFolderSortKey(d.Name))
            .FirstOrDefault();

        if (weekFolder is null)
        {
            Console.WriteLine($"[Step 1] [Fallback] No week folders found under: {monthFolder.FullName}");
            return FallbackToLatestFolder(rootFolder);
        }

        return (weekFolder.FullName, weekFolder.Name,
            $"Year/Month/Week → {yearFolder.Name} / {monthFolder.Name} / {weekFolder.Name}");
    }

    private static (string folder, string weekFolderName, string note) FallbackToLatestFolder(string rootFolder)
    {
        const string outputMarker = "_Prediction_vs_NonPayment_Analysis_";

        // Find the most recently WRITTEN source .xlsx/.csv file anywhere under rootFolder.
        // Using LastWriteTimeUtc is reliable regardless of how/when the folder was created
        // or copied — it always reflects when the file content was last changed.
        var newestFile = Directory
            .EnumerateFiles(rootFolder, "*.*", SearchOption.AllDirectories)
            .Where(IsSourceExtension)
            .Where(f => !Path.GetFileName(f)
                            .Contains(outputMarker, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .OrderByDescending(fi => fi.LastWriteTimeUtc)
            .FirstOrDefault();

        if (newestFile is not null)
        {
            var dir = newestFile.DirectoryName!;
            return (dir, Path.GetFileName(dir),
                $"Fallback: newest source file by LastWriteTime → {newestFile.FullName}");
        }

        throw new FileNotFoundException($"No source .xlsx/.csv files found anywhere under: {rootFolder}");
    }

    // ── Folder sort helpers ───────────────────────────────────────────────────

    /// <summary>
    /// Returns a sort key for year or month folder names.
    /// Folder name examples: "2026", "03.March", "02.February"
    /// Extracts the leading numeric part so folders sort correctly by date.
    /// Falls back to the folder name string if no number is found.
    /// </summary>
    private static string FolderSortKey(string name)
    {
        // Extract leading digits (e.g. "2026" → "2026", "03.March" → "03")
        var digits = new string(name.TakeWhile(char.IsDigit).ToArray());
        return digits.Length > 0 ? digits.PadLeft(6, '0') : name;
    }

    /// <summary>
    /// Returns a sort key for week folder names like "03.19.2026 - 03.25.2026".
    /// Parses the START date from the folder name; falls back to the raw name so
    /// sorting is always deterministic even for unexpected formats.
    /// </summary>
    private static DateTime WeekFolderSortKey(string name)
    {
        // Pattern: MM.dd.yyyy - MM.dd.yyyy  (take the first date)
        var part = name.Split('-')[0].Trim();  // "03.19.2026"
        if (DateTime.TryParseExact(part, "MM.dd.yyyy",
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out var dt))
            return dt;

        // Fallback: try any parseable date in the first segment
        if (DateTime.TryParse(part, out dt))
            return dt;

        return DateTime.MinValue;
    }

    // ── Source file extension helper ──────────────────────────────────────────

    /// <summary>Accepted source file extensions: .xlsx and .csv.</summary>
    private static bool IsSourceExtension(string path)
    {
        var ext = Path.GetExtension(path);
        return ext.Equals(".xlsx", StringComparison.OrdinalIgnoreCase)
            || ext.Equals(".csv",  StringComparison.OrdinalIgnoreCase);
    }

    // ── CSV support ───────────────────────────────────────────────────────────

    /// <summary>
    /// In-memory CSV table: header list, header→index map, and data rows.
    /// Parsed with RFC 4180 rules (quoted fields, embedded commas/quotes/newlines).
    /// </summary>
    private sealed class CsvTable
    {
        public List<string>            Headers { get; }
        public Dictionary<string, int> ColMap  { get; }
        public List<string[]>          Rows    { get; }

        private CsvTable(List<string> headers, Dictionary<string, int> colMap, List<string[]> rows)
        {
            Headers = headers;
            ColMap  = colMap;
            Rows    = rows;
        }

        public static CsvTable Load(string path)
        {
            // FileShare.ReadWrite: tolerate the file being open in Excel.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream, detectEncodingFromByteOrderMarks: true);

            var allRows = ParseCsv(reader);

            if (allRows.Count == 0)
                throw new InvalidDataException($"CSV file is empty: {path}");

            var headers = allRows[0]
                .Select(h => h.Trim())
                .ToList();

            if (headers.All(string.IsNullOrEmpty))
                throw new InvalidDataException($"CSV header row is blank: {path}");

            var colMap = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < headers.Count; i++)
            {
                if (!string.IsNullOrEmpty(headers[i]) && !colMap.ContainsKey(headers[i]))
                    colMap[headers[i]] = i;
            }

            // Data rows: skip completely blank lines.
            var rows = allRows
                .Skip(1)
                .Where(r => r.Any(v => !string.IsNullOrWhiteSpace(v)))
                .ToList();

            return new CsvTable(headers, colMap, rows);
        }

        /// <summary>RFC 4180 character-level parser: handles quoted fields containing commas, quotes ("" escape) and newlines.</summary>
        private static List<string[]> ParseCsv(TextReader reader)
        {
            var rows     = new List<string[]>();
            var fields   = new List<string>();
            var sb       = new System.Text.StringBuilder();
            bool inQuotes = false;
            int ch;

            while ((ch = reader.Read()) != -1)
            {
                char c = (char)ch;

                if (inQuotes)
                {
                    if (c == '"')
                    {
                        if (reader.Peek() == '"') { sb.Append('"'); reader.Read(); }
                        else inQuotes = false;
                    }
                    else sb.Append(c);
                }
                else if (c == '"')
                {
                    inQuotes = true;
                }
                else if (c == ',')
                {
                    fields.Add(sb.ToString()); sb.Clear();
                }
                else if (c == '\r' || c == '\n')
                {
                    if (c == '\r' && reader.Peek() == '\n') reader.Read();
                    fields.Add(sb.ToString()); sb.Clear();
                    rows.Add(fields.ToArray()); fields.Clear();
                }
                else sb.Append(c);
            }

            if (sb.Length > 0 || fields.Count > 0)
            {
                fields.Add(sb.ToString());
                rows.Add(fields.ToArray());
            }

            return rows;
        }
    }

    /// <summary>
    /// Builds ClaimRecords from a parsed CSV table using the same configured
    /// column mapping and diagnostics as the xlsx path.
    /// </summary>
    private static List<ClaimRecord> BuildRecordsFromCsv(CsvTable table, AnalysisSettings settings)
    {
        var colMap = table.ColMap;

        var orderedHeaders = colMap
            .OrderBy(kv => kv.Value)
            .Select(kv => kv.Key)
            .ToList();

        Console.WriteLine($"\n[Diag] Columns found in CSV ({orderedHeaders.Count} total):");
        foreach (var kv in colMap.OrderBy(k => k.Value))
            Console.WriteLine($"         Col {kv.Value + 1,3}: {kv.Key}");

        Console.WriteLine("\n[Diag] Analysis column mapping check:");
        CheckColumn(colMap, settings.Columns.AccessionNumber,     nameof(settings.Columns.AccessionNumber));
        CheckColumn(colMap, settings.Columns.VisitNumber,         nameof(settings.Columns.VisitNumber));
        CheckColumn(colMap, settings.Columns.PayerName,           nameof(settings.Columns.PayerName));
        CheckColumn(colMap, settings.Columns.PanelName,           nameof(settings.Columns.PanelName));
        CheckColumn(colMap, settings.Columns.ForecastingP,        nameof(settings.Columns.ForecastingP));
        CheckColumn(colMap, settings.Columns.PayStatus,           nameof(settings.Columns.PayStatus));
        CheckColumn(colMap, settings.Columns.DenialCode,          nameof(settings.Columns.DenialCode));
        CheckColumn(colMap, settings.Columns.DenialDescription,   nameof(settings.Columns.DenialDescription));
        CheckColumn(colMap, settings.Columns.ExpectedPaymentDate, nameof(settings.Columns.ExpectedPaymentDate));
        CheckColumn(colMap, settings.Columns.FirstBilledDate,     nameof(settings.Columns.FirstBilledDate));
        CheckColumn(colMap, settings.Columns.ModeAllowedAmount,   nameof(settings.Columns.ModeAllowedAmount));
        CheckColumn(colMap, settings.Columns.ModeInsurancePaid,   nameof(settings.Columns.ModeInsurancePaid));
        CheckColumn(colMap, settings.Columns.AllowedAmount,       nameof(settings.Columns.AllowedAmount));
        CheckColumn(colMap, settings.Columns.InsurancePayment,    nameof(settings.Columns.InsurancePayment));
        Console.WriteLine();

        var records = new List<ClaimRecord>(table.Rows.Count);

        foreach (var row in table.Rows)
        {
            var rawColumns = new Dictionary<string, string>(orderedHeaders.Count,
                StringComparer.OrdinalIgnoreCase);
            foreach (var header in orderedHeaders)
                rawColumns[header] = GetCsvCell(row, colMap, header);

            var record = new ClaimRecord
            {
                AccessionNumber     = GetCsvCell(row, colMap, settings.Columns.AccessionNumber),
                VisitNumber         = GetCsvCell(row, colMap, settings.Columns.VisitNumber),
                PayerName           = GetCsvCell(row, colMap, settings.Columns.PayerName),
                PanelName           = GetCsvCell(row, colMap, settings.Columns.PanelName),
                ForecastingP        = GetCsvCell(row, colMap, settings.Columns.ForecastingP),
                PayStatus           = GetCsvCell(row, colMap, settings.Columns.PayStatus),
                DenialCode          = GetCsvCell(row, colMap, settings.Columns.DenialCode),
                DenialDescription   = GetCsvCell(row, colMap, settings.Columns.DenialDescription),
                ExpectedPaymentDate = ParseCsvDate(row, colMap, settings.Columns.ExpectedPaymentDate),
                FirstBilledDate     = ParseCsvDate(row, colMap, settings.Columns.FirstBilledDate),
                ModeAllowedAmount   = ParseCsvDecimal(row, colMap, settings.Columns.ModeAllowedAmount),
                ModeInsurancePaid   = ParseCsvDecimal(row, colMap, settings.Columns.ModeInsurancePaid),
                AllowedAmount       = ParseCsvDecimal(row, colMap, settings.Columns.AllowedAmount),
                InsurancePayment    = ParseCsvDecimal(row, colMap, settings.Columns.InsurancePayment),
                RawColumns          = rawColumns,
                SourceHeaders       = []
            };

            records.Add(record);
        }

        // Propagate SourceHeaders to all records (mirrors xlsx path behaviour)
        foreach (var r in records)
            r.SourceHeaders = orderedHeaders;

        Console.WriteLine($"[Step 1] Loaded {records.Count} rows | {orderedHeaders.Count} columns per row. (CSV source)");
        PrintDistinctSample(records, "ForecastingP", r => r.ForecastingP);
        PrintDistinctSample(records, "PayStatus",    r => r.PayStatus);
        PrintDistinctSample(records, "ExpectedPaymentDate (null?)",
            r => r.ExpectedPaymentDate.HasValue ? "has value" : "NULL");

        return records;
    }

    private static string GetCsvCell(string[] row, Dictionary<string, int> colMap, string colName)
    {
        if (string.IsNullOrWhiteSpace(colName)) return string.Empty;
        if (!colMap.TryGetValue(colName, out int col)) return string.Empty;
        return col < row.Length ? row[col].Trim() : string.Empty;
    }

    private static DateTime? ParseCsvDate(string[] row, Dictionary<string, int> colMap, string colName)
    {
        var value = GetCsvCell(row, colMap, colName);
        if (string.IsNullOrWhiteSpace(value)) return null;

        if (DateTime.TryParse(value, out var parsed)) return parsed;

        // Excel serial date number exported as raw value (e.g. "46107")
        if (double.TryParse(value, System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out var oa)
            && oa is > 20000 and < 80000)
        {
            try { return DateTime.FromOADate(oa); } catch { /* fall through */ }
        }

        return null;
    }

    private static decimal ParseCsvDecimal(string[] row, Dictionary<string, int> colMap, string colName)
    {
        var value = GetCsvCell(row, colMap, colName);
        if (string.IsNullOrWhiteSpace(value)) return 0m;

        // Tolerate currency formatting: "$1,234.56", "(123.45)" for negatives
        var cleaned  = value.Replace("$", "").Replace(",", "").Trim();
        bool negative = cleaned.StartsWith('(') && cleaned.EndsWith(')');
        if (negative) cleaned = cleaned[1..^1];

        if (decimal.TryParse(cleaned, System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out var parsed))
            return negative ? -parsed : parsed;

        return 0m;
    }

    // ── Column / cell helpers ─────────────────────────────────────────────────

    private static void CheckColumn(Dictionary<string, int> colMap, string configuredName, string fieldName)
    {
        if (string.IsNullOrWhiteSpace(configuredName))
        {
            Console.WriteLine($"         [BLANK]   {fieldName} => (not configured in appsettings.json)");
            return;
        }

        if (colMap.ContainsKey(configuredName))
        {
            Console.WriteLine($"         [OK]      {fieldName} => '{configuredName}'");
        }
        else
        {
            // Find the closest actual header to help diagnose typos / naming differences
            var closest = colMap.Keys
                .Where(k => k.Contains(configuredName, StringComparison.OrdinalIgnoreCase)
                         || configuredName.Contains(k, StringComparison.OrdinalIgnoreCase))
                .ToList();

            var hint = closest.Count > 0
                ? $" - closest match(es): [{string.Join(", ", closest.Select(h => $"'{h}'"))}]"
                : " - no similar header found in sheet";

            Console.WriteLine($"         [MISSING] {fieldName} => '{configuredName}'{hint}");
        }
    }

    private static void PrintDistinctSample(
        List<ClaimRecord> records, string label, Func<ClaimRecord, string> selector)
    {
        var distinct = records.Select(selector).Distinct().OrderBy(v => v).Take(20).ToList();
        Console.WriteLine($"[Diag] Distinct '{label}' values (up to 20): {string.Join(" | ", distinct)}");
    }

    private static Dictionary<string, int> BuildColumnMap(IXLWorksheet sheet)
    {
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var cell in sheet.Row(1).CellsUsed())
        {
            var header = cell.GetString().Trim();
            if (!string.IsNullOrEmpty(header))
                map[header] = cell.Address.ColumnNumber;
        }
        return map;
    }

    private static string GetCell(
        IXLWorksheet sheet, int row, Dictionary<string, int> colMap, string colName)
    {
        if (!colMap.TryGetValue(colName, out int col)) return string.Empty;
        return sheet.Cell(row, col).GetString().Trim();
    }

    private static DateTime? ParseDate(
        IXLWorksheet sheet, int row, Dictionary<string, int> colMap, string colName)
    {
        if (!colMap.TryGetValue(colName, out int col)) return null;
        var cell = sheet.Cell(row, col);
        if (cell.DataType == XLDataType.DateTime) return cell.GetDateTime();
        if (DateTime.TryParse(cell.GetString(), out var parsed)) return parsed;
        return null;
    }

    private static decimal ParseDecimal(
        IXLWorksheet sheet, int row, Dictionary<string, int> colMap, string colName)
    {
        if (!colMap.TryGetValue(colName, out int col)) return 0m;
        var cell = sheet.Cell(row, col);
        if (cell.DataType == XLDataType.Number) return (decimal)cell.GetDouble();
        if (decimal.TryParse(cell.GetString(), out var parsed)) return parsed;
        return 0m;
    }
}
