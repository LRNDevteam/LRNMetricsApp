using LabMetricsDashboard.Models;
using System.Diagnostics;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

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
    private readonly IAnalysisRangeService _analysisRange;
    private readonly INotesRepository _notes;
    private readonly ILogger<CollectionSummaryController> _logger;

    public CollectionSummaryController(
        LabSettings labSettings,
        ICollectionSummaryRepository repo,
        IAnalysisRangeService analysisRange,
        INotesRepository notes,
        ILogger<CollectionSummaryController> logger)
    {
        _labSettings = labSettings;
        _repo = repo;
        _analysisRange = analysisRange;
        _notes = notes;
        _logger = logger;
    }

    /// <summary>True when the resolved aggregate prefix maps to NorthWest ("NW").</summary>
    private static bool IsNorthWest(string? aggregatePrefix) =>
        string.Equals(aggregatePrefix, "NW", StringComparison.OrdinalIgnoreCase);


    /// <summary>
    /// GET /CollectionSummary?lab=�&amp;filterPayerNames=�&amp;filterPanelNames=�
    /// </summary>
    public IActionResult Index(
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

        // ?? Step 1: Resolve aggregate prefix + filter state ?????????????????
        // Done early so both the filter-dropdown query and the tab-data query
        // can share the same computed values without repeating the logic.
        //
        // Panel column mapping:
        //   NorthWest            ? PanelType
        //   All other labs       ? PanelName
        // Payer always uses PayerName_Raw for every lab.
        var panelColumn = LabCollectionPrefix.GetPanelColumn(selectedLab);

        bool hasActiveFilters =
               filterPayerNames.Count > 0
            || filterPanelNames.Count > 0
            || !string.IsNullOrWhiteSpace(filterFirstBillFrom)
            || !string.IsNullOrWhiteSpace(filterFirstBillTo)
            || !string.IsNullOrWhiteSpace(filterDosFrom)
            || !string.IsNullOrWhiteSpace(filterDosTo)
            || !string.IsNullOrWhiteSpace(filterCheckDateFrom)
            || !string.IsNullOrWhiteSpace(filterCheckDateTo);

        string? aggregatePrefix = config.EnableCollectionSummaryReport
            ? LabCollectionPrefix.GetPrefix(selectedLab)
            : null;
        bool useAggregates = aggregatePrefix is not null && !hasActiveFilters;

        // Page chrome first — monthly, Top 5, filters, and banner load after HTML.
        var pageSw = Stopwatch.StartNew();
        var monthlyRule = config.CollectionSummary?.Rule;
        FirstPaintLog.Write(_logger, "Collection", selectedLab, "shell", pageSw.ElapsedMilliseconds,
            "html-first");

        return View(new CollectionSummaryViewModel
        {
            AvailableLabs        = availableLabs,
            SelectedLab          = selectedLab,
            CollectionSummaryRule = monthlyRule,
            AnalysisRange        = AnalysisRangeInfo.Empty,
            FilterPayerNames     = filterPayerNames,
            FilterPanelNames     = filterPanelNames,
            FilterFirstBillFrom  = filterFirstBillFrom,
            FilterFirstBillTo    = filterFirstBillTo,
            FilterDosFrom        = filterDosFrom,
            FilterDosTo          = filterDosTo,
            FilterCheckDateFrom  = filterCheckDateFrom,
            FilterCheckDateTo    = filterCheckDateTo,
            PayerNames           = [],
            PanelNames           = [],
            UsesLineEncounters   = useLineEncounters,
            ShowTop5TotalPayments = showTotalPayments,
            ShowInsuranceVsPayment = true,
            IsAggregateMode      = useAggregates,
            SupportsAggregateMode = aggregatePrefix is not null,
            LazyLoadTabs         = true,
        });
    }

    /// <summary>
    /// Filter dropdowns and analysis-range banner after Collection Summary HTML has landed.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> GetMeta(
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
        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return Json(new { payers = Array.Empty<string>(), panels = Array.Empty<string>() });

        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        bool hasActiveFilters =
               filterPayerNames.Count > 0
            || filterPanelNames.Count > 0
            || !string.IsNullOrWhiteSpace(filterFirstBillFrom)
            || !string.IsNullOrWhiteSpace(filterFirstBillTo)
            || !string.IsNullOrWhiteSpace(filterDosFrom)
            || !string.IsNullOrWhiteSpace(filterDosTo)
            || !string.IsNullOrWhiteSpace(filterCheckDateFrom)
            || !string.IsNullOrWhiteSpace(filterCheckDateTo);

        string? aggregatePrefix = config.EnableCollectionSummaryReport
            ? LabCollectionPrefix.GetPrefix(selectedLab)
            : null;
        var panelColumn = LabCollectionPrefix.GetPanelColumn(selectedLab);

        try
        {
            var metaSw = Stopwatch.StartNew();
            var optionsTask = LoadFilterOptionsAsync(
                config.DbConnectionString, panelColumn, selectedLab, aggregatePrefix, hasActiveFilters, ct);
            var analysisTask = _analysisRange.GetAsync(config.DbConnectionString, ct);
            await Task.WhenAll(optionsTask, analysisTask);
            var options = optionsTask.Result;
            var analysis = analysisTask.Result;
            FirstPaintLog.Write(_logger, "Collection", selectedLab, "meta", metaSw.ElapsedMilliseconds);

            return Json(new
            {
                payers = options.PayerNames,
                panels = options.PanelNames,
                weekFolder = analysis.WeekFolder,
                runId = analysis.RunId,
                inserted = analysis.InsertedDateTime?.ToString("MMM d, yyyy h:mm tt")
            });
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return Json(new { payers = Array.Empty<string>(), panels = Array.Empty<string>() });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Collection GetMeta failed for lab '{Lab}'.", selectedLab);
            return Json(new { payers = Array.Empty<string>(), panels = Array.Empty<string>() });
        }
    }

    /// <summary>
    /// Loads filter dropdown values. Uses the fast aggregate snapshot path when the lab
    /// has a known prefix and no filters are active; falls back to a live ClaimLevelData
    /// query otherwise.
    /// </summary>
    private async Task<CollectionFilterOptions> LoadFilterOptionsAsync(
        string connStr, string panelColumn, string labName, string? aggregatePrefix,
        bool hasActiveFilters, CancellationToken ct)
    {
        try
        {
            CollectionFilterOptions options;
            if (aggregatePrefix is not null && !hasActiveFilters)
            {
                // Aggregate snapshot is tiny � orders of magnitude faster than ClaimLevelData.
                options = await _repo.GetFilterOptionsFromAggregatesAsync(connStr, aggregatePrefix, ct);
                _logger.LogInformation(
                    "CollectionSummary FilterOptions '{Lab}' (aggregate fast path): payers={P}, panels={N}",
                    labName, options.PayerNames.Count, options.PanelNames.Count);
            }
            else
            {
                options = await _repo.GetFilterOptionsAsync(connStr, panelColumn, ct);
                _logger.LogInformation(
                    "CollectionSummary FilterOptions '{Lab}': payers={P}, panels={N} (panelCol={Col})",
                    labName, options.PayerNames.Count, options.PanelNames.Count, panelColumn);
            }
            return options;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "CollectionSummary FilterOptions failed for '{Lab}' (panelCol={Col}).",
                labName, panelColumn);
            return new CollectionFilterOptions([], []);
        }
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
    /// Returns the HTML for a single tab pane, called via AJAX for tabs that were not
    /// pre-loaded on page load (live / lazy mode).
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> GetTabPartial(
        string tab,
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
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return BadRequest();

        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        var connStr = config.DbConnectionString;
        var useLineEncounters = !string.IsNullOrWhiteSpace(config.CollectionOutput)
            && string.Equals(config.CollectionOutput, "table1", StringComparison.OrdinalIgnoreCase);

        bool hasActiveFilters =
               filterPayerNames.Count > 0
            || filterPanelNames.Count > 0
            || !string.IsNullOrWhiteSpace(filterFirstBillFrom)
            || !string.IsNullOrWhiteSpace(filterFirstBillTo)
            || !string.IsNullOrWhiteSpace(filterDosFrom)
            || !string.IsNullOrWhiteSpace(filterDosTo)
            || !string.IsNullOrWhiteSpace(filterCheckDateFrom)
            || !string.IsNullOrWhiteSpace(filterCheckDateTo);

        string? aggregatePrefix = config.EnableCollectionSummaryReport
            ? LabCollectionPrefix.GetPrefix(selectedLab)
            : null;
        bool useAggregates = aggregatePrefix is not null && !hasActiveFilters;

        _logger.LogInformation("CollectionSummary[GetTabPartial] Lab={Lab}, AggregatePrefix={Prefix}, UseAggregates={UseAgg}, HasFilters={HasFilters}, Tab={Tab}",
            selectedLab, aggregatePrefix ?? "null", useAggregates, hasActiveFilters, tab);

        var payerFilter = filterPayerNames.Count > 0 ? filterPayerNames : null;
        var panelFilter = filterPanelNames.Count > 0 ? filterPanelNames : null;

        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo,   out var fbTo);
        DateOnly.TryParse(filterDosFrom,        out var dosFrom);
        DateOnly.TryParse(filterDosTo,          out var dosTo);
        DateOnly.TryParse(filterCheckDateFrom,  out var cdFrom);
        DateOnly.TryParse(filterCheckDateTo,    out var cdTo);

        DateOnly? fbFromN  = fbFrom  == default ? null : fbFrom;
        DateOnly? fbToN    = fbTo    == default ? null : fbTo;
        DateOnly? dosFromN = dosFrom == default ? null : dosFrom;
        DateOnly? dosToN   = dosTo   == default ? null : dosTo;
        DateOnly? cdFromN  = cdFrom  == default ? null : cdFrom;
        DateOnly? cdToN    = cdTo    == default ? null : cdTo;

        // Shared base view model � only the tab-specific data field is populated.
        var vm = new CollectionSummaryViewModel
        {
            SelectedLab         = selectedLab,
            FilterPayerNames    = filterPayerNames,
            FilterPanelNames    = filterPanelNames,
            FilterFirstBillFrom = filterFirstBillFrom,
            FilterFirstBillTo   = filterFirstBillTo,
            FilterDosFrom       = filterDosFrom,
            FilterDosTo         = filterDosTo,
            FilterCheckDateFrom = filterCheckDateFrom,
            FilterCheckDateTo   = filterCheckDateTo,
            UsesLineEncounters  = useLineEncounters,
            IsAggregateMode     = useAggregates,
        };

        try
        {
            switch (tab?.ToLowerInvariant())
            {
                case "mcv":
                    var mcv = useAggregates
                        ? await _repo.GetCollectionMonthlyVolumeFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetCollectionMonthlyVolumeAsync(
                            connStr, selectedLab, useLineEncounters, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
                    vm.MonthlyClaimVolume = BuildCollectionMonthlyPivot(mcv);
                    FirstPaintLog.Write(_logger, "Collection", selectedLab, "tab-mcv", 0);
                    ViewData["CsPaneOnly"] = "mcv";
                    return PartialView("Index", vm);

                case "top5":
                    var reimb = useAggregates
                        ? await _repo.GetTop5ReimbursementFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetTop5ReimbursementAsync(
                            connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    var totPay = !config.DisableShowTop5TotalPayments
                        ? (useAggregates
                            ? await _repo.GetTop5TotalPaymentsFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                            : await _repo.GetTop5TotalPaymentsAsync(
                                connStr, payerFilter, panelFilter,
                                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct))
                        : new Top5TotalPaymentsResult([]);
                    vm.Top5Reimbursement = reimb.Rows;
                    vm.Top5TotalPayments = totPay.Rows;
                    vm.ShowTop5TotalPayments = !config.DisableShowTop5TotalPayments;
                    FirstPaintLog.Write(_logger, "Collection", selectedLab, "tab-top5", 0);
                    ViewData["CsPaneOnly"] = "top5";
                    return PartialView("Index", vm);

                case "wcv":
                    var wcv = useAggregates
                        ? await _repo.GetCollectionWeeklyVolumeFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetCollectionWeeklyVolumeAsync(connStr, useLineEncounters, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.WeeklyClaimVolume = BuildCollectionWeeklyPivot(wcv);
                    return PartialView("_CsTabWcv", vm);

                case "panelavg":
                    var pa = useAggregates
                        ? await _repo.GetPanelAveragesFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetPanelAveragesAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.PanelAverages = pa.PanelRows;
                    return PartialView("_CsTabPanelAvg", vm);

                case "avgpay":
                    var ap = useAggregates
                        ? await _repo.GetAvgPaymentsFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetAvgPaymentsAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.AvgPayments = ap;
                    return PartialView("_CsTabAvgPayments", vm);

                case "aging":
                    var aging = useAggregates
                        ? await _repo.GetInsuranceAgingFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetInsuranceAgingAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.InsuranceAging = aging.Rows;
                    return PartialView("_CsTabAging", vm);

                case "panelpay":
                    var pp = useAggregates
                        ? await _repo.GetPanelPaymentFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetPanelPaymentAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.PanelPayments = pp.Rows;
                    return PartialView("_CsTabPanelPay", vm);

                case "inspctpay":
                    var ip = useAggregates
                        ? await _repo.GetInsurancePaymentPctFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetInsurancePaymentPctAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.InsurancePaymentPct = ip.Rows;
                    return PartialView("_CsTabInsPctPay", vm);

                case "insvspay":
                    var ivpPrefix = aggregatePrefix ?? LabCollectionPrefix.GetPrefix(selectedLab);
                    if (string.IsNullOrEmpty(ivpPrefix))
                    {
                        vm.InsuranceVsPayment = [];
                    }
                    else if (useAggregates)
                    {
                        vm.InsuranceVsPayment = await _repo.GetInsuranceVsPaymentFromAggregatesAsync(connStr, ivpPrefix, ct);
                    }
                    else
                    {
                        vm.InsuranceVsPayment = await _repo.GetInsuranceVsPaymentAsync(
                            connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    }
                    vm.ShowInsuranceVsPayment = true;
                    return PartialView("_CsTabInsVsPay", vm);

                case "cptpctpay":
                    var cp = useAggregates
                        ? await _repo.GetCptPaymentPctFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetCptPaymentPctAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.CptPaymentPct = cp.Rows;
                    return PartialView("_CsTabCptPctPay", vm);

                case "statussummary":
                    var ss = useAggregates
                        ? await _repo.GetStatusSummaryFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetStatusSummaryAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.StatusSummary = ss;
                    return PartialView("_CsTabStatusSummary", vm);

                case "provider":
                    var prov = useAggregates
                        ? await _repo.GetProviderSummaryFromAggregatesAsync(connStr, aggregatePrefix!, ct)
                        : await _repo.GetProviderSummaryAsync(connStr, payerFilter, panelFilter,
                            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
                    vm.ProviderSummary = prov;
                    return PartialView("_CsTabProvider", vm);

                default:
                    return BadRequest($"Unknown tab: {tab}");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GetTabPartial failed for tab '{Tab}', lab '{Lab}'.", tab, selectedLab);
            return Content(
                $"<div class='alert alert-warning'><i class='bi bi-exclamation-triangle-fill me-1'></i>Failed to load tab data: {System.Text.Encodings.Web.HtmlEncoder.Default.Encode(ex.Message)}</div>",
                "text/html");
        }
    }

    /// <summary>
    /// Builds the Collection Summary export view model (all summary sheets' data,
    /// fetched in parallel). Shared by ExportExcel and — PUBLIC for that reason —
    /// LRN.ReportWorker's CollectionReportGenerator, so the async export reuses the
    /// exact same repository queries and pivot logic.
    /// </summary>
    public async Task<CollectionSummaryViewModel> BuildCollectionExportViewModelAsync(
        string selectedLab, string connStr, bool useLineEncounters, bool showTotalPayments,
        List<string>? payerFilter, List<string>? panelFilter,
        DateOnly? fbFromN, DateOnly? fbToN,
        DateOnly? dosFromN, DateOnly? dosToN,
        DateOnly? cdFromN, DateOnly? cdToN,
        CancellationToken ct)
    {
        // Fetch all report data in parallel
        var monthlyVolumeTask = _repo.GetCollectionMonthlyVolumeAsync(
            connStr, selectedLab, useLineEncounters, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
        var weeklyVolumeTask = _repo.GetCollectionWeeklyVolumeAsync(
            connStr, useLineEncounters, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var reimbursementTask = _repo.GetTop5ReimbursementAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var totalPaymentsTask = showTotalPayments
            ? _repo.GetTop5TotalPaymentsAsync(connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct)
            : Task.FromResult(new Top5TotalPaymentsResult([]));
        var insuranceAgingTask = _repo.GetInsuranceAgingAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var panelPaymentTask = _repo.GetPanelPaymentAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var insurancePaymentPctTask = _repo.GetInsurancePaymentPctAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var cptPaymentPctTask = _repo.GetCptPaymentPctAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var panelAveragesTask = _repo.GetPanelAveragesAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var avgPaymentsTask = _repo.GetAvgPaymentsAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var statusSummaryTask = _repo.GetStatusSummaryAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);
        var providerSummaryTask = _repo.GetProviderSummaryAsync(
            connStr, payerFilter, panelFilter,
            fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct);

        // Soft-fail per sheet when a Collection Summary SP is not deployed on a lab DB
        // (SqlException 2812). One missing SP must not fail the whole Collection Report.
        // Also soft-fail SqlNullValueException so a single nullable column read cannot
        // abort the entire CollectionReport export (typed getters throw "Data is Null…").
        static async Task<T> AwaitOrDefaultAsync<T>(
            Task<T> task, T fallback, string sheet, string lab, ILogger logger)
        {
            try
            {
                return await task.ConfigureAwait(false);
            }
            catch (SqlException ex) when (ex.Number is 2812 or 208)
            {
                // 2812 = SP missing; 208 = snapshot table missing (e.g. Cert_CS_* not refreshed yet).
                logger.LogWarning(
                    "Collection export sheet '{Sheet}' skipped for lab {Lab}: missing SP/table ({Number}: {Message}).",
                    sheet, lab, ex.Number, ex.Message);
                return fallback;
            }
            catch (System.Data.SqlTypes.SqlNullValueException ex)
            {
                logger.LogWarning(ex,
                    "Collection export sheet '{Sheet}' skipped for lab {Lab}: null DB value on reader.",
                    sheet, lab);
                return fallback;
            }
        }

        var emptyMonthly = new CollectionMonthlyVolumeResult([], [], [], [], [], 0, 0m);
        var emptyWeekly = new CollectionWeeklyVolumeResult([], [], [], 0, 0m);

        return new CollectionSummaryViewModel
        {
            SelectedLab = selectedLab,
            MonthlyClaimVolume = BuildCollectionMonthlyPivot(
                await AwaitOrDefaultAsync(monthlyVolumeTask, emptyMonthly, "Monthly Claim Volume", selectedLab, _logger)),
            WeeklyClaimVolume = BuildCollectionWeeklyPivot(
                await AwaitOrDefaultAsync(weeklyVolumeTask, emptyWeekly, "Weekly Claim Volume", selectedLab, _logger)),
            UsesLineEncounters = useLineEncounters,
            Top5Reimbursement = (await AwaitOrDefaultAsync(
                reimbursementTask, new Top5ReimbursementResult([]), "Top 5 Reimbursement", selectedLab, _logger)).Rows,
            Top5TotalPayments = (await AwaitOrDefaultAsync(
                totalPaymentsTask, new Top5TotalPaymentsResult([]), "Top 5 Total Payments", selectedLab, _logger)).Rows,
            ShowTop5TotalPayments = showTotalPayments,
            InsuranceAging = (await AwaitOrDefaultAsync(
                insuranceAgingTask, new InsuranceAgingResult([]), "Insurance vs Aging", selectedLab, _logger)).Rows,
            PanelPayments = (await AwaitOrDefaultAsync(
                panelPaymentTask, new PanelPaymentResult([]), "Panel vs Payment", selectedLab, _logger)).Rows,
            InsurancePaymentPct = (await AwaitOrDefaultAsync(
                insurancePaymentPctTask, new InsurancePaymentPctResult([]), "Insurance vs Payment %", selectedLab, _logger)).Rows,
            CptPaymentPct = (await AwaitOrDefaultAsync(
                cptPaymentPctTask, new CptPaymentPctResult([]), "CPT vs Payment %", selectedLab, _logger)).Rows,
            PanelAverages = (await AwaitOrDefaultAsync(
                panelAveragesTask, new PanelAveragesResult([]), "Panel Averages", selectedLab, _logger)).PanelRows,
            AvgPayments = await AwaitOrDefaultAsync(
                avgPaymentsTask, new PanelAveragesResult([]), "Avg Payments", selectedLab, _logger),
            StatusSummary = await AwaitOrDefaultAsync(
                statusSummaryTask, StatusSummaryResult.Empty, "Status Summary", selectedLab, _logger),
            ProviderSummary = await AwaitOrDefaultAsync(
                providerSummaryTask, ProviderSummaryResult.Empty, "Provider Summary", selectedLab, _logger),
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

        bool hasActiveFilters = payerFilter is not null || panelFilter is not null
            || fbFromN.HasValue || fbToN.HasValue || dosFromN.HasValue || dosToN.HasValue
            || cdFromN.HasValue || cdToN.HasValue;

        // ── No-filter fast path: serve the pre-generated Excel if available ──────
        // ClaimLineCSVDataCapture generates this file after each data capture run.
        // Serving it avoids a full DB query and is significantly faster.
        if (!hasActiveFilters && !string.IsNullOrWhiteSpace(config.CollectionSummaryExcelPath))
        {
            var preGenFile = Directory
                .EnumerateFiles(config.CollectionSummaryExcelPath, "*.xlsx", SearchOption.TopDirectoryOnly)
                .OrderByDescending(System.IO.File.GetLastWriteTimeUtc)
                .FirstOrDefault();

            if (preGenFile is not null)
            {
                _logger.LogInformation(
                    "CollectionSummary ExportExcel '{Lab}': serving pre-generated file: {File}",
                    selectedLab, preGenFile);

                var safeLabName = string.Join("_", selectedLab.Split(
                    Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
                var downloadName = $"{safeLabName}_CollectionSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

                Response.Cookies.Append("csExportDone", "1", new CookieOptions
                {
                    Path     = "/",
                    HttpOnly = false,
                    SameSite = SameSiteMode.Lax,
                    MaxAge   = TimeSpan.FromSeconds(30),
                });

                var insights = await InsightsExcelBuilder.LoadAsync(_notes, connStr, "Collection Report", ct);
                try
                {
                    var bytes = InsightsExcelBuilder.InjectIntoExistingWorkbook(
                        preGenFile, insights, selectedLab, "Collection Report");
                    return File(bytes,
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        downloadName);
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex,
                        "CollectionSummary ExportExcel '{Lab}': could not inject Insights sheet; serving original file.",
                        selectedLab);
                }

                return File(
                    ExcelTheme.LoadWithAccounting(preGenFile),
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    downloadName);
            }

            _logger.LogInformation(
                "CollectionSummary ExportExcel '{Lab}': no pre-generated file found in '{Path}', generating fresh.",
                selectedLab, config.CollectionSummaryExcelPath);
        }

        try
        {
            // Check row counts before fetching raw data — skip sheets that exceed 200,000 rows
            // to avoid out-of-memory on large labs. (The async CollectionReport export via
            // LRN.ReportWorker has NO such limit — it streams the raw sheets in chunks.)
            const int RawDataRowLimit = 200_000;
            var claimCountTask = _repo.GetClaimLevelDataCountAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);
            var lineCountTask = _repo.GetLineLevelDataCountAsync(
                connStr, payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            var vm = await BuildCollectionExportViewModelAsync(
                selectedLab, connStr, useLineEncounters, showTotalPayments,
                payerFilter, panelFilter,
                fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, ct);

            int claimCount = await claimCountTask;
            int lineCount  = await lineCountTask;
            bool includeClaimRaw = claimCount <= RawDataRowLimit;
            bool includeLineRaw  = lineCount  <= RawDataRowLimit;

            _logger.LogInformation(
                "CollectionSummary ExportExcel '{Lab}': claimCount={C} (include={IC}), lineCount={L} (include={IL})",
                selectedLab, claimCount, includeClaimRaw, lineCount, includeLineRaw);

            // Fetch raw data only when within the row limit
            var claimRows = includeClaimRaw
                ? await _repo.GetClaimLevelDataExportAsync(connStr, payerFilter, panelFilter,
                    fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct)
                : [];
            var lineRows = includeLineRaw
                ? await _repo.GetLineLevelDataExportAsync(connStr, payerFilter, panelFilter,
                    fbFromN, fbToN, dosFromN, dosToN, cdFromN, cdToN, selectedLab, ct)
                : [];

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
                vm, claimRows, lineRows, selectedLab, activeFilters,
                claimRowsOmitted: !includeClaimRaw ? claimCount : null,
                lineRowsOmitted:  !includeLineRaw  ? lineCount  : null);

            var liveInsights = await InsightsExcelBuilder.LoadAsync(_notes, connStr, "Collection Report", ct);
            InsightsExcelBuilder.InsertAsFirstSheet(workbook, liveInsights, selectedLab, "Collection Report");

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
