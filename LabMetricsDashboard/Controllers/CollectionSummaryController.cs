using LabMetricsDashboard.Models;
using System.Diagnostics;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Controller for the Collection Summary report.
/// Tabs: Monthly Claim Volume, Weekly Claim Volume,
///       Top 5 Insurance Reimbursement %, Top 5 Insurance Total Payments,
///       Panel Averages, Insurance vs Aging, Panel vs Payment,
///       Rep vs Payments, Insurance vs Payment %, CPT vs Payment %.
/// </summary>
public class CollectionSummaryController : Controller
{
    private readonly LabSettings _labSettings;
    private readonly ICollectionSummaryRepository _repo;
    private readonly ILogger<CollectionSummaryController> _logger;

    public CollectionSummaryController(
        LabSettings labSettings,
        ICollectionSummaryRepository repo,
        ILogger<CollectionSummaryController> logger)
    {
        _labSettings = labSettings;
        _repo = repo;
        _logger = logger;
    }

    /// <summary>
    /// GET /CollectionSummary?lab=…&amp;filterPayerNames=…&amp;filterPanelNames=…
    /// </summary>
    public async Task<IActionResult> Index(
        string? lab,
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
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab))
            return View(new CollectionSummaryViewModel { AvailableLabs = availableLabs });

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var config))
        {
            return View(new CollectionSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab = selectedLab,
                ErrorMessage = $"Configuration not found for {selectedLab}.",
            });
        }

        if (!config.EnableCollectionReport)
        {
            return View(new CollectionSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab = selectedLab,
                ErrorMessage = $"Collection Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
            });
        }

        if (!config.LineClaimEnable)
        {
            return View(new CollectionSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab = selectedLab,
                ErrorMessage = $"Collection Summary is currently not available for {selectedLab}.",
            });
        }

        var showTotalPayments = !config.DisableShowTop5TotalPayments;
        var useLineEncounters = !string.IsNullOrWhiteSpace(config.CollectionOutput)
            && string.Equals(config.CollectionOutput, "table1", StringComparison.OrdinalIgnoreCase);

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return View(new CollectionSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab = selectedLab,
                ErrorMessage = $"Collection Summary is currently not available for {selectedLab}. No connection string configured.",
            });
        }

        try
        {
            var pageSw = Stopwatch.StartNew();

            // Fetch filter options once (was duplicated in 4 queries before)
            var filterOptions = await _repo.GetFilterOptionsAsync(connStr, ct);

            var payerFilter = filterPayerNames.Count > 0 ? filterPayerNames : null;
            var panelFilter = filterPanelNames.Count > 0 ? filterPanelNames : null;

            DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
            DateOnly.TryParse(filterFirstBillTo, out var fbTo);
            DateOnly.TryParse(filterDosFrom, out var dosFrom);
            DateOnly.TryParse(filterDosTo, out var dosTo);
            DateOnly.TryParse(filterCheckDateFrom, out var cdFrom);
            DateOnly.TryParse(filterCheckDateTo, out var cdTo);

            DateOnly? fbFromN = fbFrom == default ? null : fbFrom;
            DateOnly? fbToN   = fbTo   == default ? null : fbTo;
            DateOnly? dosFromN = dosFrom == default ? null : dosFrom;
            DateOnly? dosToN   = dosTo   == default ? null : dosTo;
            DateOnly? cdFromN = cdFrom == default ? null : cdFrom;
            DateOnly? cdToN   = cdTo   == default ? null : cdTo;

            var monthlyRule = config.CollectionSummary?.Rule;
<<<<<<< HEAD
            var weeklyRule  = config.CollectionSummary?.Week;
=======
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5

            var monthlyVolumeTask = _repo.GetCollectionMonthlyVolumeAsync(
                connStr, monthlyRule, useLineEncounters, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var weeklyVolumeTask = _repo.GetCollectionWeeklyVolumeAsync(
                connStr, useLineEncounters, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, weeklyRule, ct);

            var reimbursementTask = _repo.GetTop5ReimbursementAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var totalPaymentsTask = showTotalPayments
                ? _repo.GetTop5TotalPaymentsAsync(connStr, payerFilter, panelFilter,
                    fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct)
                : Task.FromResult(new Top5TotalPaymentsResult([]));

            var insuranceAgingTask = _repo.GetInsuranceAgingAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var panelPaymentTask = _repo.GetPanelPaymentAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var repPaymentTask = _repo.GetRepPaymentAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var insurancePaymentPctTask = _repo.GetInsurancePaymentPctAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var cptPaymentPctTask = _repo.GetCptPaymentPctAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var panelAveragesTask = _repo.GetPanelAveragesAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var statusSummaryTask = _repo.GetStatusSummaryAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var avgPaymentsTask = _repo.GetAvgPaymentsAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var providerSummaryTask = _repo.GetProviderSummaryAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            await Task.WhenAll(monthlyVolumeTask, weeklyVolumeTask, reimbursementTask, totalPaymentsTask,
                insuranceAgingTask, panelPaymentTask, repPaymentTask, insurancePaymentPctTask, cptPaymentPctTask,
                panelAveragesTask, statusSummaryTask, avgPaymentsTask, providerSummaryTask);

            var monthlyVolumeResult = await monthlyVolumeTask;
            var weeklyVolumeResult = await weeklyVolumeTask;
            var reimbursementResult = await reimbursementTask;
            var totalPaymentsResult = await totalPaymentsTask;
            var insuranceAgingResult = await insuranceAgingTask;
            var panelPaymentResult = await panelPaymentTask;
            var repPaymentResult = await repPaymentTask;
            var insurancePaymentPctResult = await insurancePaymentPctTask;
            var cptPaymentPctResult = await cptPaymentPctTask;
            var panelAveragesResult = await panelAveragesTask;
            var statusSummaryResult = await statusSummaryTask;
            var avgPaymentsResult = await avgPaymentsTask;
            var providerSummaryResult = await providerSummaryTask;

            var repPivot = BuildRepPaymentPivot(repPaymentResult.Rows);

            _logger.LogInformation(
                "CollectionSummary page total for '{Lab}': {Ms}ms", selectedLab, pageSw.ElapsedMilliseconds);

            return View(new CollectionSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab = selectedLab,
                CollectionSummaryRule = monthlyRule,
                FilterPayerNames = filterPayerNames,
                FilterPanelNames = filterPanelNames,
                FilterFirstBillFrom = filterFirstBillFrom,
                FilterFirstBillTo = filterFirstBillTo,
                FilterDosFrom = filterDosFrom,
                FilterDosTo = filterDosTo,
                FilterCheckDateFrom = filterCheckDateFrom,
                FilterCheckDateTo = filterCheckDateTo,
                PayerNames = filterOptions.PayerNames,
                PanelNames = filterOptions.PanelNames,
                MonthlyClaimVolume = BuildCollectionMonthlyPivot(monthlyVolumeResult),
                WeeklyClaimVolume = BuildCollectionWeeklyPivot(weeklyVolumeResult),
                UsesLineEncounters = useLineEncounters,
                Top5Reimbursement = reimbursementResult.Rows,
                Top5TotalPayments = totalPaymentsResult.Rows,
                ShowTop5TotalPayments = showTotalPayments,
                InsuranceAging = insuranceAgingResult.Rows,
                PanelPayments = panelPaymentResult.Rows,
                RepPayments = repPivot,
                InsurancePaymentPct = insurancePaymentPctResult.Rows,
                CptPaymentPct = cptPaymentPctResult.Rows,
                PanelAverages = panelAveragesResult.PanelRows,
                StatusSummary = statusSummaryResult,
                AvgPayments = avgPaymentsResult,
                ProviderSummary = providerSummaryResult,
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Collection Summary query failed for lab '{LabName}'.", selectedLab);
            return View(new CollectionSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab = selectedLab,
                ErrorMessage = $"Failed to load Collection Summary: {ex.Message}",
            });
        }
    }

    /// <summary>
    /// Transforms flat Rep×Year×Month rows into the pivot structure for the view.
    /// Periods sorted chronologically; rows sorted by grand-total payments descending.
    /// </summary>
    private static RepPaymentPivot BuildRepPaymentPivot(List<RepPaymentFlatRow> flatRows)
    {
        if (flatRows.Count == 0)
            return RepPaymentPivot.Empty;

        // Discover distinct periods in chronological order
        var periods = flatRows
            .Select(r => new RepPaymentPeriod(r.Year, r.Month))
            .Distinct()
            .OrderBy(p => p.Year).ThenBy(p => p.Month)
            .ToList();

        // Group by SalesRepName
        var grouped = flatRows
            .GroupBy(r => r.SalesRepName, StringComparer.OrdinalIgnoreCase);

        var pivotRows = new List<RepPaymentPivotRow>();
        foreach (var g in grouped)
        {
            var cells = new Dictionary<RepPaymentPeriod, RepPaymentCell>();
            foreach (var r in g)
            {
                var period = new RepPaymentPeriod(r.Year, r.Month);
                cells[period] = new RepPaymentCell(r.NoOfClaims, r.InsurancePayments);
            }

            pivotRows.Add(new RepPaymentPivotRow
            {
                SalesRepName = g.Key,
                Cells = cells,
                GrandClaims = g.Sum(r => r.NoOfClaims),
                GrandPayments = g.Sum(r => r.InsurancePayments),
            });
        }

        // Sort rows by grand-total payments descending
        pivotRows.Sort((a, b) => b.GrandPayments.CompareTo(a.GrandPayments));

        return new RepPaymentPivot
        {
            Periods = periods,
            Rows = pivotRows,
        };
    }

    /// <summary>
    /// Wraps the repository result into the view-ready pivot structure.
    /// </summary>
    private static CollectionMonthlyVolumePivot BuildCollectionMonthlyPivot(CollectionMonthlyVolumeResult result)
    {
        if (result.PanelRows.Count == 0)
            return CollectionMonthlyVolumePivot.Empty;

        return new CollectionMonthlyVolumePivot
        {
            Periods = result.Periods,
            Years = result.Years,
            PanelRows = result.PanelRows,
            GrandTotalByMonth = result.GrandTotalByMonth,
            GrandTotalByYear = result.GrandTotalByYear,
            GrandTotalEncounters = result.GrandTotalEncounters,
            GrandTotalInsurancePaid = result.GrandTotalInsurancePaid,
        };
    }

    /// <summary>
    /// Wraps the weekly repository result into the view-ready pivot structure.
    /// </summary>
    private static CollectionWeeklyVolumePivot BuildCollectionWeeklyPivot(CollectionWeeklyVolumeResult result)
    {
        if (result.PanelRows.Count == 0)
            return CollectionWeeklyVolumePivot.Empty;

        return new CollectionWeeklyVolumePivot
        {
            Weeks = result.Weeks,
            PanelRows = result.PanelRows,
            GrandTotalByWeek = result.GrandTotalByWeek,
            GrandTotalEncounters = result.GrandTotalEncounters,
            GrandTotalInsurancePaid = result.GrandTotalInsurancePaid,
        };
    }

    /// <summary>
    /// Exports Collection Summary report outputs plus raw data to an Excel file, respecting the current filters.
    /// </summary>
    public async Task<IActionResult> ExportExcel(
        string? lab,
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
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.LineClaimEnable
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            TempData["ExportError"] = "Export is not available for the selected lab.";
            return RedirectToAction(nameof(Index), new { lab });
        }

        var connStr = config.DbConnectionString;
        var showTotalPayments = !config.DisableShowTop5TotalPayments;
        var useLineEncounters = !string.IsNullOrWhiteSpace(config.CollectionOutput)
            && string.Equals(config.CollectionOutput, "table1", StringComparison.OrdinalIgnoreCase);

        var monthlyRule = config.CollectionSummary?.Rule;
<<<<<<< HEAD
        var weeklyRule  = config.CollectionSummary?.Week;
=======
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5

        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);
        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterCheckDateFrom, out var cdFrom);
        DateOnly.TryParse(filterCheckDateTo, out var cdTo);

        DateOnly? fbFromN = fbFrom == default ? null : fbFrom;
        DateOnly? fbToN   = fbTo   == default ? null : fbTo;
        DateOnly? dosFromN = dosFrom == default ? null : dosFrom;
        DateOnly? dosToN   = dosTo   == default ? null : dosTo;
        DateOnly? cdFromN = cdFrom == default ? null : cdFrom;
        DateOnly? cdToN   = cdTo   == default ? null : cdTo;

        var payerFilter = filterPayerNames.Count > 0 ? filterPayerNames : null;
        var panelFilter = filterPanelNames.Count > 0 ? filterPanelNames : null;

        try
        {
            // Fetch all report data in parallel
            var monthlyVolumeTask = _repo.GetCollectionMonthlyVolumeAsync(
                connStr, monthlyRule, useLineEncounters, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var weeklyVolumeTask = _repo.GetCollectionWeeklyVolumeAsync(
                connStr, useLineEncounters, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, weeklyRule, ct);
            var reimbursementTask = _repo.GetTop5ReimbursementAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var totalPaymentsTask = showTotalPayments
                ? _repo.GetTop5TotalPaymentsAsync(connStr, payerFilter, panelFilter,
                    fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct)
                : Task.FromResult(new Top5TotalPaymentsResult([]));
            var insuranceAgingTask = _repo.GetInsuranceAgingAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var panelPaymentTask = _repo.GetPanelPaymentAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var repPaymentTask = _repo.GetRepPaymentAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var insurancePaymentPctTask = _repo.GetInsurancePaymentPctAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var cptPaymentPctTask = _repo.GetCptPaymentPctAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var panelAveragesTask = _repo.GetPanelAveragesAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var avgPaymentsTask = _repo.GetAvgPaymentsAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var statusSummaryTask = _repo.GetStatusSummaryAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var providerSummaryTask = _repo.GetProviderSummaryAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            // Fetch raw data in parallel
            var claimTask = _repo.GetClaimLevelDataExportAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var lineTask = _repo.GetLineLevelDataExportAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            await Task.WhenAll(
                monthlyVolumeTask, weeklyVolumeTask, reimbursementTask, totalPaymentsTask,
                insuranceAgingTask, panelPaymentTask, repPaymentTask, insurancePaymentPctTask,
                cptPaymentPctTask, panelAveragesTask, avgPaymentsTask,
                statusSummaryTask, providerSummaryTask,
                claimTask, lineTask);

            var vm = new CollectionSummaryViewModel
            {
                SelectedLab = selectedLab,
                CollectionSummaryRule = monthlyRule,
                MonthlyClaimVolume = BuildCollectionMonthlyPivot(await monthlyVolumeTask),
                WeeklyClaimVolume = BuildCollectionWeeklyPivot(await weeklyVolumeTask),
                UsesLineEncounters = useLineEncounters,
                Top5Reimbursement = (await reimbursementTask).Rows,
                Top5TotalPayments = (await totalPaymentsTask).Rows,
                ShowTop5TotalPayments = showTotalPayments,
                InsuranceAging = (await insuranceAgingTask).Rows,
                PanelPayments = (await panelPaymentTask).Rows,
                RepPayments = BuildRepPaymentPivot((await repPaymentTask).Rows),
                InsurancePaymentPct = (await insurancePaymentPctTask).Rows,
                CptPaymentPct = (await cptPaymentPctTask).Rows,
                PanelAverages = (await panelAveragesTask).PanelRows,
                AvgPayments = await avgPaymentsTask,
                StatusSummary = await statusSummaryTask,
                ProviderSummary = await providerSummaryTask,
            };

            var claimRows = await claimTask;
            var lineRows = await lineTask;

            // Build active filters summary
            var activeFilters = new List<(string Label, string? Value)>();
            if (payerFilter is { Count: > 0 })
                activeFilters.Add(("Payer Names", string.Join(", ", payerFilter)));
            if (panelFilter is { Count: > 0 })
                activeFilters.Add(("Panel Names", string.Join(", ", panelFilter)));
            if (!string.IsNullOrWhiteSpace(filterFirstBillFrom))
                activeFilters.Add(("First Bill From", filterFirstBillFrom));
            if (!string.IsNullOrWhiteSpace(filterFirstBillTo))
                activeFilters.Add(("First Bill To", filterFirstBillTo));
            if (!string.IsNullOrWhiteSpace(filterDosFrom))
                activeFilters.Add(("Date of Service From", filterDosFrom));
            if (!string.IsNullOrWhiteSpace(filterDosTo))
                activeFilters.Add(("Date of Service To", filterDosTo));
            if (!string.IsNullOrWhiteSpace(filterCheckDateFrom))
                activeFilters.Add(("Check Date From", filterCheckDateFrom));
            if (!string.IsNullOrWhiteSpace(filterCheckDateTo))
                activeFilters.Add(("Check Date To", filterCheckDateTo));

            using var workbook = CollectionSummaryExcelExportBuilder.CreateWorkbook(
                vm, claimRows, lineRows, selectedLab, activeFilters);

            // Free raw data lists early to reduce peak memory before SaveAs
            claimRows.Clear();
            lineRows.Clear();

            var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(
                Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_CollectionSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            // Signal the browser that the download is ready (used by the progress overlay JS).
            Response.Cookies.Append("csExportDone", "1", new CookieOptions
            {
                Path = "/",
                HttpOnly = false,
                SameSite = SameSiteMode.Lax,
                MaxAge = TimeSpan.FromSeconds(30),
            });

            return File(
                stream,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Collection Summary Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(Index), new { lab });
        }
    }
}
