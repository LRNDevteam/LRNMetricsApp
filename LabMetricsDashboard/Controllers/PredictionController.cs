using System.Globalization;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Http.Timeouts;
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
    private readonly DenialDescriptionMasterLookup _denialDescLookup;
    private readonly ILogger<PredictionController> _logger;

    public PredictionController(
        LabSettings labSettings,
        LabCsvFileResolver resolver,
        PredictionReportParserService parser,
        IPredictionDbRepository dbRepo,
        PredictionInsightLoader insightLoader,
        DenialDescriptionMasterLookup denialDescLookup,
        ILogger<PredictionController> logger)
    {
        _labSettings      = labSettings;
        _resolver         = resolver;
        _parser           = parser;
        _dbRepo           = dbRepo;
        _insightLoader    = insightLoader;
        _denialDescLookup = denialDescLookup;
        _logger           = logger;
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
        string? filterForecastingPayability,
        string? filterPayStatus,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus,
        int page = 1)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var labConfig = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg)
            ? cfg : null;

        // Prediction page availability is controlled only by EnablePrediction.
        if (labConfig?.EnablePrediction != true)
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

        // Week-start (Monday) — used for trend charts and display only, not for data filtering
        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        // ?? Choose data source: DB or Excel file ?????????????????????????????????????
        List<PredictionRecord> baseDataset;
        string? filePath = null;
        bool    usingDb  = labConfig?.DBEnabled == true;
        PredictionDbDiagnostic? dbProbe = null;

        if (usingDb)
        {
            try
            {
                dbProbe = await _dbRepo.ProbeAsync(
                    labConfig!.DbConnectionString ?? string.Empty,
                    HttpContext.RequestAborted);

                if (!dbProbe.IsReady)
                {
                    _logger.LogWarning(
                        "[{Lab}] Prediction DB probe: TableExists={T}, ProcExists={P}, Rows={N}, LatestRunId={R}, LastRun={D}, Error={E}",
                        selectedLab, dbProbe.TableExists, dbProbe.ProcedureExists, dbProbe.RowCount,
                        dbProbe.LatestRunId, dbProbe.LatestRunInsertedAt, dbProbe.ErrorMessage);
                    return View(new PredictionAnalysisViewModel
                    {
                        AvailableLabs        = availableLabs,
                        SelectedLab          = selectedLab,
                        PredictionAvailable  = false,
                        ErrorMessage         = $"Prediction Analysis is not yet available for {selectedLab}. {dbProbe.ErrorMessage}",
                        CurrentWeekStartDate = weekStart,
                    });
                }

                baseDataset = [];
                _logger.LogInformation(
                    "[{Lab}] DB index: skipping full line load ({RowCount} rows in source table); aggregates from PV_* snapshots / SPs.",
                    selectedLab, dbProbe.RowCount);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[{Lab}] Prediction DB probe failed.", selectedLab);
                PredictionDbDiagnostic diag;
                try
                {
                    diag = await _dbRepo.ProbeAsync(
                        labConfig!.DbConnectionString ?? string.Empty, HttpContext.RequestAborted);
                }
                catch
                {
                    diag = new PredictionDbDiagnostic(false, false, 0, null, null, ex.Message);
                }

                return View(new PredictionAnalysisViewModel
                {
                    AvailableLabs        = availableLabs,
                    SelectedLab          = selectedLab,
                    PredictionAvailable  = false,
                    ErrorMessage         = $"Failed to load Prediction Analysis for {selectedLab}: {diag.ErrorMessage ?? ex.Message}",
                    CurrentWeekStartDate = weekStart,
                });
            }
        }
        else
        {
            filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);

            baseDataset = filePath is not null
                ? _parser.ParseFiltered(filePath)
                : [];

            _logger.LogInformation(
                "[{Lab}] File source returned {Count} records.",
                selectedLab, baseDataset.Count);
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
        if (!string.IsNullOrWhiteSpace(filterForecastingPayability))
            filtered = filtered.Where(r => r.ForecastingPayability.Equals(filterForecastingPayability, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayStatus))
            filtered = filtered.Where(r => (string.IsNullOrWhiteSpace(r.PayStatus) ? "(Blank)" : r.PayStatus).Equals(filterPayStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterForecastingPayabilitySubstatus))
            filtered = filtered.Where(r => r.ForecastingPayabilitySubstatus.Equals(filterForecastingPayabilitySubstatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPredictionStatus))
            filtered = filtered.Where(r => r.PredictionStatus.Equals(filterPredictionStatus, StringComparison.OrdinalIgnoreCase));

        // Single materialisation
        var dataset = filtered.ToList();

        // ── DB path: all displayed aggregates come from SPs ────────────────────
        // ── File path: keep original in-memory computation ─────────────────────
        List<PredictionBucketRow>          buckets;
        List<PredictionPayerRow>           topPayers;
        List<PredictionPanelRow>           topPanels;
        List<PredictionCptRow>             topCpt;
        List<PredictionPayerPayStatusRow>    payerPayStatusRows;
        List<PredictionAdjustedPayerRow>   adjustedByPayer;
        DenialBreakdown                    denialBreakdown;
        NoResponseBreakdown                noResponseBreakdown;
        PredictionSummaryMetricsSpRow?     spMetrics = null;
        List<string> forecastingPayabilities;
        List<string> payStatuses;
        List<string> substatuses;
        List<string> predStatuses;

        if (usingDb)
        {
            var connStr = labConfig!.DbConnectionString ?? string.Empty;
            var ct      = HttpContext.RequestAborted;

            var filterOptsTask   = _dbRepo.GetFilterOptionsAsync(connStr, cancellationToken: ct);
            var bucketTask       = _dbRepo.GetSummaryBucketsAsync      (connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var metricsTask      = _dbRepo.GetSummaryMetricsAsync      (connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var payerTask        = _dbRepo.GetValidationByPayerAsync    (connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var payStatusTask    = _dbRepo.GetPayerPayStatusBreakdownAsync(connStr, weekStart, filterPayerName: filterPayerName, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var adjustedTask     = _dbRepo.GetAdjustedByPayerAsync     (connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var denialTask       = _dbRepo.GetDenialBreakdownAsync      (connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var noRespTask       = _dbRepo.GetNoResponseBreakdownAsync  (connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);

            await Task.WhenAll(filterOptsTask, bucketTask, metricsTask, payerTask, payStatusTask, adjustedTask, denialTask, noRespTask);

            var filterOpts = filterOptsTask.Result;
            buckets = MapSpBuckets(bucketTask.Result);

            topPayers = payerTask.Result
                .Select(r => new PredictionPayerRow(
                    r.PayerName, r.PayerType,
                    r.TotalLineItems, r.PaidCount, r.DeniedCount, r.NoResponseCount, r.AdjustedCount, r.UnpaidCount,
                    r.TotalLineItems > 0 ? Math.Round((decimal)r.PaidCount / r.TotalLineItems * 100, 1) : null,
                    r.PredictedAllowed, r.PredictedInsurance, r.ActualAllowed, r.ActualInsurance,
                    r.VarianceAllowed, r.VariancePaid))
                .OrderByDescending(r => r.VarianceAllowed)
                .ToList();

            topPanels = [];
            topCpt    = [];

            payerPayStatusRows = payStatusTask.Result
                .Select(r => new PredictionPayerPayStatusRow(
                    r.PayerName, r.PayStatus, r.LineItemCount,
                    r.PredictedAllowed, r.PredictedInsurance, r.ActualAllowed, r.ActualInsurance,
                    r.VarianceAllowed, r.VariancePaid))
                .ToList();

            adjustedByPayer = adjustedTask.Result
                .Select(r => new PredictionAdjustedPayerRow(
                    r.PayerName, r.LineItemCount,
                    r.PredictedAllowed, r.PredictedInsurance, r.ActualAllowed, r.ActualInsurance,
                    r.VarianceAllowed, r.VariancePaid))
                .ToList();

            var denialRows = await _denialDescLookup.EnrichAsync(
                connStr,
                labConfig.MasterDbConnectionString,
                denialTask.Result,
                ct);
            denialBreakdown     = AssembleDenialBreakdownV2(denialRows);
            noResponseBreakdown = AssembleNoResponseBreakdownV2(noRespTask.Result);
            spMetrics           = metricsTask.Result;

            payerNames              = filterOpts.PayerNames;
            payerTypes              = filterOpts.PayerTypes;
            panelNames              = filterOpts.PanelNames;
            coverageStatuses        = filterOpts.FinalCoverageStatuses;
            payabilityOpts          = filterOpts.Payabilities;
            cptCodes                = filterOpts.CPTCodes;
            forecastingPayabilities = filterOpts.ForecastingPayabilities;
            payStatuses             = filterOpts.PayStatuses;
            substatuses             = filterOpts.ForecastingPayabilitySubstatuses;
            predStatuses            = filterOpts.PredictionStatuses;
        }
        else
        {
            payerPayStatusRows      = [];
            adjustedByPayer         = [];
            forecastingPayabilities = baseDataset.Select(r => r.ForecastingPayability).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
            payStatuses             = baseDataset.Select(r => string.IsNullOrWhiteSpace(r.PayStatus) ? "(Blank)" : r.PayStatus).Distinct().OrderBy(v => v).ToList();
            substatuses             = baseDataset.Select(r => r.ForecastingPayabilitySubstatus).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
            predStatuses            = baseDataset.Select(r => r.PredictionStatus).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct().OrderBy(v => v).ToList();
            // File path: original in-memory aggregation
            var forecastPayable = dataset
                .Where(r => PredictionReportParserService.IsForecastPayable(r.ForecastingPayability))
                .ToList();

            var byPayStatus = forecastPayable
                .GroupBy(r => PredictionReportParserService.Normalise(r.PayStatus), StringComparer.OrdinalIgnoreCase)
                .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

            _logger.LogInformation("[{Lab}] ForecastPayable rows={FP}; PayStatus breakdown: {Values}",
                selectedLab, forecastPayable.Count, string.Join(", ", byPayStatus.Keys.Select(k => $"'{k}'")));

            var paidRows     = GetRows(byPayStatus, "Paid")
                .Concat(GetRows(byPayStatus, "Patient Responsibility"))
                .ToList();
            var deniedRows   = GetRows(byPayStatus, "Denied");
            var noRespRows   = GetRows(byPayStatus, "No Response");
            var adjustedPayRows  = GetRows(byPayStatus, "Adjusted");
            var unpaidRows       = deniedRows.Concat(noRespRows).Concat(adjustedPayRows).ToList();

            buckets = new List<PredictionBucketRow>
            {
                BuildBucket("Predicted To Pay",     forecastPayable, includeActuals: false),
                BuildBucket("Predicted \u2013 Paid",     paidRows,        includeActuals: true),
                BuildBucket("Predicted \u2013 Unpaid",   unpaidRows,      includeActuals: true),
                BuildBucket("Unpaid \u2013 Denied",      deniedRows,      includeActuals: true),
                BuildBucket("Unpaid \u2013 No Response", noRespRows,      includeActuals: true),
                BuildBucket("Unpaid \u2013 Adjusted",    adjustedPayRows,    includeActuals: true),
            };

            topPayers           = BuildPayerValidationRows(dataset);
            topPanels           = BuildPanelValidationRows(dataset);
            topCpt              = BuildCptRows(dataset);
            denialBreakdown     = BuildDenialBreakdown(deniedRows);
            noResponseBreakdown = BuildNoResponseBreakdown(noRespRows);
        }

        // ?? Breakdown charts (always computed from in-memory dataset) ???????????
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

        // ?? Expected payment by month (in-memory, fast) ???????????????????????
        var paymentByMonth = dataset
            .Where(r => !string.IsNullOrWhiteSpace(r.ExpectedPaymentMonth))
            .GroupBy(r => r.ExpectedPaymentMonth)
            .Select(g => (Month: g.Key, ExpectedPayment: g.Sum(r => r.ModeInsurancePaidSameLab)))
            .OrderBy(x => x.Month)
            .ToList();

        // ?? Summary metrics (Ratios + Prediction Accuracy) ????????????????????
        // DB path: all values come from usp_GetPredictionSummaryMetrics (SP 12).
        // File path: computed in-memory from the bucket list.
        var summaryMetrics = usingDb && spMetrics is not null
            ? MapSpMetrics(spMetrics)
            : BuildSummaryMetrics(buckets);

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

        // ── Source run info for the page header ────────────────────────────────
        // DB path: latest RunId / WeekFolder / InsertedDateTime via run-stats SP.
        // File path: derived from the resolved report file itself.
        string?   runInfoRunId      = null;
        string?   runInfoWeekFolder = null;
        DateTime? runInfoInsertedAt = null;
        string?   runInfoFileName   = null;

        if (usingDb && dbProbe is not null)
        {
            runInfoRunId      = dbProbe.LatestRunId;
            runInfoWeekFolder = dbProbe.WeekFolder;
            runInfoInsertedAt = dbProbe.LatestRunInsertedAt is { } utc
                ? DateTime.SpecifyKind(utc, DateTimeKind.Utc).ToLocalTime()
                : null;
            runInfoFileName   = dbProbe.SourceFileName;
        }
        else if (usingDb)
        {
            try
            {
                var runDiag = await _dbRepo.ProbeAsync(
                    labConfig!.DbConnectionString ?? string.Empty, HttpContext.RequestAborted);
                runInfoRunId      = runDiag.LatestRunId;
                runInfoWeekFolder = runDiag.WeekFolder;
                runInfoInsertedAt = runDiag.LatestRunInsertedAt is { } utc
                    ? DateTime.SpecifyKind(utc, DateTimeKind.Utc).ToLocalTime()
                    : null;
                runInfoFileName   = runDiag.SourceFileName;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "[{Lab}] Could not load run info for header — continuing without it.", selectedLab);
            }
        }
        else if (filePath is not null)
        {
            var fi = new FileInfo(filePath);
            runInfoFileName   = fi.Name;
            runInfoInsertedAt = fi.Exists ? fi.LastWriteTime : null;
            runInfoWeekFolder = fi.Directory?.Name;
            var baseName      = Path.GetFileNameWithoutExtension(fi.Name);
            var us            = baseName.IndexOf('_');
            runInfoRunId      = us > 0 ? baseName[..us] : null;
        }

        var totalAll      = usingDb ? (int)(dbProbe?.RowCount ?? 0) : baseDataset.Count;
        var totalFiltered = usingDb ? totalAll : dataset.Count;

        var vm = new PredictionAnalysisViewModel
        {
            AvailableLabs             = availableLabs,
            SelectedLab               = selectedLab,
            PredictionAvailable       = true,
            ResolvedFilePath          = usingDb ? $"[DB] {selectedLab}" : filePath,
            CurrentWeekStartDate      = weekStart,

            RunId          = runInfoRunId,
            WeekFolder     = runInfoWeekFolder,
            DataInsertedAt = runInfoInsertedAt,
            SourceFileName = runInfoFileName,

            FilterPayerName           = filterPayerName,
            FilterPayerType           = filterPayerType,
            FilterPanelName           = filterPanelName,
            FilterFinalCoverageStatus = filterFinalCoverageStatus,
            FilterPayability          = filterPayability,
            FilterCPTCode             = filterCPTCode,
            FilterForecastingPayability         = filterForecastingPayability,
            FilterPayStatus                     = filterPayStatus,
            FilterForecastingPayabilitySubstatus = filterForecastingPayabilitySubstatus,
            FilterPredictionStatus              = filterPredictionStatus,

            PayerNames            = payerNames,
            PayerTypes            = payerTypes,
            PanelNames            = panelNames,
            FinalCoverageStatuses = coverageStatuses,
            PayabilityOptions     = payabilityOpts,
            CPTCodes              = cptCodes,
            ForecastingPayabilities          = forecastingPayabilities,
            PayStatuses                      = payStatuses,
            ForecastingPayabilitySubstatuses = substatuses,
            PredictionStatuses               = predStatuses,

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
            Paging  = new PageInfo(currentPage, PageSize, totalFiltered, totalAll),
            DenialBreakdown         = denialBreakdown,
            NoResponseBreakdown     = noResponseBreakdown,
            AdjustedByPayer         = adjustedByPayer,
            PayerPayStatusBreakdown = payerPayStatusRows,
            Insight                 = _insightLoader.Load(labConfig?.InsightPath, selectedLab),
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
        string? tab = null,
        int page = 1)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var labConfig = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg)
            ? cfg : null;

        // Forecasting page availability is controlled only by EnableForcast.
        if (labConfig?.EnableForcast != true)
        {
            return View(new ForecastingSummaryViewModel
            {
                AvailableLabs       = availableLabs,
                SelectedLab         = selectedLab,
                PredictionAvailable = false,
                ErrorMessage        = $"Forecasting Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
            });
        }

        bool usingDb = labConfig?.DBEnabled == true;

        // ── Source run info (resolved EARLY: the forecast weeks are anchored
        //    to the source file's WeekFolder, not to today's date) ─────────────
        string?   runInfoRunId      = null;
        string?   runInfoWeekFolder = null;
        DateTime? runInfoInsertedAt = null;

        if (usingDb)
        {
            try
            {
                var runDiag = await _dbRepo.ProbeAsync(
                    labConfig!.DbConnectionString ?? string.Empty, HttpContext.RequestAborted);
                runInfoRunId      = runDiag.LatestRunId;
                runInfoWeekFolder = runDiag.WeekFolder;
                // InsertedDateTime is stored as SYSUTCDATETIME() — convert to local for display.
                runInfoInsertedAt = runDiag.LatestRunInsertedAt is { } utc
                    ? DateTime.SpecifyKind(utc, DateTimeKind.Utc).ToLocalTime()
                    : null;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "[{Lab}] Could not load run info — falling back to today-based weeks.", selectedLab);
            }
        }
        else if (!string.IsNullOrEmpty(selectedLab)
                 && _resolver.ResolvePredictionValidationReport(selectedLab) is { } srcPath)
        {
            var fi = new FileInfo(srcPath);
            runInfoInsertedAt = fi.Exists ? fi.LastWriteTime : null;
            runInfoWeekFolder = fi.Directory?.Name;
            var baseName      = Path.GetFileNameWithoutExtension(fi.Name);
            var us            = baseName.IndexOf('_');
            runInfoRunId      = us > 0 ? baseName[..us] : null;
        }

        // ── Build forecast weeks anchored to the WeekFolder ──────────────────
        // Weeks 1–4 = the 4 weeks AFTER the WeekFolder end date, each a 7-day
        // block so the weekday span always matches the WeekFolder's own range.
        // Everything earlier lands in the YTD bucket "Prior to <weekfolder>".
        // Falls back to today-based weeks when WeekFolder cannot be parsed.
        var (weeks, priorLabel, weekStart) = BuildWeekFolderAnchoredWeeks(runInfoWeekFolder);

        _logger.LogInformation(
            "[{Lab}] Forecast weeks anchored to WeekFolder '{WeekFolder}': {First} – {Last} (prior = '{Prior}')",
            selectedLab, runInfoWeekFolder, weeks[0].Label, weeks[^1].Label, priorLabel ?? "(today-based fallback)");

        var summaryWeeks = BuildForecastWeeksWithPrior(weeks, priorLabel);

        var rangeStart = weeks[0].Start;
        var rangeEnd   = weeks[^1].End;

        // Load records and filter to the 4-week window with ForecastingPayability check
        List<PredictionRecord> inRangeRecords;
        List<PredictionRecord> summaryRecords;
        List<PredictionRecord> rawRecords;

        if (usingDb)
        {
            // Slim SP: only the forecasting columns, pre-filtered in SQL to
            // forecast-payable rows — much faster for large labs (CERTUS etc.)
            rawRecords = await _dbRepo.GetForecastRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);

            _logger.LogInformation("[{Lab}] ForecastingSummary DB raw rows: {Count}", selectedLab, rawRecords.Count);

            // Use the date-range filter – NOT ApplyGlobalFilter which strips the last-4-weeks data
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, rangeStart, rangeEnd.AddDays(1));

            summaryRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, DateOnly.MinValue, rangeEnd.AddDays(1));

            _logger.LogInformation("[{Lab}] ForecastingSummary in-range rows ({Start}–{End}): {Count}",
                selectedLab, rangeStart, rangeEnd, inRangeRecords.Count);

            if (inRangeRecords.Count == 0 && rawRecords.Count > 0)
            {
                var forecastOnly = rawRecords
                    .Where(r => PredictionReportParserService.IsForecastSummaryRow(r.ForecastingPayability, r.PayStatus))
                    .ToList();

                _logger.LogWarning(
                    "[{Lab}] ForecastingSummary DB returned {RawCount} rows but 4-week window returned 0. " +
                    "Falling back to forecast-only rows ({ForecastCount}) so the page can display available data.",
                    selectedLab, rawRecords.Count, forecastOnly.Count);

                inRangeRecords = forecastOnly.Count > 0 ? forecastOnly : rawRecords;
                summaryRecords = inRangeRecords;
            }
        }
        else
        {
            var filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);

            rawRecords = filePath is not null ? _parser.Parse(filePath) : new List<PredictionRecord>();
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, rangeStart, rangeEnd.AddDays(1));
            summaryRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, DateOnly.MinValue, rangeEnd.AddDays(1));
        }

        // Detect when there is no data in the 4-week window
        bool noDataForRange = inRangeRecords.Count == 0 && summaryRecords.Count == 0;
        DateOnly? latestDataDate = null;

        if (noDataForRange)
        {
            // Reuse the already-loaded records to find the most recent
            // ExpectedPaymentDate — no second round-trip to the database.
            latestDataDate = rawRecords
                .Select(r => PredictionReportParserService.TryParseDate(r.ExpectedPaymentDate, out var d) ? d : (DateOnly?)null)
                .Where(d => d.HasValue)
                .Select(d => d!.Value)
                .DefaultIfEmpty()
                .Max() is { } max && max != default ? max : null;

            _logger.LogInformation("[{Lab}] No data in 4-week window. Latest date in data: {LatestDate}", selectedLab, latestDataDate);
        }

        // All-data summaries — prefer SQL aggregation for large DB-backed labs.
        WeeklyForecastSummary medianSummary;
        WeeklyForecastSummary modeSummary;
        if (usingDb)
        {
            var spSummary = await _dbRepo.TryGetForecastingSummaryAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);

            if (spSummary is not null)
            {
                medianSummary = spSummary.MedianSummary;
                modeSummary   = spSummary.ModeSummary;
            }
            else
            {
                (medianSummary, modeSummary) = BuildWeeklySummaries(summaryRecords, summaryWeeks);
            }
        }
        else
        {
            (medianSummary, modeSummary) = BuildWeeklySummaries(summaryRecords, summaryWeeks);
        }

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

        // (Run info for the header bar was resolved earlier — see top of action.)

        var vm = new ForecastingSummaryViewModel
        {
            AvailableLabs        = availableLabs,
            SelectedLab          = selectedLab,
            PredictionAvailable  = true,
            NoDataForRange       = noDataForRange,
            LatestDataDate       = latestDataDate,
            CurrentWeekStartDate = weekStart,
            TotalRecordsInRange  = inRangeRecords.Count,
            TotalForecastRecords = rawRecords.Count,

            RunId          = runInfoRunId,
            WeekFolder     = runInfoWeekFolder,
            DataInsertedAt = runInfoInsertedAt,
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

            // Explicit ?tab= wins (keeps the Filtered Data tab active across
            // paging links); otherwise default by filter presence.
            ActiveTab = tab?.ToLowerInvariant() is "median" or "mode" or "filtered"
                ? tab!.ToLowerInvariant()
                : (hasActiveFilters ? "filtered" : "median"),
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
            .Where(kv => kv.Value.EnablePrediction)
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

            baseDataset = PredictionReportParserService.ApplyGlobalFilter(rawRecords);
        }
        else
        {
            filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);

            baseDataset = filePath is not null ? _parser.ParseFiltered(filePath) : [];
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
            .Where(kv => kv.Value.EnablePrediction)
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
        int afterForecast = 0;
        if (usingDb)
        {
            afterForecast = PredictionReportParserService.ApplyGlobalFilter(allRecords).Count;
        }
        else
        {
            var filePath = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolvePredictionValidationReport(selectedLab);
            if (filePath is not null)
                afterForecast = _parser.ParseFiltered(filePath).Count;
        }
        var afterBoth = afterForecast;

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
        string? filterCPTCode,
        string? filterForecastingPayability,
        string? filterPayStatus,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        var labConfig     = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg) ? cfg : null;

        if (labConfig?.EnablePrediction != true)
        {
            TempData["ExportError"] = "Export is not available for the selected lab.";
            return RedirectToAction(nameof(Index), new { lab });
        }

        try
        {
            // Reuse the same data-load + filter logic as Index
            var vm = await BuildPredictionViewModelAsync(selectedLab, labConfig,
                filterPayerName, filterPayerType, filterPanelName,
                filterFinalCoverageStatus, filterPayability, filterCPTCode,
                filterForecastingPayability, filterPayStatus,
                filterForecastingPayabilitySubstatus, filterPredictionStatus);

            using var workbook = PredictionExcelExportBuilder.CreateWorkbook(vm, selectedLab,
                activeFilters: new List<(string, string?)>
                {
                    ("Payer Name", filterPayerName),
                    ("Payer Type", filterPayerType),
                    ("Panel Name", filterPanelName),
                    ("Final Coverage Status", filterFinalCoverageStatus),
                    ("Payability", filterPayability),
                    ("CPT Code", filterCPTCode),
                    ("Forecasting Payability", filterForecastingPayability),
                    ("Pay Status", filterPayStatus),
                    ("Forecasting Payability Substatus", filterForecastingPayabilitySubstatus),
                    ("Prediction Status", filterPredictionStatus),
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
    /// Downloads the Forecasting Summary as a formatted Excel file.
    /// The Data sheet contains the forecast-payable rows of the displayed run
    /// (fetched via the slim dbo.usp_GetForecastingRecords for performance);
    /// dimension filters, when supplied, are applied in memory.
    /// </summary>
    [RequestTimeout(milliseconds: 900_000)] // 15 min — large labs can take several minutes
    public async Task<IActionResult> ExportForecastingExcel(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterCPTCode)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        var labConfig     = !string.IsNullOrEmpty(selectedLab) && _labSettings.Labs.TryGetValue(selectedLab, out var cfg) ? cfg : null;

        if (labConfig?.EnableForcast != true)
        {
            TempData["ExportError"] = "Export is not available for the selected lab.";
            return RedirectToAction(nameof(ForecastingSummary), new { lab });
        }

        try
        {
            // ── Single slim fetch shared by the summary sheets AND the Data
            //    sheet (previously fetched twice — doubled the export time).
            List<PredictionRecord>? slimRecords = null;
            if (labConfig?.DBEnabled == true)
            {
                slimRecords = await _dbRepo.GetForecastRecordsAsync(
                    labConfig.DbConnectionString ?? string.Empty,
                    cancellationToken: HttpContext.RequestAborted);
            }

            var vm = await BuildForecastingViewModelAsync(selectedLab, labConfig, slimRecords);

            // ── Line-item detail for the Data sheet ──────────────────────────
            // Dimension filters are applied in memory on the shared dataset.
            List<PredictionRecord> exportRecords;
            if (slimRecords is not null)
            {
                var q = slimRecords.AsEnumerable();
                if (!string.IsNullOrWhiteSpace(filterPayerName))
                    q = q.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
                if (!string.IsNullOrWhiteSpace(filterPayerType))
                    q = q.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
                if (!string.IsNullOrWhiteSpace(filterPanelName))
                    q = q.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
                if (!string.IsNullOrWhiteSpace(filterCPTCode))
                    q = q.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));
                exportRecords = q.ToList();
            }
            else
            {
                var srcPath = string.IsNullOrEmpty(selectedLab)
                    ? null
                    : _resolver.ResolvePredictionValidationReport(selectedLab);
                var all = srcPath is not null ? _parser.Parse(srcPath) : new List<PredictionRecord>();

                var q = all.Where(r =>
                    PredictionReportParserService.IsForecastSummaryRow(
                        r.ForecastingPayability, r.PayStatus));
                if (!string.IsNullOrWhiteSpace(filterPayerName))
                    q = q.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
                if (!string.IsNullOrWhiteSpace(filterPayerType))
                    q = q.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
                if (!string.IsNullOrWhiteSpace(filterPanelName))
                    q = q.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
                if (!string.IsNullOrWhiteSpace(filterCPTCode))
                    q = q.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));
                exportRecords = q.ToList();
            }

            _logger.LogInformation(
                "[{Lab}] Forecasting Excel export: {ExportRows:N0} detail rows.",
                selectedLab, exportRecords.Count);

            var activeFilters = new List<(string Label, string? Value)>();
            if (!string.IsNullOrWhiteSpace(filterPayerName)) activeFilters.Add(("Payer Name", filterPayerName));
            if (!string.IsNullOrWhiteSpace(filterPayerType)) activeFilters.Add(("Payer Type", filterPayerType));
            if (!string.IsNullOrWhiteSpace(filterPanelName)) activeFilters.Add(("Panel", filterPanelName));
            if (!string.IsNullOrWhiteSpace(filterCPTCode))   activeFilters.Add(("CPT Code", filterCPTCode));

            using var workbook = ForecastingExcelExportBuilder.CreateWorkbook(
                vm, selectedLab, activeFilters.Count > 0 ? activeFilters : null, exportRecords);

            var saveSw = System.Diagnostics.Stopwatch.StartNew();
            using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            var bytes = stream.ToArray();
            saveSw.Stop();

            _logger.LogInformation(
                "[{Lab}] Forecasting Excel saved in {Ms}ms — {Rows:N0} detail rows, {Bytes:N0} bytes ({Mb:N1} MB).",
                selectedLab, saveSw.ElapsedMilliseconds, exportRecords.Count, bytes.Length, bytes.Length / 1_048_576.0);

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_ForecastingSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            return File(
                bytes,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Forecasting Excel export failed for lab '{LabName}'.", selectedLab);
            return StatusCode(500, $"Export failed: {ex.Message}");
        }
    }

    // ?? Private helpers ?????????????????????????????????????????????????

    /// <summary>Builds the Prediction Analysis view model (shared by Index and ExportPredictionExcel).</summary>
    private async Task<PredictionAnalysisViewModel> BuildPredictionViewModelAsync(
        string selectedLab, LabCsvConfig? labConfig,
        string? filterPayerName, string? filterPayerType, string? filterPanelName,
        string? filterFinalCoverageStatus, string? filterPayability, string? filterCPTCode,
        string? filterForecastingPayability = null,
        string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null,
        string? filterPredictionStatus = null)
    {
        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);
        bool usingDb       = labConfig?.DBEnabled == true;

        List<PredictionBucketRow>          buckets;
        PredictionSummaryMetrics         summaryMetrics;
        List<PredictionPayerRow>           topPayers;
        List<PredictionPayerPayStatusRow>    payerPayStatusRows;
        List<PredictionAdjustedPayerRow>   adjustedByPayer;
        DenialBreakdown                    denialBreakdown;
        NoResponseBreakdown                noResponseBreakdown;
        string? filePath = null;

        if (usingDb)
        {
            var connStr = labConfig!.DbConnectionString ?? string.Empty;
            var ct      = HttpContext.RequestAborted;

            var bucketTask    = _dbRepo.GetSummaryBucketsAsync(connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var metricsTask   = _dbRepo.GetSummaryMetricsAsync(connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var payerTask     = _dbRepo.GetValidationByPayerAsync(connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var payStatusTask = _dbRepo.GetPayerPayStatusBreakdownAsync(connStr, weekStart, filterPayerName: filterPayerName, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var adjustedTask  = _dbRepo.GetAdjustedByPayerAsync(connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var denialTask    = _dbRepo.GetDenialBreakdownAsync(connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);
            var noRespTask    = _dbRepo.GetNoResponseBreakdownAsync(connStr, weekStart, filterPayerName: filterPayerName, filterPayerType: filterPayerType, filterPanelName: filterPanelName, filterFinalCoverageStatus: filterFinalCoverageStatus, filterPayability: filterPayability, filterCPTCode: filterCPTCode, filterForecastingPayability: filterForecastingPayability, filterPayStatus: filterPayStatus, filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus, filterPredictionStatus: filterPredictionStatus, cancellationToken: ct);

            await Task.WhenAll(bucketTask, metricsTask, payerTask, payStatusTask, adjustedTask, denialTask, noRespTask);

            buckets = MapSpBuckets(bucketTask.Result);
            summaryMetrics = metricsTask.Result is { } spMetrics
                ? MapSpMetrics(spMetrics)
                : new PredictionSummaryMetrics();

            topPayers = payerTask.Result
                .Select(r => new PredictionPayerRow(
                    r.PayerName, r.PayerType,
                    r.TotalLineItems, r.PaidCount, r.DeniedCount, r.NoResponseCount, r.AdjustedCount, r.UnpaidCount,
                    r.TotalLineItems > 0 ? Math.Round((decimal)r.PaidCount / r.TotalLineItems * 100, 1) : null,
                    r.PredictedAllowed, r.PredictedInsurance, r.ActualAllowed, r.ActualInsurance,
                    r.VarianceAllowed, r.VariancePaid))
                .OrderByDescending(r => r.VarianceAllowed)
                .ToList();

            payerPayStatusRows = payStatusTask.Result
                .Select(r => new PredictionPayerPayStatusRow(
                    r.PayerName, r.PayStatus, r.LineItemCount,
                    r.PredictedAllowed, r.PredictedInsurance, r.ActualAllowed, r.ActualInsurance,
                    r.VarianceAllowed, r.VariancePaid))
                .ToList();

            adjustedByPayer = adjustedTask.Result
                .Select(r => new PredictionAdjustedPayerRow(
                    r.PayerName, r.LineItemCount,
                    r.PredictedAllowed, r.PredictedInsurance, r.ActualAllowed, r.ActualInsurance,
                    r.VarianceAllowed, r.VariancePaid))
                .ToList();

            var denialRows = await _denialDescLookup.EnrichAsync(
                connStr,
                labConfig.MasterDbConnectionString,
                denialTask.Result,
                ct);
            denialBreakdown     = AssembleDenialBreakdownV2(denialRows);
            noResponseBreakdown = AssembleNoResponseBreakdownV2(noRespTask.Result);
        }
        else
        {
            filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);
            var baseDataset = filePath is not null
                ? _parser.ParseFiltered(filePath)
                : [];

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
            if (!string.IsNullOrWhiteSpace(filterForecastingPayability))
                filtered = filtered.Where(r => r.ForecastingPayability.Equals(filterForecastingPayability, StringComparison.OrdinalIgnoreCase));
            if (!string.IsNullOrWhiteSpace(filterPayStatus))
                filtered = filtered.Where(r => (string.IsNullOrWhiteSpace(r.PayStatus) ? "(Blank)" : r.PayStatus).Equals(filterPayStatus, StringComparison.OrdinalIgnoreCase));
            if (!string.IsNullOrWhiteSpace(filterForecastingPayabilitySubstatus))
                filtered = filtered.Where(r => r.ForecastingPayabilitySubstatus.Equals(filterForecastingPayabilitySubstatus, StringComparison.OrdinalIgnoreCase));
            if (!string.IsNullOrWhiteSpace(filterPredictionStatus))
                filtered = filtered.Where(r => r.PredictionStatus.Equals(filterPredictionStatus, StringComparison.OrdinalIgnoreCase));

            var dataset = filtered.ToList();
            var forecastPayable = dataset
                .Where(r => PredictionReportParserService.IsForecastPayable(r.ForecastingPayability))
                .ToList();

            var byPayStatus = forecastPayable
                .GroupBy(r => PredictionReportParserService.Normalise(r.PayStatus), StringComparer.OrdinalIgnoreCase)
                .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

            var paidRows     = GetRows(byPayStatus, "Paid")
                .Concat(GetRows(byPayStatus, "Patient Responsibility"))
                .ToList();
            var deniedRows   = GetRows(byPayStatus, "Denied");
            var noRespRows   = GetRows(byPayStatus, "No Response");
            var adjustedRows = GetRows(byPayStatus, "Adjusted");
            var unpaidRows   = deniedRows.Concat(noRespRows).Concat(adjustedRows).ToList();

            buckets = new List<PredictionBucketRow>
            {
                BuildBucket("Predicted To Pay",     forecastPayable, includeActuals: false),
                BuildBucket("Predicted \u2013 Paid",     paidRows,        includeActuals: true),
                BuildBucket("Predicted \u2013 Unpaid",   unpaidRows,      includeActuals: true),
                BuildBucket("Unpaid \u2013 Denied",      deniedRows,      includeActuals: true),
                BuildBucket("Unpaid \u2013 No Response", noRespRows,      includeActuals: true),
                BuildBucket("Unpaid \u2013 Adjusted",    adjustedRows,    includeActuals: true),
            };
            summaryMetrics = BuildSummaryMetrics(buckets);
            topPayers = BuildPayerValidationRows(dataset);
            payerPayStatusRows = BuildPayerPayStatusBreakdown(forecastPayable);
            adjustedByPayer = BuildAdjustedByPayer(adjustedRows);
            denialBreakdown = BuildDenialBreakdown(deniedRows);
            noResponseBreakdown = BuildNoResponseBreakdown(noRespRows);
        }

        return new PredictionAnalysisViewModel
        {
            SelectedLab              = selectedLab,
            PredictionAvailable      = true,
            ResolvedFilePath         = usingDb ? $"[DB] {selectedLab}" : filePath,
            CurrentWeekStartDate     = weekStart,
            Buckets                  = buckets,
            SummaryMetrics           = summaryMetrics,
            TopPayerInsights         = topPayers,
            PayerPayStatusBreakdown  = payerPayStatusRows,
            AdjustedByPayer          = adjustedByPayer,
            DenialBreakdown          = denialBreakdown,
            NoResponseBreakdown      = noResponseBreakdown,
        };
    }

    /// <summary>Builds the Forecasting Summary view model (shared by ForecastingSummary and ExportForecastingExcel).</summary>
    private async Task<ForecastingSummaryViewModel> BuildForecastingViewModelAsync(
        string selectedLab, LabCsvConfig? labConfig,
        List<PredictionRecord>? preloadedRecords = null)
    {
        // Resolve the WeekFolder so the Excel export uses the same
        // WeekFolder-anchored weeks as the Forecasting Summary page.
        string? weekFolder = null;
        if (labConfig?.DBEnabled == true)
        {
            try
            {
                var runDiag = await _dbRepo.ProbeAsync(
                    labConfig.DbConnectionString ?? string.Empty, HttpContext.RequestAborted);
                weekFolder = runDiag.WeekFolder;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "[{Lab}] Export: could not load WeekFolder — falling back to today-based weeks.", selectedLab);
            }
        }
        else if (!string.IsNullOrEmpty(selectedLab)
                 && _resolver.ResolvePredictionValidationReport(selectedLab) is { } srcPath)
        {
            weekFolder = new FileInfo(srcPath).Directory?.Name;
        }

        var (weeks, priorLabel, weekStart) = BuildWeekFolderAnchoredWeeks(weekFolder);
        var summaryWeeks = BuildForecastWeeksWithPrior(weeks, priorLabel);

        var rangeStart = weeks[0].Start;
        var rangeEnd   = weeks[^1].End;

        List<PredictionRecord> inRangeRecords;
        List<PredictionRecord> summaryRecords;
        bool usingDb = labConfig?.DBEnabled == true;

        if (usingDb)
        {
            // Slim SP — same fast path as the Forecasting Summary page.
            // Reuses the caller's already-fetched dataset when supplied.
            var rawRecords = preloadedRecords ?? await _dbRepo.GetForecastRecordsAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, rangeStart, rangeEnd.AddDays(1));
            summaryRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                rawRecords, DateOnly.MinValue, rangeEnd.AddDays(1));

            if (inRangeRecords.Count == 0 && rawRecords.Count > 0)
            {
                var forecastOnly = rawRecords
                    .Where(r => PredictionReportParserService.IsForecastSummaryRow(
                        r.ForecastingPayability, r.PayStatus))
                    .ToList();

                if (forecastOnly.Count > 0)
                {
                    inRangeRecords = forecastOnly;
                    summaryRecords = forecastOnly;
                }
            }
        }
        else
        {
            var filePath = string.IsNullOrEmpty(selectedLab)
                ? null
                : _resolver.ResolvePredictionValidationReport(selectedLab);
            var allParsed = filePath is not null ? _parser.Parse(filePath) : new List<PredictionRecord>();
            inRangeRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                allParsed, rangeStart, rangeEnd.AddDays(1));
            summaryRecords = PredictionReportParserService.ApplyForecastDateRangeFilter(
                allParsed, DateOnly.MinValue, rangeEnd.AddDays(1));
        }

        WeeklyForecastSummary medianSummary;
        WeeklyForecastSummary modeSummary;
        if (usingDb)
        {
            var spSummary = await _dbRepo.TryGetForecastingSummaryAsync(
                labConfig!.DbConnectionString ?? string.Empty,
                cancellationToken: HttpContext.RequestAborted);

            if (spSummary is not null)
            {
                medianSummary = spSummary.MedianSummary;
                modeSummary   = spSummary.ModeSummary;
            }
            else
            {
                (medianSummary, modeSummary) = BuildWeeklySummaries(summaryRecords, summaryWeeks);
            }
        }
        else
        {
            (medianSummary, modeSummary) = BuildWeeklySummaries(summaryRecords, summaryWeeks);
        }

        return new ForecastingSummaryViewModel
        {
            SelectedLab          = selectedLab,
            PredictionAvailable  = true,
            CurrentWeekStartDate = weekStart,
            TotalRecordsInRange  = inRangeRecords.Count,
            MedianSummary = medianSummary,
            ModeSummary = modeSummary,
        };
    }

    // ?? Static helpers ??????????????????????????????????????????????????

    private static List<PredictionRecord> GetRows(
        Dictionary<string, List<PredictionRecord>> byPayStatus, string key) =>
        byPayStatus.TryGetValue(key, out var rows) ? rows : [];

    /// <summary>
    /// Maps the single-row SP 12 result directly to <see cref="PredictionSummaryMetrics"/>.
    /// Every ratio and accuracy value is already pre-calculated by the SP; no further
    /// arithmetic is needed here — only a straight column-to-property assignment.
    /// </summary>
    private static PredictionSummaryMetrics MapSpMetrics(PredictionSummaryMetricsSpRow sp) =>
        new()
        {
            ToPayBasis      = new(sp.ToPay_LineItems, sp.ToPay_ModeAllowed, sp.ToPay_ModeIns),
            PaidBasis       = new(sp.Paid_LineItems, sp.Paid_ModeAllowed, sp.Paid_ModeIns),
            UnpaidBasis     = new(sp.Unpaid_LineItems, sp.Unpaid_ModeAllowed, sp.Unpaid_ModeIns),
            DeniedBasis     = new(sp.Denied_LineItems, sp.Denied_ModeAllowed, sp.Denied_ModeIns),
            NoResponseBasis = new(sp.NoResp_LineItems, sp.NoResp_ModeAllowed, sp.NoResp_ModeIns),
            AdjustedBasis   = new(sp.Adj_LineItems, sp.Adj_ModeAllowed, sp.Adj_ModeIns),

            // Section 2 – Ratios
            PaymentRatioClaim       = sp.PaymentRatio_Claim,
            PaymentRatioAllowed     = sp.PaymentRatio_Allowed,
            PaymentRatioInsurance   = sp.PaymentRatio_Insurance,

            NonPaymentRateClaim     = sp.NonPaymentRate_Claim,
            NonPaymentRateAllowed   = sp.NonPaymentRate_Allowed,
            NonPaymentRateInsurance = sp.NonPaymentRate_Insurance,

            DeniedPctClaim      = sp.DeniedPct_Claim,
            DeniedPctAllowed    = sp.DeniedPct_Allowed,
            DeniedPctInsurance  = sp.DeniedPct_Insurance,

            NoResponsePctClaim      = sp.NoResponsePct_Claim,
            NoResponsePctAllowed    = sp.NoResponsePct_Allowed,
            NoResponsePctInsurance  = sp.NoResponsePct_Insurance,

            AdjustedPctClaim      = sp.AdjustedPct_Claim,
            AdjustedPctAllowed    = sp.AdjustedPct_Allowed,
            AdjustedPctInsurance  = sp.AdjustedPct_Insurance,

            // Section 3 – Prediction Accuracy
            PredVsActualRatioClaim    = sp.PredAccuracy_Claim,
            PredVsActualAllowedAmount = sp.PredAccuracy_AllowedAmount,
            PredVsActualInsPayment    = sp.PredAccuracy_InsurancePayment,
            PredAccuracyClaimNumerator       = sp.Paid_LineItems,
            PredAccuracyClaimDenominator     = sp.ToPay_LineItems,
            PredAccuracyAllowedNumerator     = sp.Paid_ActAllowed,
            PredAccuracyAllowedDenominator   = sp.ToPay_ModeAllowed,
            PredAccuracyInsuranceNumerator   = sp.Paid_ActIns,
            PredAccuracyInsuranceDenominator = sp.ToPay_ModeIns,
        };

    private static PredictionBucketRow BuildBucket(
        string name,
        IReadOnlyList<PredictionRecord> rows,
        bool includeActuals)
    {
        // Only the displayed Claim Count uses unique claims. All amount
        // columns continue to sum every line item.
        var claimCount = rows
            .Select(r => r.VisitNumber?.Trim())
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();
        var predictedAllowed = rows.Sum(r => r.ModeAllowedAmountSameLab);
        var predictedIns     = rows.Sum(r => r.ModeInsurancePaidSameLab);
        var varAllowed       = rows.Sum(r => r.Variance_AllowedAmount);
        var varPaid          = rows.Sum(r => r.Variance_PaidAmount);

        if (!includeActuals)
            return new PredictionBucketRow("Predicted To Pay", name, null, true, claimCount,
                predictedAllowed, predictedIns,
                rows.Sum(r => r.AllowedAmount), rows.Sum(r => r.InsurancePayment),
                varAllowed, varPaid);

        var actualAllowed = rows.Sum(r => r.AllowedAmount);
        var actualIns     = rows.Sum(r => r.InsurancePayment);

        return new PredictionBucketRow("Predicted To Pay", name, null, name.StartsWith("Predicted", StringComparison.Ordinal),
            claimCount, predictedAllowed, predictedIns, actualAllowed, actualIns, varAllowed, varPaid);
    }

    private static PredictionSummaryMetrics BuildSummaryMetrics(IReadOnlyList<PredictionBucketRow> buckets)
    {
        // Bucket definitions (all scoped to ForecastPayability = Payable / Potentially Payable / Payable - Need Action):
        //   toPay  = all ForecastPayable line items
        //   paid   = ForecastPayable AND PayStatus = Paid
        //   unpaid = ForecastPayable AND PayStatus IN (Denied, Adjusted, No Response)
        //   denied = ForecastPayable AND PayStatus = Denied
        //   noResp = ForecastPayable AND PayStatus = No Response
        //   adj    = ForecastPayable AND PayStatus = Adjusted
        var toPay   = buckets.FirstOrDefault(b => b.IsGroupTotal && b.GroupName == "Predicted To Pay");
        var paid    = buckets.FirstOrDefault(b => b.BucketName == "Predicted \u2013 Paid" || b.BucketName == "Predicted - Paid");
        var unpaid  = buckets.FirstOrDefault(b => b.BucketName == "Predicted \u2013 Unpaid" || b.BucketName == "Predicted - Unpaid");
        var denied  = buckets.FirstOrDefault(b => b.BucketName == "Unpaid \u2013 Denied");
        var noResp  = buckets.FirstOrDefault(b => b.BucketName == "Unpaid \u2013 No Response");
        var adj     = buckets.FirstOrDefault(b => b.BucketName == "Unpaid \u2013 Adjusted");

        static decimal? Pct(decimal? num, decimal? denom) =>
            denom is > 0 && num.HasValue ? Math.Round(num.Value / denom.Value * 100, 2) : null;

        return new PredictionSummaryMetrics
        {
            ToPayBasis = new(
                toPay?.ClaimCount ?? 0,
                toPay?.PredictedAllowed ?? 0,
                toPay?.PredictedInsurance ?? 0),
            PaidBasis = new(
                paid?.ClaimCount ?? 0,
                paid?.PredictedAllowed ?? 0,
                paid?.PredictedInsurance ?? 0),
            UnpaidBasis = new(
                unpaid?.ClaimCount ?? 0,
                unpaid?.PredictedAllowed ?? 0,
                unpaid?.PredictedInsurance ?? 0),
            DeniedBasis = new(
                denied?.ClaimCount ?? 0,
                denied?.PredictedAllowed ?? 0,
                denied?.PredictedInsurance ?? 0),
            NoResponseBasis = new(
                noResp?.ClaimCount ?? 0,
                noResp?.PredictedAllowed ?? 0,
                noResp?.PredictedInsurance ?? 0),
            AdjustedBasis = new(
                adj?.ClaimCount ?? 0,
                adj?.PredictedAllowed ?? 0,
                adj?.PredictedInsurance ?? 0),

            // Payment Ratio (%) = Predicted Paid / Predicted To Pay * 100
            PaymentRatioClaim     = Pct(paid?.ClaimCount,          toPay?.ClaimCount),
            PaymentRatioAllowed   = Pct(paid?.PredictedAllowed,    toPay?.PredictedAllowed),
            PaymentRatioInsurance = Pct(paid?.PredictedInsurance,  toPay?.PredictedInsurance),

            // Non-Payment Rate (%) = Predicted Unpaid / Predicted To Pay * 100
            NonPaymentRateClaim     = Pct(unpaid?.ClaimCount,         toPay?.ClaimCount),
            NonPaymentRateAllowed   = Pct(unpaid?.PredictedAllowed,   toPay?.PredictedAllowed),
            NonPaymentRateInsurance = Pct(unpaid?.PredictedInsurance, toPay?.PredictedInsurance),

            // Denied (%) = Denied / Total Unpaid * 100
            DeniedPctClaim      = Pct(denied?.ClaimCount,         unpaid?.ClaimCount),
            DeniedPctAllowed    = Pct(denied?.PredictedAllowed,   unpaid?.PredictedAllowed),
            DeniedPctInsurance  = Pct(denied?.PredictedInsurance, unpaid?.PredictedInsurance),

            // No Response (%) = No Response / Total Unpaid * 100
            NoResponsePctClaim      = Pct(noResp?.ClaimCount,         unpaid?.ClaimCount),
            NoResponsePctAllowed    = Pct(noResp?.PredictedAllowed,   unpaid?.PredictedAllowed),
            NoResponsePctInsurance  = Pct(noResp?.PredictedInsurance, unpaid?.PredictedInsurance),

            // Adjusted (%) = Adjusted / Total Unpaid * 100
            AdjustedPctClaim      = Pct(adj?.ClaimCount,         unpaid?.ClaimCount),
            AdjustedPctAllowed    = Pct(adj?.PredictedAllowed,   unpaid?.PredictedAllowed),
            AdjustedPctInsurance  = Pct(adj?.PredictedInsurance, unpaid?.PredictedInsurance),

            // Prediction Accuracy: Paid Claim count / Total Predicted To Pay * 100
            PredVsActualRatioClaim    = Pct(paid?.ClaimCount, toPay?.ClaimCount),
            // Prediction Accuracy amounts use the complete Predicted To Pay
            // group: actual sum / mode-predicted sum.
            PredVsActualAllowedAmount = toPay?.ActualAllowed.HasValue == true && toPay.PredictedAllowed != 0
                ? Math.Round(toPay.ActualAllowed!.Value / toPay.PredictedAllowed * 100, 2) : null,
            PredVsActualInsPayment    = toPay?.ActualInsurance.HasValue == true && toPay.PredictedInsurance != 0
                ? Math.Round(toPay.ActualInsurance!.Value / toPay.PredictedInsurance * 100, 2) : null,
            PredAccuracyClaimNumerator       = paid?.ClaimCount,
            PredAccuracyClaimDenominator     = toPay?.ClaimCount,
            PredAccuracyAllowedNumerator     = toPay?.ActualAllowed,
            PredAccuracyAllowedDenominator   = toPay?.PredictedAllowed,
            PredAccuracyInsuranceNumerator   = toPay?.ActualInsurance,
            PredAccuracyInsuranceDenominator = toPay?.PredictedInsurance,
        };
    }

    /// <summary>
    /// Builds a weekly forecast summary (Median or Mode) by assigning each record
    /// to a week bin based on its ExpectedPaymentDate and grouping by payer.
    /// </summary>
    private static IReadOnlyList<WeekRange> BuildForecastWeeksWithPrior(
        IReadOnlyList<WeekRange> weeks, string? priorLabel = null)
    {
        if (weeks.Count == 0) return weeks;

        var firstWeek = weeks[0];
        var result = new List<WeekRange>(weeks.Count + 1)
        {
            new(
                DateOnly.MinValue,
                firstWeek.Start.AddDays(-1),
                priorLabel ?? $"Prior to {firstWeek.Label}",
                IncludeBeforeStart: true)
        };
        result.AddRange(weeks);
        return result;
    }

    /// <summary>
    /// Builds the 5 forecast weeks anchored to the source WeekFolder
    /// (e.g. "06.29.2026 - 07.05.2026" or "06.29.2026 to 07.05.2026").
    /// Week 1 is the WeekFolder week ITSELF; Weeks 2–5 are the next 4 weeks
    /// (5 weeks total). Each is a 7-day block so the weekday span always
    /// matches the WeekFolder's range (Thu–Wed stays Thu–Wed, etc.).
    /// The YTD/prior bucket is labelled "Prior to &lt;weekfolder range&gt;".
    /// Falls back to the legacy today-based Monday weeks when parsing fails.
    /// </summary>
    private static (List<WeekRange> Weeks, string? PriorLabel, DateOnly WeekStart)
        BuildWeekFolderAnchoredWeeks(string? weekFolder)
    {
        if (TryParseWeekFolderRange(weekFolder, out var wfStart, out var wfEnd))
        {
            var weeks = new List<WeekRange>(5);
            for (int w = 0; w < 5; w++)
                weeks.Add(new WeekRange(wfStart.AddDays(7 * w), wfEnd.AddDays(7 * w)));

            var priorLabel = $"Prior to {wfStart:MM/dd/yyyy} - {wfEnd:MM/dd/yyyy}";
            return (weeks, priorLabel, wfStart);
        }

        // Fallback: last 4 completed Monday-based weeks (legacy behaviour).
        var today          = DateOnly.FromDateTime(DateTime.Today);
        var daysFromMonday = ((int)today.DayOfWeek + 6) % 7;
        var weekStart      = today.AddDays(-daysFromMonday);

        var fallback = new List<WeekRange>(4);
        for (int w = 4; w >= 1; w--)
        {
            var wkStart = weekStart.AddDays(-7 * w);
            fallback.Add(new WeekRange(wkStart, wkStart.AddDays(6)));
        }
        return (fallback, null, weekStart);
    }

    /// <summary>Parses WeekFolder names like "06.25.2026 - 07.01.2026" or "06.25.2026 to 07.01.2026".</summary>
    private static bool TryParseWeekFolderRange(string? weekFolder, out DateOnly start, out DateOnly end)
    {
        start = default;
        end   = default;
        if (string.IsNullOrWhiteSpace(weekFolder)) return false;

        var normalized = weekFolder
            .Replace(" to ", "-", StringComparison.OrdinalIgnoreCase)
            .Replace('–', '-')   // en dash
            .Replace('—', '-');  // em dash

        var parts = normalized.Split('-', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 2) return false;

        return TryParseWeekFolderDate(parts[0], out start)
            && TryParseWeekFolderDate(parts[1], out end)
            && end >= start;
    }

    private static bool TryParseWeekFolderDate(string value, out DateOnly date)
    {
        date  = default;
        value = value.Trim().Replace('.', '/');
        return DateOnly.TryParseExact(value, "MM/dd/yyyy",
                   CultureInfo.InvariantCulture, DateTimeStyles.None, out date)
            || DateOnly.TryParse(value, CultureInfo.InvariantCulture, out date);
    }

    private static (WeeklyForecastSummary Median, WeeklyForecastSummary Mode) BuildWeeklySummaries(
        IReadOnlyList<PredictionRecord> records,
        IReadOnlyList<WeekRange> weeks)
    {
        var priorBucket = weeks.FirstOrDefault(w => w.IncludeBeforeStart);
        var normalWeeks = weeks.Where(w => !w.IncludeBeforeStart).ToList();
        var firstNormalWeekStart = normalWeeks.Count > 0 ? normalWeeks[0].Start : (DateOnly?)null;

        var medianByPayer = new Dictionary<string, Dictionary<DateOnly, (decimal Allowed, decimal Paid)>>(
            StringComparer.OrdinalIgnoreCase);
        var modeByPayer = new Dictionary<string, Dictionary<DateOnly, (decimal Allowed, decimal Paid)>>(
            StringComparer.OrdinalIgnoreCase);
        var medianTotals = weeks.ToDictionary(w => w.Start, _ => (Allowed: 0m, Paid: 0m));
        var modeTotals = weeks.ToDictionary(w => w.Start, _ => (Allowed: 0m, Paid: 0m));

        foreach (var r in records)
        {
            if (!PredictionReportParserService.TryParseDate(r.ExpectedPaymentDate, out var pmtDate))
                continue;

            DateOnly? weekKey = null;
            if (priorBucket is not null && firstNormalWeekStart.HasValue && pmtDate < firstNormalWeekStart.Value)
                weekKey = priorBucket.Start;
            else
            {
                foreach (var wk in normalWeeks)
                {
                    if (pmtDate >= wk.Start && pmtDate <= wk.End)
                    {
                        weekKey = wk.Start;
                        break;
                    }
                }
            }

            if (weekKey is null)
                continue;

            var payer = string.IsNullOrWhiteSpace(r.PayerNameNormalized)
                ? r.PayerName
                : r.PayerNameNormalized;

            var medianAllowed = r.MedianAllowedAmountSameLab;
            var medianPaid    = r.MedianInsurancePaidSameLab;
            var modeAllowed   = r.ModeAllowedAmountSameLab;
            var modePaid      = r.ModeInsurancePaidSameLab;

            if (!medianByPayer.TryGetValue(payer, out var medianWeeks))
            {
                medianWeeks = new Dictionary<DateOnly, (decimal, decimal)>();
                medianByPayer[payer] = medianWeeks;
            }
            medianWeeks.TryGetValue(weekKey.Value, out var medianExisting);
            medianWeeks[weekKey.Value] = (
                medianExisting.Allowed + medianAllowed,
                medianExisting.Paid + medianPaid);

            if (!modeByPayer.TryGetValue(payer, out var modeWeeks))
            {
                modeWeeks = new Dictionary<DateOnly, (decimal, decimal)>();
                modeByPayer[payer] = modeWeeks;
            }
            modeWeeks.TryGetValue(weekKey.Value, out var modeExisting);
            modeWeeks[weekKey.Value] = (
                modeExisting.Allowed + modeAllowed,
                modeExisting.Paid + modePaid);

            var mt = medianTotals[weekKey.Value];
            medianTotals[weekKey.Value] = (mt.Allowed + medianAllowed, mt.Paid + medianPaid);
            var mot = modeTotals[weekKey.Value];
            modeTotals[weekKey.Value] = (mot.Allowed + modeAllowed, mot.Paid + modePaid);
        }

        var medianPayers = medianByPayer
            .OrderBy(kv => kv.Key)
            .Select(kv => new WeeklyPayerRow(kv.Key)
            {
                WeekAmounts = kv.Value.ToDictionary(
                    wk => wk.Key,
                    wk => new WeeklyAmounts(wk.Value.Allowed, wk.Value.Paid)),
                TotalAllowed = kv.Value.Values.Sum(v => v.Allowed),
                TotalPaid    = kv.Value.Values.Sum(v => v.Paid),
            })
            .ToList();

        var modePayers = modeByPayer
            .OrderBy(kv => kv.Key)
            .Select(kv => new WeeklyPayerRow(kv.Key)
            {
                WeekAmounts = kv.Value.ToDictionary(
                    wk => wk.Key,
                    wk => new WeeklyAmounts(wk.Value.Allowed, wk.Value.Paid)),
                TotalAllowed = kv.Value.Values.Sum(v => v.Allowed),
                TotalPaid    = kv.Value.Values.Sum(v => v.Paid),
            })
            .ToList();

        return (
            new WeeklyForecastSummary
            {
                Weeks = weeks,
                PayerRows = medianPayers,
                Totals = new WeeklyPayerRow("Total")
                {
                    WeekAmounts = medianTotals.ToDictionary(
                        kv => kv.Key,
                        kv => new WeeklyAmounts(kv.Value.Allowed, kv.Value.Paid)),
                    TotalAllowed = medianTotals.Values.Sum(v => v.Allowed),
                    TotalPaid    = medianTotals.Values.Sum(v => v.Paid),
                },
            },
            new WeeklyForecastSummary
            {
                Weeks = weeks,
                PayerRows = modePayers,
                Totals = new WeeklyPayerRow("Total")
                {
                    WeekAmounts = modeTotals.ToDictionary(
                        kv => kv.Key,
                        kv => new WeeklyAmounts(kv.Value.Allowed, kv.Value.Paid)),
                    TotalAllowed = modeTotals.Values.Sum(v => v.Allowed),
                    TotalPaid    = modeTotals.Values.Sum(v => v.Paid),
                },
            });
    }

    private static WeeklyForecastSummary BuildWeeklySummary(
        IReadOnlyList<PredictionRecord> records,
        IReadOnlyList<WeekRange> weeks,
        Func<PredictionRecord, decimal> allowedSelector,
        Func<PredictionRecord, decimal> paidSelector)
    {
        var priorBucket = weeks.FirstOrDefault(w => w.IncludeBeforeStart);
        var normalWeeks = weeks.Where(w => !w.IncludeBeforeStart).ToList();
        var firstNormalWeekStart = normalWeeks.Count > 0 ? normalWeeks[0].Start : (DateOnly?)null;

        var byPayer = new Dictionary<string, Dictionary<DateOnly, (decimal Allowed, decimal Paid)>>(
            StringComparer.OrdinalIgnoreCase);
        var totalWeekAmounts = weeks.ToDictionary(w => w.Start, _ => (Allowed: 0m, Paid: 0m));

        foreach (var r in records)
        {
            if (!PredictionReportParserService.TryParseDate(r.ExpectedPaymentDate, out var pmtDate))
                continue;

            DateOnly? weekKey = null;
            if (priorBucket is not null && firstNormalWeekStart.HasValue && pmtDate < firstNormalWeekStart.Value)
                weekKey = priorBucket.Start;
            else
            {
                foreach (var wk in normalWeeks)
                {
                    if (pmtDate >= wk.Start && pmtDate <= wk.End)
                    {
                        weekKey = wk.Start;
                        break;
                    }
                }
            }

            if (weekKey is null)
                continue;

            var payer = string.IsNullOrWhiteSpace(r.PayerNameNormalized)
                ? r.PayerName
                : r.PayerNameNormalized;
            var allowed = allowedSelector(r);
            var paid    = paidSelector(r);

            if (!byPayer.TryGetValue(payer, out var weekAmounts))
            {
                weekAmounts = new Dictionary<DateOnly, (decimal, decimal)>();
                byPayer[payer] = weekAmounts;
            }

            weekAmounts.TryGetValue(weekKey.Value, out var existing);
            weekAmounts[weekKey.Value] = (existing.Allowed + allowed, existing.Paid + paid);

            var t = totalWeekAmounts[weekKey.Value];
            totalWeekAmounts[weekKey.Value] = (t.Allowed + allowed, t.Paid + paid);
        }

        var payerRows = byPayer
            .OrderBy(kv => kv.Key)
            .Select(kv => new WeeklyPayerRow(kv.Key)
            {
                WeekAmounts = kv.Value.ToDictionary(
                    wk => wk.Key,
                    wk => new WeeklyAmounts(wk.Value.Allowed, wk.Value.Paid)),
                TotalAllowed = kv.Value.Values.Sum(v => v.Allowed),
                TotalPaid    = kv.Value.Values.Sum(v => v.Paid),
            })
            .ToList();

        return new WeeklyForecastSummary
        {
            Weeks = weeks,
            PayerRows = payerRows,
            Totals = new WeeklyPayerRow("Total")
            {
                WeekAmounts = totalWeekAmounts.ToDictionary(
                    kv => kv.Key,
                    kv => new WeeklyAmounts(kv.Value.Allowed, kv.Value.Paid)),
                TotalAllowed = totalWeekAmounts.Values.Sum(v => v.Allowed),
                TotalPaid    = totalWeekAmounts.Values.Sum(v => v.Paid),
            },
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
                            dgList.Sum(r => r.AllowedAmount),
                            dgList.Sum(r => r.InsurancePayment),
                            dgList.Sum(r => r.Variance_AllowedAmount),
                            dgList.Sum(r => r.Variance_PaidAmount),
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
                    pgList.Sum(r => r.AllowedAmount),
                    pgList.Sum(r => r.InsurancePayment),
                    pgList.Sum(r => r.Variance_AllowedAmount),
                    pgList.Sum(r => r.Variance_PaidAmount),
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
            TotalActualAllowed      = deniedRows.Sum(r => r.AllowedAmount),
            TotalActualInsurance    = deniedRows.Sum(r => r.InsurancePayment),
            TotalVarianceAllowed    = deniedRows.Sum(r => r.Variance_AllowedAmount),
            TotalVariancePaid       = deniedRows.Sum(r => r.Variance_PaidAmount),
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
            var lineItems = list.Select(x => x.Record.VisitNumber)
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Distinct(StringComparer.OrdinalIgnoreCase).Count();
            var varAllowed = list.Sum(x => x.Record.Variance_AllowedAmount);
            var varPaid    = list.Sum(x => x.Record.Variance_PaidAmount);
            return new AgeBucketAmount(lineItems, varAllowed, varPaid, null, null);
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
                    .OrderByDescending(b => byBucket[b].LineItemCount)
                    .First();

                return new NoResponsePayerRow(
                    pg.Key,
                    pgItems.Count,
                    pgItems.Sum(x => x.Record.Variance_AllowedAmount),
                    pgItems.Sum(x => x.Record.Variance_PaidAmount),
                    byBucket,
                    priorityBucket);
            })
            .OrderByDescending(p => p.TotalVarianceAllowed)
            .ToList();

        var totalByBucket = ByBucket(classified);

        return new NoResponseBreakdown
        {
            PayerRows            = payerRows,
            TotalLineItems         = noRespRows.Count,
            TotalVarianceAllowed   = noRespRows.Sum(r => r.Variance_AllowedAmount),
            TotalVariancePaid      = noRespRows.Sum(r => r.Variance_PaidAmount),
            TotalByBucket          = totalByBucket,
        };
    }

    /// <summary>Builds payer x pay-status breakdown rows for Excel/file-path export.</summary>
    private static List<PredictionPayerPayStatusRow> BuildPayerPayStatusBreakdown(
        IReadOnlyList<PredictionRecord> forecastPayable) =>
        forecastPayable
            .GroupBy(r => new
            {
                Payer = string.IsNullOrWhiteSpace(r.PayerNameNormalized) ? r.PayerName : r.PayerNameNormalized,
                PayStatus = string.IsNullOrWhiteSpace(r.PayStatus) ? "(Blank)" : r.PayStatus
            })
            .Select(g =>
            {
                var rows = g.ToList();
                return new PredictionPayerPayStatusRow(
                    g.Key.Payer, g.Key.PayStatus, rows.Count,
                    rows.Sum(r => r.ModeAllowedAmountSameLab),
                    rows.Sum(r => r.ModeInsurancePaidSameLab),
                    rows.Sum(r => r.AllowedAmount),
                    rows.Sum(r => r.InsurancePayment),
                    rows.Sum(r => r.Variance_AllowedAmount),
                    rows.Sum(r => r.Variance_PaidAmount));
            })
            .ToList();

    /// <summary>Builds adjusted-by-payer rows for Excel/file-path export.</summary>
    private static List<PredictionAdjustedPayerRow> BuildAdjustedByPayer(
        IReadOnlyList<PredictionRecord> adjustedRows) =>
        adjustedRows
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PayerNameNormalized) ? r.PayerName : r.PayerNameNormalized,
                     StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var rows = g.ToList();
                return new PredictionAdjustedPayerRow(
                    g.Key, rows.Count,
                    rows.Sum(r => r.ModeAllowedAmountSameLab),
                    rows.Sum(r => r.ModeInsurancePaidSameLab),
                    rows.Sum(r => r.AllowedAmount),
                    rows.Sum(r => r.InsurancePayment),
                    rows.Sum(r => r.Variance_AllowedAmount),
                    rows.Sum(r => r.Variance_PaidAmount));
            })
            .OrderByDescending(r => r.VarianceAllowed)
            .ToList();

    /// <summary>Builds Prediction Validation by Payer rows sorted by Total Claims descending.</summary>
    private static List<PredictionPayerRow> BuildPayerValidationRows(List<PredictionRecord> dataset)
    {
        static int DistinctClaimCount(IEnumerable<PredictionRecord> rows) =>
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

                int paidCnt    = DistinctClaimCount(paid);
                int deniedCnt  = DistinctClaimCount(denied);
                int noRespCnt  = DistinctClaimCount(noResp);
                int adjCnt     = DistinctClaimCount(adjusted);
                int unpaidCnt  = DistinctClaimCount(unpaid);
                int total      = DistinctClaimCount(rows);

                decimal predAllowed   = rows.Sum(r => r.ModeAllowedAmountSameLab);
                decimal predIns       = rows.Sum(r => r.ModeInsurancePaidSameLab);
                decimal actAllowed    = rows.Sum(r => r.AllowedAmount);
                decimal actIns        = rows.Sum(r => r.InsurancePayment);
                decimal? payRate      = total > 0 ? Math.Round((decimal)paidCnt / total * 100, 1) : null;

                return new PredictionPayerRow(
                    g.Key.Payer, g.Key.PayerType,
                    total, paidCnt, deniedCnt, noRespCnt, adjCnt, unpaidCnt,
                    payRate, predAllowed, predIns, actAllowed, actIns,
                    rows.Sum(r => r.Variance_AllowedAmount), rows.Sum(r => r.Variance_PaidAmount));
            })
            .OrderByDescending(r => r.TotalClaims)
            .ToList();
    }

    /// <summary>Builds Prediction Validation by Panel rows sorted by Total Claims descending.</summary>
    private static List<PredictionPanelRow> BuildPanelValidationRows(List<PredictionRecord> dataset)
    {
        static int DistinctClaimCount(IEnumerable<PredictionRecord> rows) =>
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

                int paidCnt    = DistinctClaimCount(paid);
                int deniedCnt  = DistinctClaimCount(denied);
                int noRespCnt  = DistinctClaimCount(noResp);
                int adjCnt     = DistinctClaimCount(adjusted);
                int unpaidCnt  = DistinctClaimCount(unpaid);
                int total      = DistinctClaimCount(rows);

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

    /// <summary>Builds CPT rows from an in-memory dataset (file path).</summary>
    private static List<PredictionCptRow> BuildCptRows(List<PredictionRecord> dataset) =>
        dataset
            .GroupBy(r => string.IsNullOrWhiteSpace(r.CPTCode) ? "Unknown" : r.CPTCode)
            .Select(g => new PredictionCptRow(
                g.Key,
                g.Select(r => r.VisitNumber).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                g.Sum(r => r.BilledAmount),
                g.Sum(r => r.ModeAllowedAmountSameLab),
                g.Sum(r => r.ModeInsurancePaidSameLab)))
            .OrderByDescending(x => x.PredictedInsurance)
            .Take(50)
            .ToList();

    // ── SP result assemblers ────────────────────────────────────────────────

    private static List<PredictionBucketRow> MapSpBuckets(List<PredictionBucketSpRow> spRows) =>
        spRows.OrderBy(r => r.SortOrder)
            .Select(r => new PredictionBucketRow(
                r.GroupName,
                r.IsGroupTotal ? r.GroupName : (r.PayStatus ?? r.BucketName),
                r.PayStatus,
                r.IsGroupTotal,
                r.LineItemCount,
                r.PredictedAllowed,
                r.PredictedInsurance,
                r.ActualAllowed,
                r.ActualInsurance,
                r.VarianceAllowed,
                r.VariancePaid))
            .ToList();

    private static DenialBreakdown AssembleDenialBreakdownV2(List<DenialBreakdownSpRow> spRows)
    {
        if (spRows.Count == 0) return new DenialBreakdown();
        var payerGroups = spRows.GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var list = pg.ToList();
                // Group by denial code only; prefer a non-blank description from LRNMaster enrichment.
                var topDenials = list.GroupBy(r => r.DenialCode, StringComparer.OrdinalIgnoreCase)
                    .Select(dg =>
                    {
                        var desc = dg.Select(x => x.DenialDescription)
                            .FirstOrDefault(d => !string.IsNullOrWhiteSpace(d)) ?? string.Empty;
                        return new DenialCodeRow(
                            dg.Key, desc,
                            dg.Sum(x => x.LineItemCount),
                            dg.Sum(x => x.PredictedAllowed), dg.Sum(x => x.PredictedInsurance),
                            dg.Sum(x => x.ActualAllowed), dg.Sum(x => x.ActualInsurance),
                            dg.Sum(x => x.VarianceAllowed), dg.Sum(x => x.VariancePaid),
                            new Dictionary<string, DenialMonthAmount>());
                    })
                    .OrderByDescending(d => d.VarianceAllowed).ToList();
                return new DenialPayerRow(pg.Key, list.Sum(x => x.LineItemCount),
                    list.Sum(x => x.PredictedAllowed), list.Sum(x => x.PredictedInsurance),
                    list.Sum(x => x.ActualAllowed), list.Sum(x => x.ActualInsurance),
                    list.Sum(x => x.VarianceAllowed), list.Sum(x => x.VariancePaid),
                    new Dictionary<string, DenialMonthAmount>(), topDenials);
            }).OrderByDescending(p => p.VarianceAllowed).ToList();
        return new DenialBreakdown
        {
            PayerRows = payerGroups,
            TotalClaims = spRows.Sum(r => r.LineItemCount),
            TotalPredictedAllowed = spRows.Sum(r => r.PredictedAllowed),
            TotalPredictedInsurance = spRows.Sum(r => r.PredictedInsurance),
            TotalActualAllowed = spRows.Sum(r => r.ActualAllowed),
            TotalActualInsurance = spRows.Sum(r => r.ActualInsurance),
            TotalVarianceAllowed = spRows.Sum(r => r.VarianceAllowed),
            TotalVariancePaid = spRows.Sum(r => r.VariancePaid),
        };
    }

    private static NoResponseBreakdown AssembleNoResponseBreakdownV2(List<NoResponseBreakdownSpRow> spRows)
    {
        if (spRows.Count == 0) return new NoResponseBreakdown();
        static string MapBucket(string b) => b switch
        {
            "Current" => AgeBuckets.B0_30,
            "30+" => AgeBuckets.B31_60,
            "60+" => AgeBuckets.B61_90,
            "90+" => AgeBuckets.B91_120,
            _ => AgeBuckets.B120P
        };
        var payerRows = spRows.GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var list = pg.ToList();
                var byBucket = list.ToDictionary(
                    x => MapBucket(x.AgeBucket),
                    x => new AgeBucketAmount(
                        x.LineItemCount, x.VarianceAllowed, x.VariancePaid,
                        x.PctVarianceAllowed, x.PctVariancePaid));
                var priority = byBucket.OrderByDescending(kv => kv.Value.LineItemCount).First().Key;
                return new NoResponsePayerRow(pg.Key, list.Sum(x => x.LineItemCount),
                    list.Sum(x => x.VarianceAllowed), list.Sum(x => x.VariancePaid),
                    byBucket, priority);
            }).OrderByDescending(p => p.TotalVarianceAllowed).ToList();

        var totalByBucket = AgeBuckets.All.ToDictionary(
            b => b,
            b =>
            {
                var rows = spRows.Where(r => MapBucket(r.AgeBucket) == b).ToList();
                if (rows.Count == 0)
                    return new AgeBucketAmount(0, 0, 0, null, null);
                return new AgeBucketAmount(
                    rows.Sum(r => r.LineItemCount),
                    rows.Sum(r => r.VarianceAllowed),
                    rows.Sum(r => r.VariancePaid),
                    null, null);
            });

        return new NoResponseBreakdown
        {
            PayerRows = payerRows,
            TotalLineItems = spRows.Sum(r => r.LineItemCount),
            TotalVarianceAllowed = spRows.GroupBy(r => r.PayerName).Select(g => g.First().TotalVarianceAllowed).Sum(),
            TotalVariancePaid = spRows.GroupBy(r => r.PayerName).Select(g => g.First().TotalVariancePaid).Sum(),
            TotalByBucket = totalByBucket,
        };
    }

    /// <summary>Assembles a DenialBreakdown from the flat SP 10 rows.</summary>
    private static DenialBreakdown AssembleDenialBreakdown(List<DenialBreakdownSpRow> spRows)
    {
        if (spRows.Count == 0) return new DenialBreakdown();

        var months = spRows
            .Select(r => r.ExpectedPaymentMonth)
            .Where(m => !string.IsNullOrWhiteSpace(m))
            .Distinct()
            .OrderBy(m => m)
            .ToList();

        DenialMonthAmount MonthAmount(IEnumerable<DenialBreakdownSpRow> rows, string month)
        {
            var list = rows.Where(r => r.ExpectedPaymentMonth == month).ToList();
            return new DenialMonthAmount(
                list.Sum(r => r.LineItemCount),
                list.Sum(r => r.PredictedAllowed),
                list.Sum(r => r.PredictedInsurance));
        }

        var payerGroups = spRows
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var pgList      = pg.ToList();
                var totalClaims = pgList.Sum(r => r.LineItemCount);

                var byMonth = months.ToDictionary(
                    m => m,
                    m => MonthAmount(pgList, m));

                var topDenials = pgList
                    .GroupBy(r => new { r.DenialCode, r.DenialDescription }, (k, g) =>
                    {
                        var dgList = g.ToList();
                        return new DenialCodeRow(
                            k.DenialCode, k.DenialDescription,
                            dgList.Sum(r => r.LineItemCount),
                            dgList.Sum(r => r.PredictedAllowed),
                            dgList.Sum(r => r.PredictedInsurance),
                            dgList.Sum(r => r.ActualAllowed),
                            dgList.Sum(r => r.ActualInsurance),
                            dgList.Sum(r => r.VarianceAllowed),
                            dgList.Sum(r => r.VariancePaid),
                            months.ToDictionary(m => m, m => MonthAmount(dgList, m)));
                    })
                    .OrderByDescending(d => d.TotalClaims)
                    .Take(5)
                    .ToList();

                return new DenialPayerRow(
                    pg.Key, totalClaims,
                    pgList.Sum(r => r.PredictedAllowed),
                    pgList.Sum(r => r.PredictedInsurance),
                    pgList.Sum(r => r.ActualAllowed),
                    pgList.Sum(r => r.ActualInsurance),
                    pgList.Sum(r => r.VarianceAllowed),
                    pgList.Sum(r => r.VariancePaid),
                    byMonth, topDenials);
            })
            .OrderByDescending(p => p.TotalClaims)
            .ToList();

        var grandByMonth = months.ToDictionary(
            m => m,
            m => MonthAmount(spRows, m));

        return new DenialBreakdown
        {
            Months                  = months,
            PayerRows               = payerGroups,
            TotalClaims             = spRows.Sum(r => r.LineItemCount),
            TotalPredictedAllowed   = spRows.Sum(r => r.PredictedAllowed),
            TotalPredictedInsurance = spRows.Sum(r => r.PredictedInsurance),
            TotalActualAllowed      = spRows.Sum(r => r.ActualAllowed),
            TotalActualInsurance    = spRows.Sum(r => r.ActualInsurance),
            TotalVarianceAllowed    = spRows.Sum(r => r.VarianceAllowed),
            TotalVariancePaid       = spRows.Sum(r => r.VariancePaid),
            TotalByMonth            = grandByMonth,
        };
    }

    /// <summary>Assembles a NoResponseBreakdown from the flat SP 11 rows.</summary>
    private static NoResponseBreakdown AssembleNoResponseBreakdown(List<NoResponseBreakdownSpRow> spRows)
    {
        if (spRows.Count == 0) return new NoResponseBreakdown();

        AgeBucketAmount BucketAmount(IEnumerable<NoResponseBreakdownSpRow> rows, string bucket)
        {
            var list = rows.Where(r => r.AgeBucket == bucket).ToList();
            return new AgeBucketAmount(
                list.Sum(r => r.LineItemCount),
                list.Sum(r => r.VarianceAllowed),
                list.Sum(r => r.VariancePaid),
                list.Count > 0 ? list.Average(r => r.PctVarianceAllowed ?? 0) : null,
                list.Count > 0 ? list.Average(r => r.PctVariancePaid ?? 0) : null);
        }

        var payerRows = spRows
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var pgList      = pg.ToList();
                var totalItems  = pgList.Sum(r => r.LineItemCount);

                var byBucket = AgeBuckets.All.ToDictionary(
                    b => b,
                    b => BucketAmount(pgList, b));

                var priorityBucket = AgeBuckets.All
                    .OrderByDescending(b => byBucket[b].LineItemCount)
                    .First();

                return new NoResponsePayerRow(
                    pg.Key, totalItems,
                    pgList.First().TotalVarianceAllowed,
                    pgList.First().TotalVariancePaid,
                    byBucket, priorityBucket);
            })
            .OrderByDescending(p => p.TotalVarianceAllowed)
            .ToList();

        var totalByBucket = AgeBuckets.All.ToDictionary(
            b => b,
            b => BucketAmount(spRows, b));

        return new NoResponseBreakdown
        {
            PayerRows            = payerRows,
            TotalLineItems         = spRows.Sum(r => r.LineItemCount),
            TotalVarianceAllowed   = spRows.GroupBy(r => r.PayerName).Select(g => g.First().TotalVarianceAllowed).Sum(),
            TotalVariancePaid      = spRows.GroupBy(r => r.PayerName).Select(g => g.First().TotalVariancePaid).Sum(),
            TotalByBucket          = totalByBucket,
        };
    }
}
