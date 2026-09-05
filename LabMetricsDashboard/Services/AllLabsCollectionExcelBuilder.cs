using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a combined Collection Summary Excel workbook that spans all configured labs.
///
/// Two paths:
/// <list type="bullet">
///   <item>
///     <b>No active filters</b> — each lab's pre-generated <c>.xlsx</c> file is located via
///     <see cref="LabCsvConfig.CollectionSummaryExcelPath"/> and its sheets are copied into the
///     combined workbook with the lab name prepended.  Labs without a pre-generated file fall
///     back to the live-query path automatically.
///   </item>
///   <item>
///     <b>Active filters</b> — the Collection Summary repository is called for each eligible lab
///     and the results are rendered using <see cref="CollectionSummaryExcelExportBuilder"/>.
///     Raw ClaimLevelData / LineLevelData sheets are omitted for any lab whose row count
///     exceeds <see cref="CollectionSummaryExcelExportBuilder.RawDataRowLimit"/>.
///   </item>
/// </list>
/// </summary>
public sealed class AllLabsCollectionExcelBuilder
{
    private readonly ICollectionSummaryRepository _repo;
    private readonly ILogger<AllLabsCollectionExcelBuilder> _logger;

    public AllLabsCollectionExcelBuilder(
        ICollectionSummaryRepository repo,
        ILogger<AllLabsCollectionExcelBuilder> logger)
    {
        _repo   = repo;
        _logger = logger;
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /// <summary>
    /// Builds the combined workbook.  Returns a <see cref="MemoryStream"/> positioned at 0.
    /// </summary>
    public async Task<MemoryStream> BuildAsync(
        IReadOnlyDictionary<string, LabCsvConfig> labConfigs,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterCheckDateFrom,
        string? filterCheckDateTo,
        CancellationToken ct = default)
    {
        bool hasActiveFilters =
               filterPayerNames is { Count: > 0 }
            || filterPanelNames is { Count: > 0 }
            || !string.IsNullOrWhiteSpace(filterFirstBillFrom)
            || !string.IsNullOrWhiteSpace(filterFirstBillTo)
            || !string.IsNullOrWhiteSpace(filterDosFrom)
            || !string.IsNullOrWhiteSpace(filterDosTo)
            || !string.IsNullOrWhiteSpace(filterCheckDateFrom)
            || !string.IsNullOrWhiteSpace(filterCheckDateTo);

        // Eligible labs: must have collection report enabled + a DB connection
        var eligibleLabs = labConfigs
            .Where(kv => kv.Value.EnableCollectionReport
                      && kv.Value.LineClaimEnable
                      && !string.IsNullOrWhiteSpace(kv.Value.DbConnectionString))
            .OrderBy(kv => kv.Key)
            .ToList();

        var combined = new XLWorkbook();

        foreach (var (labName, config) in eligibleLabs)
        {
            ct.ThrowIfCancellationRequested();

            try
            {
                if (!hasActiveFilters)
                    await AddLabFromFileOrLiveAsync(combined, labName, config, ct);
                else
                    await AddLabFromLiveQueryAsync(combined, labName, config,
                        filterPayerNames, filterPanelNames,
                        filterFirstBillFrom, filterFirstBillTo,
                        filterDosFrom, filterDosTo,
                        filterCheckDateFrom, filterCheckDateTo, ct);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "AllLabsCollection: failed to add lab '{Lab}'.", labName);
                AddErrorNoticeSheet(combined, labName, ex.Message);
            }
        }

        if (!combined.Worksheets.Any())
            combined.AddWorksheet("No Data");

        var stream = new MemoryStream();
        combined.SaveAs(stream);
        stream.Position = 0;
        return stream;
    }

    // ── No-filter path: use pre-generated file when available ────────────────

    private async Task AddLabFromFileOrLiveAsync(
        XLWorkbook combined, string labName, LabCsvConfig config, CancellationToken ct)
    {
        var excelFile = FindLatestExcelFile(config.CollectionSummaryExcelPath);

        if (excelFile is not null)
        {
            _logger.LogInformation(
                "AllLabsCollection: using pre-generated file for '{Lab}': {File}", labName, excelFile);
            CopySheetsFromFile(combined, excelFile, labName);
            return;
        }

        // No pre-generated file — fall back to aggregate/live query
        _logger.LogInformation(
            "AllLabsCollection: no pre-generated file for '{Lab}', falling back to live query.", labName);
        await AddLabFromLiveQueryAsync(combined, labName, config,
            null, null, null, null, null, null, null, null, ct);
    }

    /// <summary>
    /// Finds the most recently modified <c>.xlsx</c> file in <paramref name="folderPath"/>.
    /// Returns <c>null</c> when the folder is not configured, does not exist, or is empty.
    /// </summary>
    private static string? FindLatestExcelFile(string? folderPath)
    {
        if (string.IsNullOrWhiteSpace(folderPath) || !Directory.Exists(folderPath))
            return null;

        return Directory
            .EnumerateFiles(folderPath, "*.xlsx", SearchOption.TopDirectoryOnly)
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .FirstOrDefault();
    }

    /// <summary>
    /// Opens <paramref name="sourceFilePath"/> and copies every worksheet into
    /// <paramref name="dest"/>, prefixing each sheet name with the lab name.
    /// Sheet names are truncated to 31 characters (Excel limit).
    /// </summary>
    private static void CopySheetsFromFile(XLWorkbook dest, string sourceFilePath, string labName)
    {
        using var src = new XLWorkbook(sourceFilePath);
        ExcelTheme.ConvertCurrencyFormatsToAccounting(src);
        var prefix = TruncateLabel(labName, 12) + "_";   // e.g. "PCRLabsofAme_"

        foreach (var ws in src.Worksheets)
        {
            var rawName = prefix + ws.Name;
            var safeName = rawName.Length <= 31 ? rawName : rawName[..31];

            // Ensure uniqueness by appending a counter if name already exists
            safeName = EnsureUniqueSheetName(dest, safeName);
            ws.CopyTo(dest, safeName);
        }
    }

    // ── Filtered path: live DB query per lab ─────────────────────────────────

    private async Task AddLabFromLiveQueryAsync(
        XLWorkbook combined,
        string labName,
        LabCsvConfig config,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterCheckDateFrom,
        string? filterCheckDateTo,
        CancellationToken ct)
    {
        var connStr = config.DbConnectionString!;
        var showTotalPayments = !config.DisableShowTop5TotalPayments;
        var useLineEncounters = !string.IsNullOrWhiteSpace(config.CollectionOutput)
            && string.Equals(config.CollectionOutput, "table1", StringComparison.OrdinalIgnoreCase);

        ParseDates(filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo,
            filterCheckDateFrom, filterCheckDateTo,
            out var fbFromN, out var fbToN, out var dosFromN, out var dosToN, out var cdFromN, out var cdToN);

        var payerFilter = filterPayerNames is { Count: > 0 } ? filterPayerNames : null;
        var panelFilter = filterPanelNames is { Count: > 0 } ? filterPanelNames : null;

        // Determine whether to use aggregate snapshots (no-filter + EnableCollectionSummaryReport)
        bool hasFilters = payerFilter is not null || panelFilter is not null
            || fbFromN.HasValue || fbToN.HasValue || dosFromN.HasValue || dosToN.HasValue
            || cdFromN.HasValue || cdToN.HasValue;

        string? aggregatePrefix = config.EnableCollectionSummaryReport && !hasFilters
            ? LabCollectionPrefix.GetPrefix(labName)
            : null;
        bool useAggregates = aggregatePrefix is not null;

        // Fetch report tabs in parallel
        var monthlyTask     = useAggregates
            ? _repo.GetCollectionMonthlyVolumeFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetCollectionMonthlyVolumeAsync(connStr, labName, useLineEncounters, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
        var weeklyTask      = useAggregates
            ? _repo.GetCollectionWeeklyVolumeFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetCollectionWeeklyVolumeAsync(connStr, useLineEncounters, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var reimbTask       = useAggregates
            ? _repo.GetTop5ReimbursementFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetTop5ReimbursementAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var totPayTask      = showTotalPayments
            ? (useAggregates
                ? _repo.GetTop5TotalPaymentsFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                : _repo.GetTop5TotalPaymentsAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct))
            : Task.FromResult(new Top5TotalPaymentsResult([]));
        var agingTask       = useAggregates
            ? _repo.GetInsuranceAgingFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetInsuranceAgingAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var panelPayTask    = useAggregates
            ? _repo.GetPanelPaymentFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetPanelPaymentAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var insPctTask      = useAggregates
            ? _repo.GetInsurancePaymentPctFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetInsurancePaymentPctAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var cptPctTask      = useAggregates
            ? _repo.GetCptPaymentPctFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetCptPaymentPctAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var panelAvgTask    = useAggregates
            ? _repo.GetPanelAveragesFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetPanelAveragesAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var avgPayTask      = useAggregates
            ? _repo.GetAvgPaymentsFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetAvgPaymentsAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var statusTask      = useAggregates
            ? _repo.GetStatusSummaryFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetStatusSummaryAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);
        var providerTask    = useAggregates
            ? _repo.GetProviderSummaryFromAggregatesAsync(connStr, aggregatePrefix!, ct)
            : _repo.GetProviderSummaryAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct);

        // Count raw rows before fetching to enforce the 200K limit
        var claimCountTask = _repo.GetClaimLevelDataCountAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
        var lineCountTask  = _repo.GetLineLevelDataCountAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

        await Task.WhenAll(
            monthlyTask, weeklyTask, reimbTask, totPayTask,
            agingTask, panelPayTask, insPctTask,
            cptPctTask, panelAvgTask, avgPayTask, statusTask, providerTask,
            claimCountTask, lineCountTask);

        int claimCount       = await claimCountTask;
        int lineCount        = await lineCountTask;
        bool includeClaimRaw = claimCount <= CollectionSummaryExcelExportBuilder.RawDataRowLimit;
        bool includeLineRaw  = lineCount  <= CollectionSummaryExcelExportBuilder.RawDataRowLimit;

        var claimRows = includeClaimRaw
            ? await _repo.GetClaimLevelDataExportAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct)
            : [];
        var lineRows = includeLineRaw
            ? await _repo.GetLineLevelDataExportAsync(connStr, payerFilter, panelFilter, fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, labName, ct)
            : [];

        // Build a standalone workbook for this lab, then copy its sheets into the combined workbook
        var monthlyResult = await monthlyTask;
        var weeklyResult  = await weeklyTask;
        var vm = new CollectionSummaryViewModel
        {
            SelectedLab           = labName,
            MonthlyClaimVolume    = BuildCollectionMonthlyPivot(monthlyResult),
            WeeklyClaimVolume     = BuildCollectionWeeklyPivot(weeklyResult),
            UsesLineEncounters    = useLineEncounters,
            Top5Reimbursement     = (await reimbTask).Rows,
            Top5TotalPayments     = (await totPayTask).Rows,
            ShowTop5TotalPayments = showTotalPayments,
            InsuranceAging        = (await agingTask).Rows,
            PanelPayments         = (await panelPayTask).Rows,
            InsurancePaymentPct   = (await insPctTask).Rows,
            CptPaymentPct         = (await cptPctTask).Rows,
            PanelAverages         = (await panelAvgTask).PanelRows,
            AvgPayments           = await avgPayTask,
            StatusSummary         = await statusTask,
            ProviderSummary       = await providerTask,
            ShowInsuranceVsPayment = !string.Equals(
                LabCollectionPrefix.GetPrefix(labName), "NW",
                StringComparison.OrdinalIgnoreCase),
        };

        using var labWorkbook = CollectionSummaryExcelExportBuilder.CreateWorkbook(
            vm, claimRows, lineRows, labName,
            claimRowsOmitted: !includeClaimRaw ? claimCount : null,
            lineRowsOmitted:  !includeLineRaw  ? lineCount  : null);

        claimRows.Clear();
        lineRows.Clear();

        // Copy all sheets from the lab workbook into the combined workbook
        var prefix = TruncateLabel(labName, 12) + "_";
        foreach (var ws in labWorkbook.Worksheets)
        {
            var rawName  = prefix + ws.Name;
            var safeName = rawName.Length <= 31 ? rawName : rawName[..31];
            safeName = EnsureUniqueSheetName(combined, safeName);
            ws.CopyTo(combined, safeName);
        }

        _logger.LogInformation(
            "AllLabsCollection: added lab '{Lab}' (aggregate={Agg}), claim={C} rows, line={L} rows.",
            labName, useAggregates, claimCount, lineCount);
    }

    // ── Pivot helpers (mirrors CollectionSummaryController) ──────────────────

    private static CollectionMonthlyVolumePivot BuildCollectionMonthlyPivot(CollectionMonthlyVolumeResult result)
    {
        if (result.PanelRows.Count == 0) return CollectionMonthlyVolumePivot.Empty;
        return new CollectionMonthlyVolumePivot
        {
            Periods                = result.Periods,
            Years                  = result.Years,
            PanelRows              = result.PanelRows,
            GrandTotalByMonth      = result.GrandTotalByMonth,
            GrandTotalByYear       = result.GrandTotalByYear,
            GrandTotalEncounters   = result.GrandTotalEncounters,
            GrandTotalInsurancePaid = result.GrandTotalInsurancePaid,
        };
    }

    private static CollectionWeeklyVolumePivot BuildCollectionWeeklyPivot(CollectionWeeklyVolumeResult result)
    {
        if (result.PanelRows.Count == 0) return CollectionWeeklyVolumePivot.Empty;
        return new CollectionWeeklyVolumePivot
        {
            Weeks                  = result.Weeks,
            PanelRows              = result.PanelRows,
            GrandTotalByWeek       = result.GrandTotalByWeek,
            GrandTotalEncounters   = result.GrandTotalEncounters,
            GrandTotalInsurancePaid = result.GrandTotalInsurancePaid,
        };
    }

    // ── Error notice ─────────────────────────────────────────────────────────

    private static void AddErrorNoticeSheet(XLWorkbook wb, string labName, string message)
    {
        var sheetName = EnsureUniqueSheetName(wb, TruncateLabel(labName, 25) + "_ERROR");
        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = XLColor.Red;
        ws.Cell(1, 1).Value = $"Failed to load data for {labName}: {message}";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(1, 1).Style.Font.FontColor = XLColor.DarkRed;
        ws.Column(1).Width = 100;
    }

    // ── Utility ──────────────────────────────────────────────────────────────

    private static string EnsureUniqueSheetName(XLWorkbook wb, string name)
    {
        if (wb.Worksheets.All(ws => !ws.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            return name;

        for (int i = 2; i <= 999; i++)
        {
            var candidate = name.Length <= 28 ? $"{name}_{i}" : $"{name[..28]}_{i}";
            if (wb.Worksheets.All(ws => !ws.Name.Equals(candidate, StringComparison.OrdinalIgnoreCase)))
                return candidate;
        }
        return name + Guid.NewGuid().ToString("N")[..4];
    }

    private static string TruncateLabel(string s, int maxLen) =>
        s.Length <= maxLen ? s : s[..maxLen];

    private static void ParseDates(
        string? fbFrom, string? fbTo, string? dosFrom, string? dosTo, string? cdFrom, string? cdTo,
        out DateOnly? fbFromN, out DateOnly? fbToN,
        out DateOnly? dosFromN, out DateOnly? dosToN,
        out DateOnly? cdFromN,  out DateOnly? cdToN)
    {
        fbFromN  = TryParse(fbFrom);
        fbToN    = TryParse(fbTo);
        dosFromN = TryParse(dosFrom);
        dosToN   = TryParse(dosTo);
        cdFromN  = TryParse(cdFrom);
        cdToN    = TryParse(cdTo);

        static DateOnly? TryParse(string? s) =>
            DateOnly.TryParse(s, out var d) ? d : null;
    }
}
