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

        // ── Build candidate file list ─────────────────────────────────────────
        // Exclusions:
        //   1. Previously generated output files  → contain "_Prediction_vs_NonPayment_Analysis_"
        //   2. Temporary files                    → name ends with "_temp" (before extension)
        const string outputMarker = "_Prediction_vs_NonPayment_Analysis_";
        const string tempSuffix   = "_temp";

        var files = Directory.GetFiles(targetFolder, "*.xlsx")
            .Select(f => new FileInfo(f))
            .Where(f => !f.Name.Contains(outputMarker, StringComparison.OrdinalIgnoreCase)
                     && !Path.GetFileNameWithoutExtension(f.Name)
                             .EndsWith(tempSuffix, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(f => f.CreationTime)
            .ToList();

        if (files.Count == 0)
            throw new FileNotFoundException(
                $"No source .xlsx files found in: {targetFolder}  " +
                $"(temp and generated output files are excluded)");

        // ── Try each candidate in order until one opens successfully ─────────
        // If a file is locked, corrupt, or unreadable → log and try the next one.
        FileInfo?      latestFile = null;
        XLWorkbook?    workbook   = null;
        IXLWorksheet?  sheet      = null;

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

        if (latestFile is null || workbook is null || sheet is null)
            throw new FileNotFoundException(
                $"All candidate .xlsx files in '{targetFolder}' failed to open. Check logs above.");

        Console.WriteLine($"[Step 1] Using report      : {latestFile.FullName}");

        // ── Extract RunId: text before first '_' in the file name ─────────────
        var fileNameOnly  = Path.GetFileNameWithoutExtension(latestFile.Name);
        var underscoreIdx = fileNameOnly.IndexOf('_');
        var runId         = underscoreIdx > 0 ? fileNameOnly[..underscoreIdx] : fileNameOnly;
        Console.WriteLine($"[Step 1] RunId extracted   : {runId}  (source: '{latestFile.Name}')");

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

        // Find the most recently WRITTEN source .xlsx file anywhere under rootFolder.
        // Using LastWriteTimeUtc is reliable regardless of how/when the folder was created
        // or copied — it always reflects when the file content was last changed.
        var newestFile = Directory
            .EnumerateFiles(rootFolder, "*.xlsx", SearchOption.AllDirectories)
            .Where(f => !Path.GetFileName(f)
                            .Contains(outputMarker, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .OrderByDescending(fi => fi.LastWriteTimeUtc)
            .FirstOrDefault();

        if (newestFile is not null)
        {
            var dir = newestFile.DirectoryName!;
            return (dir, Path.GetFileName(dir),
                $"Fallback: newest source .xlsx by LastWriteTime → {newestFile.FullName}");
        }

        throw new FileNotFoundException($"No source .xlsx files found anywhere under: {rootFolder}");
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
                ? $" — closest match(es): [{string.Join(", ", closest.Select(h => $"'{h}'"))}]"
                : " — no similar header found in sheet";

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