using System.Globalization;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class PredictionController : Controller
{
    private const int PageSize = 50;

    private readonly LabSettings _labSettings;
    private readonly LabCsvFileResolver _resolver;
    private readonly PredictionReportParserService _parser;
    private readonly IPredictionDbRepository _dbRepo;
    private readonly PredictionInsightLoader _insightLoader;
    private readonly ILogger<PredictionController> _logger;

    public PredictionController(
        LabSettings labSettings,
        LabCsvFileResolver resolver,
        PredictionReportParserService parser,
        IPredictionDbRepository dbRepo,
        PredictionInsightLoader insightLoader,
        ILogger<PredictionController> logger)
    {
        _labSettings   = labSettings;
        _resolver      = resolver;
        _parser        = parser;
        _dbRepo        = dbRepo;
        _insightLoader = insightLoader;
        _logger        = logger;
    }

    /// <summary>
    /// Returns <see cref="LabCsvConfig.DbLabName"/> when set, otherwise the dashboard config key.
    /// Handles the case where the PredictionAnalysisApp stores data under a different lab name.
    /// </summary>
    private static string ResolveDbLabName(LabCsvConfig config, string dashboardLabKey) =>
        !string.IsNullOrWhiteSpace(config.DbLabName) ? config.DbLabName : dashboardLabKey;

    // GET /Prediction  or  /Prediction/Index?lab=PCRLabsofAmerica&...
    public async Task<IActionResult> Index(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode,
        int page = 1)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var labConfig = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg)
            ? cfg : null;

        // Check if Prediction feature is enabled for this lab
        if (labConfig?.EnablePrediction == false)
        {
            return View(new PredictionAnalysisViewModel
            {
                AvailableLabs        = availableLabs,
                SelectedLab          = selectedLab,
                PredictionAvailable  = false,
                ErrorMessage         = $"Prediction Analysis feature is not enabled for {selectedLab}. Please contact your administrator.",
                CurrentWeekStartDate = DateOnly.FromDateTime(DateTime.Today),
            });
        }

        // If DBEnabled is false return immediately with a "not available" view model
        if (labConfig?.DBEnabled == false)
        {
            return View(new PredictionAnalysisViewModel
            {
                AvailableLabs        = availableLabs,
                SelectedLab          = selectedLab,
                PredictionAvailable  = false,
                CurrentWeekStartDate = DateOnly.FromDateTime(DateTime.Today),
            });
        }

        // Week-start cutoff (Monday of current ISO week) – needed for both paths
        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        // ?? Choose data source: DB or Excel file ?????????????????????????????????????
        List<PredictionRecord> baseDataset;
        string? filePath = null;
        bool    usingDb  = labConfig?.DBEnabled == true;

        if (usingDb)
        {
            var rawRecords = await _dbRepo.GetRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);

            _logger.LogInformation("[{Lab}] DB source returned {Count} raw records before global filter.", selectedLab, rawRecords.Count);

            baseDataset = PredictionReportParserService.ApplyGlobalFilter(rawRecords, weekStart);

            _logger.LogInformation("[{Lab}] After global filter (ForecastPayability + ExpPmtDate < {WeekStart}): {Count} records.",
                selectedLab, weekStart, baseDataset.Count);
        }
        else
        {
            filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);

            baseDataset = filePath is not null
                ? _parser.ParseFiltered(filePath, weekStart)
                : [];

            _logger.LogInformation(
                "[{Lab}] File source returned {Count} records. WeekStart={WeekStart}",
                selectedLab, baseDataset.Count, weekStart);
        }

        // Filter-option lists (always from the full base dataset)
        var payerNames       = baseDataset.Select(r => r.PayerNameNormalized).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var payerTypes       = baseDataset.Select(r => r.PayerType).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var panelNames       = baseDataset.Select(r => r.PanelName).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var coverageStatuses = baseDataset.Select(r => r.FinalCoverageStatus).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var payabilityOpts   = baseDataset.Select(r => r.Payability).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var cptCodes         = baseDataset.Select(r => r.CPTCode).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();

        // ?? Optional dimension filters ????????????????????????????????????????
        var filtered = baseDataset.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filtered = filtered.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            filtered = filtered.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterFinalCoverageStatus))
            filtered = filtered.Where(r => r.FinalCoverageStatus.Equals(filterFinalCoverageStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayability))
            filtered = filtered.Where(r => r.Payability.Equals(filterPayability, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterCPTCode))
            filtered = filtered.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));

        // Single materialisation – every bucket and insight reuses this one list
        var dataset = filtered.ToList();

        // ?? Bucket computation ????????????????????????????????????????????????
        var byPayStatus = dataset
            .GroupBy(r => PredictionReportParserService.Normalise(r.PayStatus), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        _logger.LogInformation("[{Lab}] Distinct PayStatus values in dataset: {Values}",
            selectedLab, string.Join(", ", byPayStatus.Keys.Select(k => $"'{k}'")));

        var paidRows     = GetRows(byPayStatus, "Paid");
        var deniedRows   = GetRows(byPayStatus, "Denied");
        var noRespRows   = GetRows(byPayStatus, "No Response");
        var adjustedRows = GetRows(byPayStatus, "Adjusted");
        var unpaidRows   = deniedRows.Concat(noRespRows).Concat(adjustedRows).ToList();

        var buckets = new List<PredictionBucketRow>
        {
            // 1. Predicted To Pay – all records; no actuals/variance
            BuildBucket("Predicted To Pay",     dataset,      includeActuals: false),
            // 2. Predicted – Paid
            BuildBucket("Predicted – Paid",     paidRows,     includeActuals: true),
            // 3. Predicted – Unpaid (Denied + Adjusted + No Response combined)
            BuildBucket("Predicted – Unpaid",   unpaidRows,   includeActuals: true),
            // 4. Unpaid – Denied
            BuildBucket("Unpaid – Denied",      deniedRows,   includeActuals: true),
            // 5. Unpaid – No Response
            BuildBucket("Unpaid – No Response", noRespRows,   includeActuals: true),
            // 6. Unpaid – Adjusted
            BuildBucket("Unpaid – Adjusted",    adjustedRows, includeActuals: true),
        };

        // ?? Breakdown charts ??????????????????????????????????????????????????
        var payabilityBreakdown = dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.Payability) ? "Unknown" : r.Payability)
            .ToDictionary(g => g.Key, g => g.Count());

        var coverageBreakdown = dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.FinalCoverageStatus) ? "Unknown" : r.FinalCoverageStatus)
            .ToDictionary(g => g.Key, g => g.Count());

        var forecastingBreakdown = dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.ForecastingPayability) ? "Unknown" : r.ForecastingPayability)
            .ToDictionary(g => g.Key, g => g.Count());

        var icdBreakdown = dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.ICDComplianceStatus) ? "Unknown" : r.ICDComplianceStatus)
            .ToDictionary(g => g.Key, g => g.Count());

        var payerTypeBreakdown = dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PayerType) ? "Unknown" : r.PayerType)
            .ToDictionary(g => g.Key, g => g.Count());

        // ?? Insight tables – Prediction Validation by Payer / Panel (Claim Level) ???
        var topPayers = BuildPayerValidationRows(dataset);
        var topPanels = BuildPanelValidationRows(dataset);

        var topCpt = dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.CPTCode) ? "Unknown" : r.CPTCode)
            .Select(g => new PredictionCptRow(
                g.Key,
                g.Select(r => r.VisitNumber).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                g.Sum(r => r.BilledAmount),
                g.Sum(r => r.ModeAllowedAmountSameLab),
                g.Sum(r => r.ModeInsurancePaidSameLab)))
            .OrderByDescending(x => x.PredictedInsurance)
            .Take(15)
            .ToList();

        // ?? Expected payment by month ????????????????????????????????????????
        var paymentByMonth = dataset
            .Where(r => !string.IsNullOrWhiteSpace(r.ExpectedPaymentMonth))
            .GroupBy(r => r.ExpectedPaymentMonth)
            .Select(g => (Month: g.Key, ExpectedPayment: g.Sum(r => r.ModeInsurancePaidSameLab)))
            .OrderBy(x => x.Month)
            .ToList();

        // ?? Summary metrics (Ratios + Prediction Accuracy) ????????????????????
        var summaryMetrics = BuildSummaryMetrics(buckets);

        // ?? Predicted to Pay vs Denial Breakdown ??????????????????????????????????????
        var denialBreakdown = BuildDenialBreakdown(deniedRows);

        // ?? Predicted to Pay vs No Response Breakdown ????????????????????????????????
        var noResponseBreakdown = BuildNoResponseBreakdown(noRespRows);

        // ?? Last 4 Weeks Forecasting – Median & Mode summaries ???????????????
        var weeks = new List<WeekRange>();
        for (int w = 4; w >= 1; w--)
        {
            var wkStart = weekStart.AddDays(-7 * w);
            weeks.Add(new WeekRange(wkStart, wkStart.AddDays(6)));
        }

        var medianSummary = BuildWeeklySummary(dataset, weeks,
            r => r.MedianAllowedAmountSameLab, r => r.MedianInsurancePaidSameLab);
        var modeSummary = BuildWeeklySummary(dataset, weeks,
            r => r.ModeAllowedAmountSameLab, r => r.ModeInsurancePaidSameLab);

        // ?? Paged detail ?????????????????????????????????????????????????????
        var currentPage  = Math.Max(1, page);
        var pagedRecords = dataset.Skip((currentPage - 1) * PageSize).Take(PageSize).ToList();

        var vm = new PredictionAnalysisViewModel
        {
            AvailableLabs             = availableLabs,
            SelectedLab               = selectedLab,
            PredictionAvailable       = true,
            ResolvedFilePath          = usingDb ? $"[DB] {selectedLab}" : filePath,
            CurrentWeekStartDate      = weekStart,

            FilterPayerName           = filterPayerName,
            FilterPayerType           = filterPayerType,
            FilterPanelName           = filterPanelName,
            FilterFinalCoverageStatus = filterFinalCoverageStatus,
            FilterPayability          = filterPayability,
            FilterCPTCode             = filterCPTCode,

            PayerNames            = payerNames,
            PayerTypes            = payerTypes,
            PanelNames            = panelNames,
            FinalCoverageStatuses = coverageStatuses,
            PayabilityOptions     = payabilityOpts,
            CPTCodes              = cptCodes,

            Buckets                        = buckets,
            SummaryMetrics                 = summaryMetrics,
            MedianWeeklySummary            = medianSummary,
            ModeWeeklySummary              = modeSummary,
            PayabilityBreakdown            = payabilityBreakdown,
            FinalCoverageStatusBreakdown   = coverageBreakdown,
            ForecastingPayabilityBreakdown = forecastingBreakdown,
            ICDComplianceBreakdown         = icdBreakdown,
            PayerTypeBreakdown             = payerTypeBreakdown,

            TopPayerInsights       = topPayers,
            TopCptInsights         = topCpt,
            TopPanelInsights       = topPanels,
            ExpectedPaymentByMonth = paymentByMonth,

            Records = pagedRecords,
            Paging  = new PageInfo(currentPage, PageSize, dataset.Count, baseDataset.Count),
            DenialBreakdown     = denialBreakdown,
            NoResponseBreakdown = noResponseBreakdown,
            Insight             = _insightLoader.Load(labConfig?.InsightPath, selectedLab),
        };

        return View(vm);
    }

    // GET /Prediction/ForecastingSummary?lab=PCRLabsofAmerica&filterPayerName=...
    /// <summary>Dedicated page for last-4-weeks Median and Mode forecasting breakdown with filtered detail tab.</summary>
    public async Task<IActionResult> ForecastingSummary(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterCPTCode,
        int page = 1)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var labConfig = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg)
            ? cfg : null;

        // Check if Forecasting feature is enabled for this lab
        if (labConfig?.EnableForcast == false)
        {
            return View(new ForecastingSummaryViewModel
            {
                AvailableLabs       = availableLabs,
                SelectedLab         = selectedLab,
                PredictionAvailable = false,
                ErrorMessage        = $"Forecasting Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
            });
        }

        // If DBEnabled is false return immediately with a "not available" view model
        if (labConfig?.DBEnabled == false)
        {
            return View(new ForecastingSummaryViewModel
            {
                AvailableLabs       = availableLabs,
                SelectedLab         = selectedLab,
                PredictionAvailable = false,
            });
        }

        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        // Build 4 week ranges first – needed for both the filter and the summaries
        var weeks = new List<WeekRange>();
        for (int w = 4; w >= 1; w--)
        {
            var wkStart = weekStart.AddDays(-7 * w);
            weeks.Add(new WeekRange(wkStart, wkStart.AddDays(6)));
        }

        var rangeStart = weeks[0].Start;
        var rangeEnd   = weeks[^1].End;

        // Load records and filter to the 4-week window with ForecastingPayability check
        List<PredictionRecord> inRangeRecords;
        bool usingDb = labConfig?.DBEnabled == true;

        if (usingDb)
        {
            var rawRecords = await _dbRepo.GetRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);

            _logger.LogInformation("[{Lab}] ForecastingSummary DB raw rows: {Count}", selectedLab, rawRecords.Count);

            // Use the date-range filter – NOT ApplyGlobalFilter which strips the last-4-weeks data
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, rangeStart, rangeEnd.AddDays(1));

        _logger.LogInformation("[{Lab}] ForecastingSummary in-range rows ({Start}–{End}): {Count}",
                selectedLab, rangeStart, rangeEnd, inRangeRecords.Count);
        }
        else
        {
            var filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);

            var allParsed = filePath is not null ? _parser.Parse(filePath) : new List<PredictionRecord>();
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                allParsed, rangeStart, rangeEnd.AddDays(1));
        }

        // Detect when there is no data in the 4-week window
        bool noDataForRange = inRangeRecords.Count == 0;
        DateOnly? latestDataDate = null;

        if (noDataForRange)
        {
            // Load raw records again to find the most recent ExpectedPaymentDate
            List<PredictionRecord> allForLatest;
            if (usingDb)
            {
                allForLatest = await _dbRepo.GetRecordsAsync(
                    labConfig!.DbConnectionString ?? string.Empty,
                    cancellationToken: HttpContext.RequestAborted);
            }
            else
            {
                var fp = string.IsNullOrEmpty(selectedLab)
                    ? null
                    : _resolver.ResolvePredictionValidationReport(selectedLab);
                allForLatest = fp is not null ? _parser.Parse(fp) : [];
            }

            latestDataDate = allForLatest
                .Select(r => PredictionReportParserService.TryParseDate(r.ExpectedPaymentDate, out var d) ? d : (DateOnly?)null)
                .Where(d => d.HasValue)
                .Select(d => d!.Value)
                .DefaultIfEmpty()
                .Max() is { } max && max != default ? max : null;

            _logger.LogInformation("[{Lab}] No data in 4-week window. Latest date in data: {LatestDate}", selectedLab, latestDataDate);
        }

        // All-data summaries
        var medianSummary = BuildWeeklySummary(inRangeRecords, weeks,
            r => r.MedianAllowedAmountSameLab, r => r.MedianInsurancePaidSameLab);
        var modeSummary = BuildWeeklySummary(inRangeRecords, weeks,
            r => r.ModeAllowedAmountSameLab, r => r.ModeInsurancePaidSameLab);

        // Filter option lists (from in-range records)
        var payerNames = inRangeRecords.Select(r => r.PayerNameNormalized).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var payerTypes = inRangeRecords.Select(r => r.PayerType).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var panelNames = inRangeRecords.Select(r => r.PanelName).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
        var cptCodes   = inRangeRecords.Select(r => r.CPTCode).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();

        // Apply dimension filters for the detail tab
        bool hasActiveFilters = !string.IsNullOrWhiteSpace(filterPayerName)
                             || !string.IsNullOrWhiteSpace(filterPayerType)
                             || !string.IsNullOrWhiteSpace(filterPanelName)
                             || !string.IsNullOrWhiteSpace(filterCPTCode);

        var filteredRecords = inRangeRecords.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filteredRecords = filteredRecords.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filteredRecords = filteredRecords.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            filteredRecords = filteredRecords.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterCPTCode))
            filteredRecords = filteredRecords.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));

        var filteredList = filteredRecords.ToList();
        var currentPage  = Math.Max(1, page);
        var pagedRecords = filteredList.Skip((currentPage - 1) * PageSize).Take(PageSize).ToList();

        var vm = new ForecastingSummaryViewModel
        {
            AvailableLabs        = availableLabs,
            SelectedLab          = selectedLab,
            PredictionAvailable  = true,
            NoDataForRange       = noDataForRange,
            LatestDataDate       = latestDataDate,
            CurrentWeekStartDate = weekStart,
            TotalRecordsInRange  = inRangeRecords.Count,
            MedianSummary        = medianSummary,
            ModeSummary          = modeSummary,

            HasActiveFilters     = hasActiveFilters,
            FilteredTotalInRange = filteredList.Count,
            FilteredRecords      = pagedRecords,
            FilteredPaging       = new PageInfo(currentPage, PageSize, filteredList.Count, inRangeRecords.Count),

            FilterPayerName = filterPayerName,
            FilterPayerType = filterPayerType,
            FilterPanelName = filterPanelName,
            FilterCPTCode   = filterCPTCode,

            PayerNames = payerNames,
            PayerTypes = payerTypes,
            PanelNames = panelNames,
            CPTCodes   = cptCodes,

            ActiveTab = hasActiveFilters ? "filtered" : "median",
        };

        return View(vm);
    }

    // GET /Prediction/LineDetail?lab=...&page=1&filterPayerName=...
    /// <summary>Separate page showing paged line-item detail records.</summary>
    public async Task<IActionResult> LineDetail(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode,
        int page = 1)
    {
        var availableLabs = _labSettings.Labs
            .Where(kv => kv.Value.DBEnabled)
            .Select(kv => kv.Key)
            .OrderBy(x => x)
            .ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var labConfig = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg)
            ? cfg : null;

        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        List<PredictionRecord> baseDataset;
        string? filePath = null;
        bool    usingDb  = labConfig?.DBEnabled == true;

        if (usingDb)
        {
            var rawRecords = await _dbRepo.GetRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);

            baseDataset = PredictionReportParserService.ApplyGlobalFilter(rawRecords, weekStart);
        }
        else
        {
            filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);

            baseDataset = filePath is not null ? _parser.ParseFiltered(filePath, weekStart) : [];
        }

        var filtered = baseDataset.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filtered = filtered.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            filtered = filtered.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterFinalCoverageStatus))
            filtered = filtered.Where(r => r.FinalCoverageStatus.Equals(filterFinalCoverageStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayability))
            filtered = filtered.Where(r => r.Payability.Equals(filterPayability, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterCPTCode))
            filtered = filtered.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));

        var dataset     = filtered.ToList();
        var currentPage = Math.Max(1, page);
        var paged       = dataset.Skip((currentPage - 1) * PageSize).Take(PageSize).ToList();

        var vm = new PredictionAnalysisViewModel
        {
            AvailableLabs             = availableLabs,
            SelectedLab               = selectedLab,
            ResolvedFilePath          = usingDb ? $"[DB] {selectedLab}" : filePath,
            CurrentWeekStartDate      = weekStart,

            FilterPayerName           = filterPayerName,
            FilterPayerType           = filterPayerType,
            FilterPanelName           = filterPanelName,
            FilterFinalCoverageStatus = filterFinalCoverageStatus,
            FilterPayability          = filterPayability,
            FilterCPTCode             = filterCPTCode,

            PayerNames            = baseDataset.Select(r => r.PayerNameNormalized).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList(),
            PayerTypes            = baseDataset.Select(r => r.PayerType).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList(),
            PanelNames            = baseDataset.Select(r => r.PanelName).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList(),
            FinalCoverageStatuses = baseDataset.Select(r => r.FinalCoverageStatus).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList(),
            PayabilityOptions     = baseDataset.Select(r => r.Payability).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList(),
            CPTCodes              = baseDataset.Select(r => r.CPTCode).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList(),

            Records = paged,
            Paging  = new PageInfo(currentPage, PageSize, dataset.Count, baseDataset.Count),
        };

        return View(vm);
    }

    // GET /Prediction/Diagnostics?lab=PCRLabsofAmerica
    /// <summary>
    /// Diagnostics page – shows raw distinct field values, sample records,
    /// and filter-step counts from the source file/DB for a selected lab.
    /// </summary>
    public async Task<IActionResult> Diagnostics(string? lab)
    {
        var availableLabs = _labSettings.Labs
            .Where(kv => kv.Value.DBEnabled)
            .Select(kv => kv.Key)
            .OrderBy(x => x)
            .ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var labConfig = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg)
            ? cfg : null;

        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        List<PredictionRecord> allRecords;
        string sourcePath;
        bool usingDb = labConfig?.DBEnabled == true;

        if (usingDb)
        {
            var rawRecords = await _dbRepo.GetRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);
            allRecords = rawRecords;
            sourcePath = $"[DB] {labConfig.DbConnectionString?.Split(';').FirstOrDefault() ?? selectedLab}";
        }
        else
        {
            var filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);

            sourcePath  = filePath ?? "(not found)";
            allRecords  = filePath is not null ? _parser.Parse(filePath) : [];
        }

        // Build filter-step counts
        int afterForecast = 0, afterBoth = 0;
        if (usingDb)
        {
            afterForecast = PredictionReportParserService.ApplyGlobalFilter(allRecords, DateOnly.MaxValue).Count;
            afterBoth     = PredictionReportParserService.ApplyGlobalFilter(allRecords, weekStart).Count;
        }
        else
        {
            var filePath = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolvePredictionValidationReport(selectedLab);
            if (filePath is not null)
            {
                afterForecast = _parser.ParseFiltered(filePath, DateOnly.MaxValue).Count;
                afterBoth     = _parser.ParseFiltered(filePath, weekStart).Count;
            }
        }

        var vm = new PredictionDiagnosticsViewModel
        {
            AvailableLabs = availableLabs,
            SelectedLab   = selectedLab,
            SourceFilePath = sourcePath,
            UsingDb        = usingDb,
            TotalRows      = allRecords.Count,
            WeekStart      = weekStart.ToString("MM/dd/yyyy"),

            ForecastingPayabilityValues = allRecords
                .Select(r => r.ForecastingPayability)
                .Distinct().OrderBy(v => v)
                .Select(v => new DiagnosticDistinctValue(v, v.Length))
                .ToList(),

            PayStatusValues = allRecords
                .Select(r => r.PayStatus)
                .Distinct().OrderBy(v => v)
                .ToList(),

            ExpectedPaymentDateSamples = allRecords
                .Select(r => r.ExpectedPaymentDate)
                .Distinct().OrderBy(v => v).Take(30)
                .Select(v =>
                {
                    var parsed = PredictionReportParserService.TryParseDate(v, out var d);
                    return new DiagnosticDateSample(v, parsed, d.ToString("MM/dd/yyyy"), parsed && d < weekStart);
                })
                .ToList(),

            SampleRecords = allRecords.Take(20)
                .Select(r => new DiagnosticSampleRecord(
                    r.VisitNumber, r.CPTCode, r.PayStatus, r.ForecastingPayability,
                    r.ExpectedPaymentDate,
                    r.ModeAllowedAmountSameLab, r.ModeInsurancePaidSameLab,
                    r.MedianAllowedAmountSameLab, r.MedianInsurancePaidSameLab))
                .ToList(),

            AfterForecastFilter = afterForecast,
            AfterBothFilters    = afterBoth,
        };

        return View(vm);
    }

    /// <summary>
    /// Downloads the current Prediction Analysis filtered data as a formatted Excel file.
    /// Accepts the same filter parameters as <see cref="Index"/>.
    /// </summary>
    public async Task<IActionResult> ExportPredictionExcel(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        var labConfig     = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg) ? cfg : null;

        if (labConfig?.DBEnabled == false)
        {
            TempData["ExportError"] = "Export is not available for the selected lab.";
            return RedirectToAction(nameof(Index), new { lab });
        }

        try
        {
            // Reuse the same data-load + filter logic as Index
            var vm = await BuildPredictionViewModelAsync(selectedLab, labConfig,
                filterPayerName, filterPayerType, filterPanelName,
                filterFinalCoverageStatus, filterPayability, filterCPTCode);

            using var workbook = PredictionExcelExportBuilder.CreateWorkbook(vm, selectedLab,
                activeFilters: new List<(string, string?)>
                {
                    ("Payer Name", filterPayerName),
                    ("Payer Type", filterPayerType),
                    ("Panel Name", filterPanelName),
                    ("Final Coverage Status", filterFinalCoverageStatus),
                    ("Payability", filterPayability),
                    ("CPT Code", filterCPTCode),
                });

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_PredictionAnalysis_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            return File(
                stream.ToArray(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Prediction Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(Index), new { lab });
        }
    }

    /// <summary>
    /// Downloads the current Forecasting Summary data as a formatted Excel file.
    /// Accepts the same filter parameters as <see cref="ForecastingSummary"/>.
    /// </summary>
    public async Task<IActionResult> ExportForecastingExcel(string? lab)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        var labConfig     = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg) ? cfg : null;

        if (labConfig?.DBEnabled == false)
        {
            TempData["ExportError"] = "Export is not available for the selected lab.";
            return RedirectToAction(nameof(ForecastingSummary), new { lab });
        }

        try
        {
            var vm = await BuildForecastingViewModelAsync(selectedLab, labConfig);

            using var workbook = ForecastingExcelExportBuilder.CreateWorkbook(vm, selectedLab);

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_ForecastingSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            return File(
                stream.ToArray(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Forecasting Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(ForecastingSummary), new { lab });
        }
    }

    // ?? Private helpers ?????????????????????????????????????????????????

    /// <summary>Builds the Prediction Analysis view model (shared by Index and ExportPredictionExcel).</summary>
    private async Task<PredictionAnalysisViewModel> BuildPredictionViewModelAsync(
        string selectedLab, LabCsvConfig? labConfig,
        string? filterPayerName, string? filterPayerType, string? filterPanelName,
        string? filterFinalCoverageStatus, string? filterPayability, string? filterCPTCode)
    {
        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        List<PredictionRecord> baseDataset;
        string? filePath = null;
        bool usingDb = labConfig?.DBEnabled == true;

        if (usingDb)
        {
            var rawRecords = await _dbRepo.GetRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);
            baseDataset = PredictionReportParserService.ApplyGlobalFilter(rawRecords, weekStart);
        }
        else
        {
            filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);
            baseDataset = filePath is not null
                ? _parser.ParseFiltered(filePath, weekStart)
                : [];
        }

        var filtered = baseDataset.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filtered = filtered.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            filtered = filtered.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterFinalCoverageStatus))
            filtered = filtered.Where(r => r.FinalCoverageStatus.Equals(filterFinalCoverageStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayability))
            filtered = filtered.Where(r => r.Payability.Equals(filterPayability, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterCPTCode))
            filtered = filtered.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));

        var dataset = filtered.ToList();

        var byPayStatus = dataset
            .GroupBy(r => PredictionReportParserService.Normalise(r.PayStatus), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var paidRows     = GetRows(byPayStatus, "Paid");
        var deniedRows   = GetRows(byPayStatus, "Denied");
        var noRespRows   = GetRows(byPayStatus, "No Response");
        var adjustedRows = GetRows(byPayStatus, "Adjusted");
        var unpaidRows   = deniedRows.Concat(noRespRows).Concat(adjustedRows).ToList();

        var buckets = new List<PredictionBucketRow>
        {
            BuildBucket("Predicted To Pay",     dataset,      includeActuals: false),
            BuildBucket("Predicted \u2013 Paid",     paidRows,     includeActuals: true),
            BuildBucket("Predicted \u2013 Unpaid",   unpaidRows,   includeActuals: true),
            BuildBucket("Unpaid \u2013 Denied",      deniedRows,   includeActuals: true),
            BuildBucket("Unpaid \u2013 No Response", noRespRows,   includeActuals: true),
            BuildBucket("Unpaid \u2013 Adjusted",    adjustedRows, includeActuals: true),
        };

        var weeks = new List<WeekRange>();
        for (int w = 4; w >= 1; w--)
        {
            var wkStart = weekStart.AddDays(-7 * w);
            weeks.Add(new WeekRange(wkStart, wkStart.AddDays(6)));
        }

        return new PredictionAnalysisViewModel
        {
            SelectedLab          = selectedLab,
            PredictionAvailable  = true,
            ResolvedFilePath     = usingDb ? $"[DB] {selectedLab}" : filePath,
            CurrentWeekStartDate = weekStart,
            Buckets              = buckets,
            SummaryMetrics       = BuildSummaryMetrics(buckets),
            TopPayerInsights     = BuildPayerValidationRows(dataset),
            TopPanelInsights     = BuildPanelValidationRows(dataset),
            TopCptInsights = dataset
                .GroupBy(r => string.IsNullOrWhiteSpace(r.CPTCode) ? "Unknown" : r.CPTCode)
                .Select(g => new PredictionCptRow(
                    g.Key,
                    g.Select(r => r.VisitNumber).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                    g.Sum(r => r.BilledAmount),
                    g.Sum(r => r.ModeAllowedAmountSameLab),
                    g.Sum(r => r.ModeInsurancePaidSameLab)))
                .OrderByDescending(x => x.PredictedInsurance)
                .Take(15)
                .ToList(),
            PayabilityBreakdown = dataset
                .GroupBy(r => string.IsNullOrWhiteSpace(r.Payability) ? "Unknown" : r.Payability)
                .ToDictionary(g => g.Key, g => g.Count()),
            FinalCoverageStatusBreakdown = dataset
                .GroupBy(r => string.IsNullOrWhiteSpace(r.FinalCoverageStatus) ? "Unknown" : r.FinalCoverageStatus)
                .ToDictionary(g => g.Key, g => g.Count()),
            ForecastingPayabilityBreakdown = dataset
                .GroupBy(r => string.IsNullOrWhiteSpace(r.ForecastingPayability) ? "Unknown" : r.ForecastingPayability)
                .ToDictionary(g => g.Key, g => g.Count()),
            ICDComplianceBreakdown = dataset
                .GroupBy(r => string.IsNullOrWhiteSpace(r.ICDComplianceStatus) ? "Unknown" : r.ICDComplianceStatus)
                .ToDictionary(g => g.Key, g => g.Count()),
            PayerTypeBreakdown = dataset
                .GroupBy(r => string.IsNullOrWhiteSpace(r.PayerType) ? "Unknown" : r.PayerType)
                .ToDictionary(g => g.Key, g => g.Count()),
            DenialBreakdown     = BuildDenialBreakdown(deniedRows),
            NoResponseBreakdown = BuildNoResponseBreakdown(noRespRows),
            MedianWeeklySummary = BuildWeeklySummary(dataset, weeks,
                r => r.MedianAllowedAmountSameLab, r => r.MedianInsurancePaidSameLab),
            ModeWeeklySummary = BuildWeeklySummary(dataset, weeks,
                r => r.ModeAllowedAmountSameLab, r => r.ModeInsurancePaidSameLab),
        };
    }

    /// <summary>Builds the Forecasting Summary view model (shared by ForecastingSummary and ExportForecastingExcel).</summary>
    private async Task<ForecastingSummaryViewModel> BuildForecastingViewModelAsync(
        string selectedLab, LabCsvConfig? labConfig)
    {
        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        var weeks = new List<WeekRange>();
        for (int w = 4; w >= 1; w--)
        {
            var wkStart = weekStart.AddDays(-7 * w);
            weeks.Add(new WeekRange(wkStart, wkStart.AddDays(6)));
        }

        var rangeStart = weeks[0].Start;
        var rangeEnd   = weeks[^1].End;

        List<PredictionRecord> inRangeRecords;
        bool usingDb = labConfig?.DBEnabled == true;

        if (usingDb)
        {
            var rawRecords = await _dbRepo.GetRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, rangeStart, rangeEnd.AddDays(1));
        }
        else
        {
            var filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);
            var allParsed = filePath is not null ? _parser.Parse(filePath) : new List<PredictionRecord>();
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                allParsed, rangeStart, rangeEnd.AddDays(1));
        }

        return new ForecastingSummaryViewModel
        {
            SelectedLab          = selectedLab,
            PredictionAvailable  = true,
            CurrentWeekStartDate = weekStart,
            TotalRecordsInRange  = inRangeRecords.Count,
            MedianSummary = BuildWeeklySummary(inRangeRecords, weeks,
                r => r.MedianAllowedAmountSameLab, r => r.MedianInsurancePaidSameLab),
            ModeSummary = BuildWeeklySummary(inRangeRecords, weeks,
                r => r.ModeAllowedAmountSameLab, r => r.ModeInsurancePaidSameLab),
        };
    }

    // ?? Static helpers ??????????????????????????????????????????????????

    private static List<PredictionRecord> GetRows(
        Dictionary<string, List<PredictionRecord>> byPayStatus, string key) =>
        byPayStatus.TryGetValue(key, out var rows) ? rows : [];

    private static PredictionBucketRow BuildBucket(
        string name,
        IReadOnlyList<PredictionRecord> rows,
        bool includeActuals)
    {
        var claimCount = rows
            .Select(r => r.VisitNumber)
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();

        var predictedAllowed = rows.Sum(r => r.ModeAllowedAmountSameLab);
        var predictedIns     = rows.Sum(r => r.ModeInsurancePaidSameLab);

        if (!includeActuals)
            return new PredictionBucketRow(name, claimCount, predictedAllowed, predictedIns,
                                           null, null, null);

        var actualAllowed = rows.Sum(r => r.AllowedAmount);
        var actualIns     = rows.Sum(r => r.InsurancePayment);
        var variance      = predictedAllowed - actualAllowed;

        return new PredictionBucketRow(name, claimCount, predictedAllowed, predictedIns,
                                       actualAllowed, actualIns, variance);
    }

    private static PredictionSummaryMetrics BuildSummaryMetrics(IReadOnlyList<PredictionBucketRow> buckets)
    {
        var toPay   = buckets.FirstOrDefault(b => b.BucketName == "Predicted To Pay");
        var paid    = buckets.FirstOrDefault(b => b.BucketName == "Predicted \u2013 Paid");
        var unpaid  = buckets.FirstOrDefault(b => b.BucketName == "Predicted \u2013 Unpaid");
        var denied  = buckets.FirstOrDefault(b => b.BucketName == "Unpaid \u2013 Denied");
        var noResp  = buckets.FirstOrDefault(b => b.BucketName == "Unpaid \u2013 No Response");
        var adj     = buckets.FirstOrDefault(b => b.BucketName == "Unpaid \u2013 Adjusted");

        static decimal? Pct(decimal? num, decimal? denom) =>
            denom is > 0 && num.HasValue ? Math.Round(num.Value / denom.Value * 100, 2) : null;

        return new PredictionSummaryMetrics
        {
            // Payment Ratio
            PaymentRatioClaim     = Pct(paid?.ClaimCount,     toPay?.ClaimCount),
            PaymentRatioAllowed   = Pct(paid?.PredictedAllowed,   toPay?.PredictedAllowed),
            PaymentRatioInsurance = Pct(paid?.PredictedInsurance, toPay?.PredictedInsurance),

            // Non-Payment Rate
            NonPaymentRateClaim     = Pct(unpaid?.ClaimCount,     toPay?.ClaimCount),
            NonPaymentRateAllowed   = Pct(unpaid?.PredictedAllowed,   toPay?.PredictedAllowed),
            NonPaymentRateInsurance = Pct(unpaid?.PredictedInsurance, toPay?.PredictedInsurance),

            // Denied %
            DeniedPctClaim      = Pct(denied?.ClaimCount,     unpaid?.ClaimCount),
            DeniedPctAllowed    = Pct(denied?.PredictedAllowed,   unpaid?.PredictedAllowed),
            DeniedPctInsurance  = Pct(denied?.PredictedInsurance, unpaid?.PredictedInsurance),

            // No Response %
            NoResponsePctClaim      = Pct(noResp?.ClaimCount,     unpaid?.ClaimCount),
            NoResponsePctAllowed    = Pct(noResp?.PredictedAllowed,   unpaid?.PredictedAllowed),
            NoResponsePctInsurance  = Pct(noResp?.PredictedInsurance, unpaid?.PredictedInsurance),

            // Adjusted %
            AdjustedPctClaim      = Pct(adj?.ClaimCount,     unpaid?.ClaimCount),
            AdjustedPctAllowed    = Pct(adj?.PredictedAllowed,   unpaid?.PredictedAllowed),
            AdjustedPctInsurance  = Pct(adj?.PredictedInsurance, unpaid?.PredictedInsurance),

            // Prediction Accuracy – Predicted Paid Claim / Total Predicted To Pay * 100
            PredVsActualRatioClaim    = Pct(paid?.ClaimCount, toPay?.ClaimCount),
            PredVsActualAllowedAmount = paid?.ActualAllowed.HasValue == true && paid.PredictedAllowed != 0
                ? Math.Round(paid.ActualAllowed!.Value / paid.PredictedAllowed * 100, 2) : null,
            PredVsActualInsPayment    = paid?.ActualInsurance.HasValue == true && paid.PredictedInsurance != 0
                ? Math.Round(paid.ActualInsurance!.Value / paid.PredictedInsurance * 100, 2) : null,
        };
    }

    /// <summary>
    /// Builds a weekly forecast summary (Median or Mode) by assigning each record
    /// to a week bin based on its ExpectedPaymentDate and grouping by payer.
    /// </summary>
    private static WeeklyForecastSummary BuildWeeklySummary(
        IReadOnlyList<PredictionRecord> records,
        IReadOnlyList<WeekRange> weeks,
        Func<PredictionRecord, decimal> allowedSelector,
        Func<PredictionRecord, decimal> paidSelector)
    {
        // Assign each record to its week bin (Mon–Sun)
        var recordsWithWeek = new List<(PredictionRecord Rec, DateOnly WeekStart)>();
        foreach (var r in records)
        {
            if (!PredictionReportParserService.TryParseDate(r.ExpectedPaymentDate, out var pmtDate))
                continue;

            foreach (var wk in weeks)
            {
                if (pmtDate >= wk.Start && pmtDate <= wk.End)
                {
                    recordsWithWeek.Add((r, wk.Start));
                    break;
                }
            }
        }

        // Group by payer ? week
        var byPayer = recordsWithWeek
            .GroupBy(x => string.IsNullOrWhiteSpace(x.Rec.PayerNameNormalized)
                ? x.Rec.PayerName : x.Rec.PayerNameNormalized,
                StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => g.Key)
            .ToList();

        var payerRows = new List<WeeklyPayerRow>();
        var totalWeekAmounts = weeks.ToDictionary(w => w.Start, _ => (Allowed: 0m, Paid: 0m));

        foreach (var payerGroup in byPayer)
        {
            var weekAmounts = new Dictionary<DateOnly, WeeklyAmounts>();
            decimal payerTotalAllowed = 0m, payerTotalPaid = 0m;

            foreach (var wk in weeks)
            {
                var weekRecords = payerGroup.Where(x => x.WeekStart == wk.Start).ToList();
                var allowed = weekRecords.Sum(x => allowedSelector(x.Rec));
                var paid    = weekRecords.Sum(x => paidSelector(x.Rec));

                weekAmounts[wk.Start] = new WeeklyAmounts(allowed, paid);
                payerTotalAllowed += allowed;
                payerTotalPaid    += paid;

                var t = totalWeekAmounts[wk.Start];
                totalWeekAmounts[wk.Start] = (t.Allowed + allowed, t.Paid + paid);
            }

            payerRows.Add(new WeeklyPayerRow(payerGroup.Key)
            {
                WeekAmounts  = weekAmounts,
                TotalAllowed = payerTotalAllowed,
                TotalPaid    = payerTotalPaid,
            });
        }

        var totalsRow = new WeeklyPayerRow("Total")
        {
            WeekAmounts  = totalWeekAmounts.ToDictionary(kv => kv.Key, kv => new WeeklyAmounts(kv.Value.Allowed, kv.Value.Paid)),
            TotalAllowed = totalWeekAmounts.Values.Sum(v => v.Allowed),
            TotalPaid    = totalWeekAmounts.Values.Sum(v => v.Paid),
        };

        return new WeeklyForecastSummary
        {
            Weeks     = weeks,
            PayerRows = payerRows,
            Totals    = totalsRow,
        };
    }

    /// <summary>
    /// Builds the Predicted to Pay vs Denial Breakdown table from denied records.
    /// Filter: ForecastingPayability IN (Payable/Potentially Payable/Payable-Need Action)
    ///         AND PayStatus = Denied (already pre-filtered in deniedRows)
    ///         AND ExpectedPaymentDate &lt; weekStart (already pre-filtered in baseDataset).
    /// Rows: Top payers by total claim count, each with top-5 denial codes.
    /// Columns: Dynamic months (ExpectedPaymentMonth) + Total.
    /// </summary>
    private static DenialBreakdown BuildDenialBreakdown(List<PredictionRecord> deniedRows)
    {
        if (deniedRows.Count == 0)
            return new DenialBreakdown();

        // Distinct ordered months from the denied dataset
        var months = deniedRows
            .Where(r => !string.IsNullOrWhiteSpace(r.ExpectedPaymentMonth))
            .Select(r => r.ExpectedPaymentMonth)
            .Distinct()
            .OrderBy(m => m)
            .ToList();

        DenialMonthAmount Aggregate(IEnumerable<PredictionRecord> rows)
        {
            var list = rows.ToList();
            return new DenialMonthAmount(
                list.Select(r => r.VisitNumber).Where(v => !string.IsNullOrWhiteSpace(v))
                    .Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                list.Sum(r => r.ModeAllowedAmountSameLab),
                list.Sum(r => r.ModeInsurancePaidSameLab));
        }

        IReadOnlyDictionary<string, DenialMonthAmount> ByMonth(IEnumerable<PredictionRecord> rows)
        {
            var list = rows.ToList();
            return months.ToDictionary(
                m => m,
                m => Aggregate(list.Where(r => r.ExpectedPaymentMonth == m)));
        }

        // Group by payer – sort by total claim count desc
        var payerGroups = deniedRows
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PayerNameNormalized) ? r.PayerName : r.PayerNameNormalized,
                     StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var pgList = pg.ToList();
                var totalClaims = pgList
                    .Select(r => r.VisitNumber).Where(v => !string.IsNullOrWhiteSpace(v))
                    .Distinct(StringComparer.OrdinalIgnoreCase).Count();

                // Top-5 denial codes for this payer by claim count
                var topDenials = pgList
                    .GroupBy(r => new
                    {
                        Code = string.IsNullOrWhiteSpace(r.DenialCode) ? "(No Code)" : r.DenialCode,
                        Desc = string.IsNullOrWhiteSpace(r.DenialDescription) ? string.Empty : r.DenialDescription
                    })
                    .Select(dg =>
                    {
                        var dgList = dg.ToList();
                        var dgClaims = dgList
                            .Select(r => r.VisitNumber).Where(v => !string.IsNullOrWhiteSpace(v))
                            .Distinct(StringComparer.OrdinalIgnoreCase).Count();
                        return new DenialCodeRow(
                            dg.Key.Code,
                            dg.Key.Desc,
                            dgClaims,
                            dgList.Sum(r => r.ModeAllowedAmountSameLab),
                            dgList.Sum(r => r.ModeInsurancePaidSameLab),
                            ByMonth(dgList));
                    })
                    .OrderByDescending(d => d.TotalClaims)
                    .Take(5)
                    .ToList();

                return new DenialPayerRow(
                    pg.Key,
                    totalClaims,
                    pgList.Sum(r => r.ModeAllowedAmountSameLab),
                    pgList.Sum(r => r.ModeInsurancePaidSameLab),
                    ByMonth(pgList),
                    topDenials);
            })
            .OrderByDescending(p => p.TotalClaims)
            .ToList();

        // Grand total footer
        var grandByMonth = months.ToDictionary(
            m => m,
            m => Aggregate(deniedRows.Where(r => r.ExpectedPaymentMonth == m)));

        return new DenialBreakdown
        {
            Months    = months,
            PayerRows = payerGroups,
            TotalClaims             = deniedRows.Select(r => r.VisitNumber).Where(v => !string.IsNullOrWhiteSpace(v))
                                                .Distinct(StringComparer.OrdinalIgnoreCase).Count(),
            TotalPredictedAllowed   = deniedRows.Sum(r => r.ModeAllowedAmountSameLab),
            TotalPredictedInsurance = deniedRows.Sum(r => r.ModeInsurancePaidSameLab),
            TotalByMonth            = grandByMonth,
        };
    }

    /// <summary>
    /// Builds the Predicted to Pay vs No Response Breakdown table.
    /// Input: noRespRows – already filtered by ForecastingPayability + PayStatus=NoResponse + ExpDate&lt;weekStart.
    /// Columns: Age buckets (0–30, 31–60, 61–90, 91–120, &gt;120) derived from FirstBilledDate.
    /// Priority Level: age bucket with the highest claim count per payer.
    /// </summary>
    private static NoResponseBreakdown BuildNoResponseBreakdown(List<PredictionRecord> noRespRows)
    {
        if (noRespRows.Count == 0)
            return new NoResponseBreakdown();

        var today = DateOnly.FromDateTime(DateTime.Today);

        // Classify each record into an age bucket using FirstBilledDate
        var classified = noRespRows
            .Select(r =>
            {
                var ageDays = PredictionReportParserService.TryParseDate(r.FirstBilledDate, out var billed)
                    ? today.DayNumber - billed.DayNumber
                    : -1;
                var bucket  = ageDays >= 0 ? AgeBuckets.Classify(ageDays) : AgeBuckets.B0_30;
                return (Record: r, Bucket: bucket);
            })
            .ToList();

        AgeBucketAmount AggregateBucket(IEnumerable<(PredictionRecord Record, string Bucket)> items)
        {
            var list = items.ToList();
            return new AgeBucketAmount(
                list.Select(x => x.Record.VisitNumber)
                    .Where(v => !string.IsNullOrWhiteSpace(v))
                    .Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                list.Sum(x => x.Record.ModeAllowedAmountSameLab),
                list.Sum(x => x.Record.ModeInsurancePaidSameLab));
        }

        IReadOnlyDictionary<string, AgeBucketAmount> ByBucket(
            IEnumerable<(PredictionRecord Record, string Bucket)> items)
        {
            var list = items.ToList();
            return AgeBuckets.All.ToDictionary(
                b => b,
                b => AggregateBucket(list.Where(x => x.Bucket == b)));
        }

        // Group by payer – sort by total claim count desc
        var payerRows = classified
            .GroupBy(
                x => string.IsNullOrWhiteSpace(x.Record.PayerNameNormalized)
                    ? x.Record.PayerName
                    : x.Record.PayerNameNormalized,
                StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var pgItems     = pg.ToList();
                var byBucket    = ByBucket(pgItems);
                var totalClaims = pgItems
                    .Select(x => x.Record.VisitNumber)
                    .Where(v => !string.IsNullOrWhiteSpace(v))
                    .Distinct(StringComparer.OrdinalIgnoreCase).Count();

                // Priority bucket = bucket with highest claim count
                var priorityBucket = AgeBuckets.All
                    .OrderByDescending(b => byBucket[b].ClaimCount)
                    .First();

                return new NoResponsePayerRow(
                    pg.Key,
                    totalClaims,
                    pgItems.Sum(x => x.Record.ModeAllowedAmountSameLab),
                    pgItems.Sum(x => x.Record.ModeInsurancePaidSameLab),
                    byBucket,
                    priorityBucket);
            })
            .OrderByDescending(p => p.TotalClaims)
            .ToList();

        // Grand total footer
        var totalByBucket = ByBucket(classified);

        return new NoResponseBreakdown
        {
            PayerRows               = payerRows,
            TotalClaims             = classified
                .Select(x => x.Record.VisitNumber)
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Distinct(StringComparer.OrdinalIgnoreCase).Count(),
            TotalPredictedAllowed   = noRespRows.Sum(r => r.ModeAllowedAmountSameLab),
            TotalPredictedInsurance = noRespRows.Sum(r => r.ModeInsurancePaidSameLab),
            TotalByBucket           = totalByBucket,
        };
    }

    /// <summary>Builds Prediction Validation by Payer rows sorted by Total Claims descending.</summary>
    private static List<PredictionPayerRow> BuildPayerValidationRows(List<PredictionRecord> dataset)
    {
        static int DistinctClaims(IEnumerable<PredictionRecord> rows) =>
            rows.Select(r => r.VisitNumber)
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Distinct(StringComparer.OrdinalIgnoreCase).Count();

        return dataset
            .GroupBy(r => new
            {
                Payer = string.IsNullOrWhiteSpace(r.PayerNameNormalized) ? r.PayerName : r.PayerNameNormalized,
                r.PayerType
            })
            .Select(g =>
            {
                var rows       = g.ToList();
                var norm       = PredictionReportParserService.Normalise;
                var paid       = rows.Where(r => norm(r.PayStatus).Equals("Paid",        StringComparison.OrdinalIgnoreCase)).ToList();
                var denied     = rows.Where(r => norm(r.PayStatus).Equals("Denied",      StringComparison.OrdinalIgnoreCase)).ToList();
                var noResp     = rows.Where(r => norm(r.PayStatus).Equals("No Response", StringComparison.OrdinalIgnoreCase)).ToList();
                var adjusted   = rows.Where(r => norm(r.PayStatus).Equals("Adjusted",    StringComparison.OrdinalIgnoreCase)).ToList();
                var unpaid     = denied.Concat(noResp).Concat(adjusted).ToList();

                int paidCnt    = DistinctClaims(paid);
                int deniedCnt  = DistinctClaims(denied);
                int noRespCnt  = DistinctClaims(noResp);
                int adjCnt     = DistinctClaims(adjusted);
                int unpaidCnt  = DistinctClaims(unpaid);
                int total      = DistinctClaims(rows);

                decimal predAllowed   = rows.Sum(r => r.ModeAllowedAmountSameLab);
                decimal predIns       = rows.Sum(r => r.ModeInsurancePaidSameLab);
                decimal actAllowed    = rows.Sum(r => r.AllowedAmount);
                decimal actIns        = rows.Sum(r => r.InsurancePayment);
                decimal? payRate      = total > 0 ? Math.Round((decimal)paidCnt / total * 100, 1) : null;

                return new PredictionPayerRow(
                    g.Key.Payer, g.Key.PayerType,
                    total, paidCnt, deniedCnt, noRespCnt, adjCnt, unpaidCnt,
                    payRate, predAllowed, predIns, actAllowed, actIns,
                    actAllowed - predAllowed);
            })
            .OrderByDescending(r => r.TotalClaims)
            .ToList();
    }

    /// <summary>Builds Prediction Validation by Panel rows sorted by Total Claims descending.</summary>
    private static List<PredictionPanelRow> BuildPanelValidationRows(List<PredictionRecord> dataset)
    {
        static int DistinctClaims(IEnumerable<PredictionRecord> rows) =>
            rows.Select(r => r.VisitNumber)
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Distinct(StringComparer.OrdinalIgnoreCase).Count();

        return dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PanelName) ? "Unknown" : r.PanelName)
            .Select(g =>
            {
                var rows       = g.ToList();
                var norm       = PredictionReportParserService.Normalise;
                var paid       = rows.Where(r => norm(r.PayStatus).Equals("Paid",        StringComparison.OrdinalIgnoreCase)).ToList();
                var denied     = rows.Where(r => norm(r.PayStatus).Equals("Denied",      StringComparison.OrdinalIgnoreCase)).ToList();
                var noResp     = rows.Where(r => norm(r.PayStatus).Equals("No Response", StringComparison.OrdinalIgnoreCase)).ToList();
                var adjusted   = rows.Where(r => norm(r.PayStatus).Equals("Adjusted",    StringComparison.OrdinalIgnoreCase)).ToList();
                var unpaid     = denied.Concat(noResp).Concat(adjusted).ToList();

                int paidCnt    = DistinctClaims(paid);
                int deniedCnt  = DistinctClaims(denied);
                int noRespCnt  = DistinctClaims(noResp);
                int adjCnt     = DistinctClaims(adjusted);
                int unpaidCnt  = DistinctClaims(unpaid);
                int total      = DistinctClaims(rows);

                decimal predAllowed   = rows.Sum(r => r.ModeAllowedAmountSameLab);
                decimal predIns       = rows.Sum(r => r.ModeInsurancePaidSameLab);
                decimal actAllowed    = rows.Sum(r => r.AllowedAmount);
                decimal actIns        = rows.Sum(r => r.InsurancePayment);
                decimal? payRate      = total > 0 ? Math.Round((decimal)paidCnt / total * 100, 1) : null;

                return new PredictionPanelRow(
                    g.Key,
                    total, paidCnt, deniedCnt, noRespCnt, adjCnt, unpaidCnt,
                    payRate, predAllowed, predIns, actAllowed, actIns,
                    actAllowed - predAllowed);
            })
            .OrderByDescending(r => r.TotalClaims)
            .ToList();
    }
}
