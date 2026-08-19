using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Generic, lab-aware Executive Summary controller.
/// Replaces the old lab-specific <c>PhiExecutiveSummaryController</c> for new
/// labs (RisingTides today; others can be added by registering the SP prefix).
/// Reuses <see cref="SqlPhiExecutiveSummaryRepository"/> because every lab's
/// Executive Summary SP returns the same 6-column contract:
/// RowCode, Category, Description, BillYear, BillMonth, MetricValue.
/// </summary>
public sealed class ExecutiveSummaryController : Controller
{
    private readonly LabSettings _labSettings;
    private readonly SqlPhiExecutiveSummaryRepository _repo;
    private readonly IAnalysisRangeService _analysisRange;
    private readonly PredictionInsightLoader _insightLoader;
    private readonly IConfiguration _config;
    private readonly ILogger<ExecutiveSummaryController> _logger;

    // Maps LabSettings key → SP prefix used to build "dbo.usp_Get{prefix}_ExecutiveSummary".
    // Keep aligned with PhiExecutiveSummaryController.LabPrefixMap.
    // PUBLIC: reused by LRN.ReportWorker's ExecutiveSummaryReportGenerator so the
    // async export resolves the exact same per-lab stored procedure.
    public static readonly Dictionary<string, string> LabPrefixMap =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["RisingTides"]      = "RT",
            ["Rising_Tides"]     = "RT",
            ["Phi_Life"]         = "Phi",
            ["PhiLife"]          = "Phi",
            ["Augustus"]         = "Aug",
            ["Augustus_Labs"]    = "Aug",
            ["Augustus_LRN"]     = "Aug",
            ["Certus"]           = "Cert",
            ["Certus_LRN"]       = "Cert",
            ["CERT"]             = "Cert",
            ["Cert"]             = "Cert",
            ["Inhealth"]         = "Inh",
            ["Inhealth_LRN"]     = "Inh",
            ["Inhealth_DTR"]     = "Inh",
            ["Cove"]             = "Cove",
            ["CoveLRN"]          = "Cove",
            ["Elixir"]           = "Elix",
            ["Elixir_LRN"]       = "Elix",
            ["NorthWest"]        = "NW",
            ["NWL"]              = "NW",
            ["PCRLabsofAmerica"] = "PCR",
            ["PCRLOA"]           = "PCR",
            ["PCR_Dx_AL"]        = "PCR",
            ["PCR_Dx_CO"]        = "PCR",
            ["PCRAL"]            = "PCR",
            ["PCRCO"]            = "PCR",
            ["Beech_Tree"]       = "BT",
        };

    public ExecutiveSummaryController(
        LabSettings labSettings,
        SqlPhiExecutiveSummaryRepository repo,
        IAnalysisRangeService analysisRange,
        PredictionInsightLoader insightLoader,
        IConfiguration config,
        ILogger<ExecutiveSummaryController> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _analysisRange = analysisRange;
        _insightLoader = insightLoader;
        _config = config;
        _logger      = logger;
    }

    // All labs in LabPrefixMap now support extended filter parameters.
    // IsCoveLab kept as alias for backward compatibility with Detail action.
    private static bool IsCoveLab(string labName) =>
        labName.Equals("Cove",    StringComparison.OrdinalIgnoreCase) ||
        labName.Equals("CoveLRN", StringComparison.OrdinalIgnoreCase);

    public async Task<IActionResult> Index(
        string? lab,
        int?    yearFrom,
        int?    yearTo,
        int?    monthFrom,
        int?    monthTo,
        string? export, // "excel"
        // New extended filter params
        DateTime? dosFrom      = null,
        DateTime? dosTo        = null,
        DateTime? billedFrom   = null,
        DateTime? billedTo     = null,
        // Dimension multi-selects — bound from <select multiple> or comma-joined hidden inputs
        string[]? panels    = null,
        string[]? clinics   = null,
        string[]? providers = null,
        string[]? reps      = null,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();

        // Cookie → query-string → first lab (same logic as every other page)
        var labName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        ViewData["Title"] = "Executive Summary";

        var emptyVm = new PhiExecutiveSummaryViewModel
        {
            AvailableLabs     = availableLabs,
            SelectedLab       = labName,
            SelectedYearFrom  = yearFrom,
            SelectedYearTo    = yearTo,
            SelectedMonthFrom = monthFrom,
            SelectedMonthTo   = monthTo,
            DosFrom      = dosFrom,
            DosTo        = dosTo,
            BilledFrom   = billedFrom,
            BilledTo     = billedTo,
            SelectedPanels    = panels    is null ? [] : [.. panels],
            SelectedClinics   = clinics   is null ? [] : [.. clinics],
            SelectedProviders = providers is null ? [] : [.. providers],
            SelectedReps      = reps      is null ? [] : [.. reps],
        };

        if (!_labSettings.Labs.TryGetValue(labName, out var config))
        {
            emptyVm.ErrorMessage = $"Lab configuration not found for '{labName}'.";
            return View(emptyVm);
        }

        if (string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            emptyVm.ErrorMessage = $"No database connection configured for '{labName}'.";
            return View(emptyVm);
        }

        if (!LabPrefixMap.TryGetValue(labName, out var prefix))
        {
            emptyVm.ErrorMessage = $"Executive Summary is not available for '{labName}'.";
            return View(emptyVm);
        }

        var spName  = $"dbo.usp_Get{prefix}_ExecutiveSummary";
        var connStr = config.DbConnectionString;

        bool spExists = await _repo.StoredProcedureExistsAsync(connStr, spName, ct);
        if (!spExists)
        {
            emptyVm.ErrorMessage =
                $"Data not generated for this lab. The stored procedure '{spName}' does not exist.";
            return View(emptyVm);
        }

        // Join array params into comma-separated strings for the SP
        var panelsStr    = panels    is { Length: > 0 } ? string.Join(",", panels)    : null;
        var clinicsStr   = clinics   is { Length: > 0 } ? string.Join(",", clinics)   : null;
        var providersStr = providers is { Length: > 0 } ? string.Join(",", providers) : null;
        var repsStr      = reps      is { Length: > 0 } ? string.Join(",", reps)      : null;

        var availableYears = await _repo.GetAvailableYearsAsync(connStr, ct);

        var vm = await _repo.GetExecutiveSummaryAsync(
            connStr, spName, availableLabs, labName,
            yearFrom, yearTo, monthFrom, monthTo,
            useExtendedFilters: true,
            dosFrom:      dosFrom,
            dosTo:        dosTo,
            billedFrom:   billedFrom,
            billedTo:     billedTo,
            panels:       panelsStr,
            clinics:      clinicsStr,
            providers:    providersStr,
            reps:         repsStr,
            ct: ct);

        if (vm.AvailableYears.Count == 0)
            vm.AvailableYears = availableYears;

        // The repository reconstructs Selected* by splitting the comma-joined
        // filter strings, which corrupts values that themselves contain commas
        // (e.g. ReferringProvider = 'LastName,FirstName' → 'ABBOTT,JOEL').
        // Restore the true selections from the original posted arrays so the
        // dropdown checkboxes / chips reflect what the user actually selected.
        vm.SelectedPanels    = panels    is null ? [] : [.. panels];
        vm.SelectedClinics   = clinics   is null ? [] : [.. clinics];
        vm.SelectedProviders = providers is null ? [] : [.. providers];
        vm.SelectedReps      = reps      is null ? [] : [.. reps];

        // Run / analysis-range banner: WeekFolder + RunId + InsertedDate from
        // LineClaimFileLogs (shared AnalysisRangeService), plus LIMSMaster RunId.
        var analysisRange = await _analysisRange.GetAsync(connStr, ct);
        var (_, _, limsRunId) = await _repo.GetRunInfoAsync(connStr, ct);
        vm.ReportWeekFolder        = analysisRange.WeekFolder;
        vm.ReportRunId             = analysisRange.RunId;
        vm.ReportInsertedDateTime  = analysisRange.InsertedDateTime;
        vm.LimsRunId               = limsRunId;
        ViewData["AnalysisRange"]  = analysisRange;

        // Pre-populate dimension filter options from the lab's FilterOptions SP (if it exists)
        var filterSpName = $"dbo.usp_Get{prefix}_ExecutiveSummary_FilterOptions";
        bool filterSpExists = await _repo.StoredProcedureExistsAsync(connStr, filterSpName, ct);
        if (filterSpExists)
        {
            var filterOptions = await _repo.GetFilterOptionsAsync(connStr, filterSpName, ct);
            vm.AvailablePanels    = filterOptions.GetValueOrDefault("Panel",    []);
            vm.AvailableClinics   = filterOptions.GetValueOrDefault("Clinic",   []);
            vm.AvailableProviders = filterOptions.GetValueOrDefault("Provider", []);
            vm.AvailableReps      = filterOptions.GetValueOrDefault("Rep",      []);
        }

        _logger.LogInformation(
            "ExecutiveSummary ready to render for lab='{Lab}' SP='{Sp}' rows={Rows} cols={Cols}",
            labName, spName, vm.Rows.Count, vm.YearMonthColumns.Count);

        if (labName.Equals("Beech_Tree", StringComparison.OrdinalIgnoreCase))
        {
            var insightRoot = _config["ThreePillarInsights:LocalRoot"]
                ?? @"C:\LRN-Files\Automation\LRN-Output\Coding_Validation_Report\Beech_Tree\ThreePillar";
            vm.AiThreePillarInsight = _insightLoader.LoadThreePillar(insightRoot, vm.ReportWeekFolder);
        }

        if (export == "excel")
        {
            var excelBuilder = new ExecutiveSummaryExcelBuilder();
            var fileBytes = excelBuilder.Build(vm);
            return File(fileBytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                $"ExecutiveSummary_{labName}_{DateTime.Now:yyyyMMdd}.xlsx");
        }

        return View(vm);
    }

    /// <summary>
    /// AJAX endpoint — returns dimension filter options for the given lab.
    /// All labs are supported; returns empty lists if the lab's FilterOptions SP
    /// does not yet exist.
    /// URL: GET /ExecutiveSummary/FilterOptions?lab=Cove
    /// Response: { "years":[], "panels":[], "clinics":[], "providers":[], "reps":[] }
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> FilterOptions(string? lab, CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var labName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (!_labSettings.Labs.TryGetValue(labName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return Json(new { error = "Lab not configured." });

        if (!LabPrefixMap.TryGetValue(labName, out var prefix))
            return Json(new { years = Array.Empty<string>(), panels = Array.Empty<string>(), clinics = Array.Empty<string>(), providers = Array.Empty<string>(), reps = Array.Empty<string>() });

        var filterSpName = $"dbo.usp_Get{prefix}_ExecutiveSummary_FilterOptions";
        bool filterSpExists = await _repo.StoredProcedureExistsAsync(config.DbConnectionString, filterSpName, ct);
        if (!filterSpExists)
            return Json(new { years = Array.Empty<string>(), panels = Array.Empty<string>(), clinics = Array.Empty<string>(), providers = Array.Empty<string>(), reps = Array.Empty<string>() });

        var options = await _repo.GetFilterOptionsAsync(config.DbConnectionString, filterSpName, ct);
        return Json(new
        {
            years     = options.GetValueOrDefault("Year",     []),
            panels    = options.GetValueOrDefault("Panel",    []),
            clinics   = options.GetValueOrDefault("Clinic",   []),
            providers = options.GetValueOrDefault("Provider", []),
            reps      = options.GetValueOrDefault("Rep",      []),
        });
    }

    /// <summary>
    /// AJAX endpoint – returns the detail partial for a single cell click.
    /// <summary>
    /// Full-page detail view for a single Executive Summary cell.
    /// URL: /ExecutiveSummary/Detail?lab=RisingTides&amp;category=PMS&amp;rowCode=O
    ///      &amp;year=2025&amp;month=3&amp;description=...
    ///      &amp;yearFrom=...&amp;yearTo=...&amp;monthFrom=...&amp;monthTo=...  ← original index filters
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> Detail(
        string? lab,
        string  category,
        string  rowCode,
        string  description,
        int     year      = 0,
        int     month     = 0,
        decimal? value     = null,
        int?    yearFrom  = null,
        int?    yearTo    = null,
        int?    monthFrom = null,
        int?    monthTo   = null,
        string? export    = null, // "excel"
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var labName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        // Build the back-link URL preserving the original index filters
        var backUrl = Url.Action("Index", "ExecutiveSummary", new
        {
            lab      = labName,
            yearFrom,
            yearTo,
            monthFrom,
            monthTo,
        }) ?? "/ExecutiveSummary";

        var errorVm = new ExecSummaryDetailRowsViewModel
        {
            Category      = category,
            RowCode       = rowCode,
            Description   = description,
            Year          = year,
            Month         = month,
            SelectedValue = value,
            BackUrl       = backUrl,
        };

        if (!_labSettings.Labs.TryGetValue(labName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            errorVm.ErrorMessage = "Lab not configured.";
            return View("Detail", errorVm);
        }

        if (!LabPrefixMap.TryGetValue(labName, out _))
        {
            errorVm.ErrorMessage = $"Detail not available for '{labName}'.";
            return View("Detail", errorVm);
        }

        var connStr = config.DbConnectionString;
        bool isRisingTides =
            string.Equals(labName, "RisingTides",  StringComparison.OrdinalIgnoreCase) ||
            string.Equals(labName, "Rising_Tides", StringComparison.OrdinalIgnoreCase);

        // ── Route to the row-level detail SP based on the clicked category ──
        //   LIS                                   → LIMSMaster
        //   PMS "R" (Paid - Client), RisingTides  → ClientPaidListData
        //   PMS / Cash (everything else)          → ClaimLevelData
        string detailSp;
        string sourceLabel;
        var sqlParams = new Dictionary<string, object?>
        {
            ["@Year"]  = year,
            ["@Month"] = month,
        };

        if (string.Equals(category, "LIS", StringComparison.OrdinalIgnoreCase))
        {
            detailSp           = "dbo.usp_GetExecutiveSummaryDetail_LIS";
            sourceLabel        = "LIMSMaster";
            sqlParams["@RowCode"] = rowCode;
        }
        else if (isRisingTides
                 && string.Equals(category, "PMS", StringComparison.OrdinalIgnoreCase)
                 && string.Equals(rowCode, "R", StringComparison.OrdinalIgnoreCase))
        {
            detailSp    = "dbo.usp_GetExecutiveSummaryDetail_ClientPaidList";
            sourceLabel = "ClientPaidListData";
        }
        else
        {
            detailSp              = "dbo.usp_GetExecutiveSummaryDetail_PMSCash";
            sourceLabel           = "ClaimLevelData";
            sqlParams["@Category"] = category;
            sqlParams["@RowCode"]  = rowCode;
        }

        bool spExists = await _repo.StoredProcedureExistsAsync(connStr, detailSp, ct);
        if (!spExists)
        {
            errorVm.ErrorMessage =
                $"Detail data is not available yet. The stored procedure '{detailSp}' does not exist.";
            errorVm.SourceLabel = sourceLabel;
            return View("Detail", errorVm);
        }

        var vm = await _repo.GetDetailRowsDynamicAsync(
            connStr, detailSp, sqlParams,
            category, rowCode, description, year, month, sourceLabel, ct);

        vm.BackUrl       = backUrl;
        vm.SelectedValue = value;

        if (export == "excel")
        {
            var excelBuilder = new ExecSummaryDetailExcelBuilder();
            var fileBytes = excelBuilder.Build(vm);
            var fileNameSafe = string.Concat(vm.Description.Trim().Split(Path.GetInvalidFileNameChars()));
            return File(fileBytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                $"ExecutiveSummaryDetail_{labName}_{fileNameSafe}_{DateTime.Now:yyyyMMdd}.xlsx");
        }

        return View("Detail", vm);
    }

    /// <summary>
    /// Insight drill-through for LIS / PMS / Cash Breakdown rows — reachable from
    /// Grand Total / Year Total cells. Row filters from dbo.LisDrillRowDef;
    /// Cash uses dbo.usp_GetExecutiveSummaryDetail_CashDrill_Core (dollar SUM).
    /// URL: /ExecutiveSummary/LisDrill?lab=Cove&amp;rowCode=O&amp;category=Cash&amp;year=2026
    /// (year=0 → Grand Total across all years).
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> LisDrill(
        string? lab,
        string  metric    = "Samples",
        string? rowCode   = null,
        string? rowTitle  = null,
        string? category  = null,
        int     year      = 0,
        decimal? value    = null,
        int?    yearFrom  = null,
        int?    yearTo    = null,
        int?    monthFrom = null,
        int?    monthTo   = null,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var labName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        // Show the resolved lab in the navbar and lock lab switching: the drill
        // data is scoped to the lab this page was opened from.
        ViewData["SelectedLab"]      = labName;
        ViewData["DisableLabSwitch"] = true;

        // Breadcrumb: Home › Executive Summary (drill opens from there, not the
        // Revenue Dashboard).
        ViewData["BreadcrumbParent"]    = "Executive Summary";
        ViewData["BreadcrumbParentUrl"] = Url.Action("Index", "ExecutiveSummary", new { lab = labName });

        // Normalise metric to the supported values.
        metric =
            string.Equals(metric, "Billable",    StringComparison.OrdinalIgnoreCase) ? "Billable" :
            string.Equals(metric, "NotResulted", StringComparison.OrdinalIgnoreCase) ? "NotResulted" :
                                                                                        "Samples";

        var backUrl = Url.Action("Index", "ExecutiveSummary", new
        {
            lab = labName, yearFrom, yearTo, monthFrom, monthTo,
        }) ?? "/ExecutiveSummary";

        var vm = new ExecSummaryLisDrillViewModel
        {
            Metric        = metric,
            Year          = year,
            SelectedValue = value,
            BackUrl       = backUrl,
        };

        if (!_labSettings.Labs.TryGetValue(labName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            vm.ErrorMessage = "Lab not configured.";
            return View("LisDrill", vm);
        }

        if (!LabPrefixMap.TryGetValue(labName, out var prefix))
        {
            vm.ErrorMessage = $"Drill-through not available for '{labName}'.";
            return View("LisDrill", vm);
        }

        var analysisRange = await _analysisRange.GetAsync(config.DbConnectionString, ct);
        // WeekFolder end-day → provisional 9 when unparsed (CutoffDate applied after SP).
        var fromFolder = AnalysisRangeInfo.ResolveComparableDayWindow(
            analysisRange.WeekFolder, fallback: 0);
        var dayWindow = fromFolder > 0 ? fromFolder : 9;

        // Prefer the ES grid heading when present (querystring), so the page
        // title matches the Description column even before LisDrillRowDef loads.
        var gridRowTitle = string.IsNullOrWhiteSpace(rowTitle) ? null : rowTitle.Trim();

        // ── Row-level drill: a specific LIS Breakdown row (Billed, Unbilled,
        //    sub-status, Other Samples…) resolved from dbo.LisDrillRowDef. ──
        if (!string.IsNullOrWhiteSpace(rowCode))
        {
            category = string.IsNullOrWhiteSpace(category) ? category : category.Trim();
            rowCode = rowCode.Trim();
            var preferredSource =
                string.Equals(category, "PMS", StringComparison.OrdinalIgnoreCase) ? "PMS" :
                string.Equals(category, "Cash", StringComparison.OrdinalIgnoreCase) ? "Cash" :
                string.Equals(category, "LIS", StringComparison.OrdinalIgnoreCase) ? "LIS" :
                null;
            var def = await _repo.GetLisDrillRowDefAsync(
                config.DbConnectionString, prefix, rowCode, preferredSource, ct);
            if (def is not null)
            {
                var coreSp = def.IsCash
                    ? "dbo.usp_GetExecutiveSummaryDetail_CashDrill_Core"
                    : def.IsPms
                        ? "dbo.usp_GetExecutiveSummaryDetail_PmsDrill_Core"
                        : "dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core";

                if (await _repo.StoredProcedureExistsAsync(config.DbConnectionString, coreSp, ct))
                {
                    // Prefer WeekFolder day when known — avoids a second full Core SP
                    // call that only exists to discover CutoffDate.Day.
                    var dayWindowKnownFromFolder = fromFolder > 0;

                    var titleLooksFullyPaid = def.IsPms
                        && !string.IsNullOrWhiteSpace(def.RowTitle)
                        && def.RowTitle.Contains("Fully Paid", StringComparison.OrdinalIgnoreCase)
                        && !def.RowTitle.Contains('$');
                    // Mismatch = Op MISMATCH|* / title / URL rowTitle — even when Source
                    // was mis-seeded, category=PMS + "Mismatch" still takes the ES path.
                    var titleLooksMismatch =
                        def.IsPmsMismatch
                        || (string.Equals(category, "PMS", StringComparison.OrdinalIgnoreCase)
                            && (ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(def.RowTitle)
                                || ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(gridRowTitle)))
                        || ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(gridRowTitle);
                    var needsEsCompanion = def.IsPms
                        && (def.IsPmsTotalBilledClaims || def.IsPmsFullyPaid || titleLooksFullyPaid
                            || titleLooksMismatch)
                        || titleLooksMismatch;

                    // Overlap RunInfo + optional ES companion with the heavy Core SP.
                    // Do NOT prefetch ES for Sec1/2/3 stacked rows (Insurance Balance) —
                    // Core already returns StatusBreakdown; waiting on the full ES grid
                    // was making those drills much slower than other Insight rows.
                    var mayNeedSubcategoryStack = !titleLooksMismatch && !titleLooksFullyPaid
                        && !def.IsPmsFullyPaid && !def.IsPmsMismatch;
                    var mayNeedEsForStackOrPanels = mayNeedSubcategoryStack
                        && !def.HasCoreStatusStack;
                    var runInfoTask = _repo.GetRunInfoAsync(config.DbConnectionString, ct);
                    var esPrefetchTask = (needsEsCompanion || mayNeedEsForStackOrPanels)
                        ? _repo.PrefetchExecutiveSummaryForDrillAsync(
                            config.DbConnectionString, prefix, labName, year, ct)
                        : null;

                    ExecSummaryLisDrillViewModel rowResult;
                    if (titleLooksMismatch)
                    {
                        // Formula row: KPIs / trend come from usp_Get{prefix}_ExecutiveSummary
                        // (same numbers as the ES grid). Skip ClaimLevelData Core — it is not
                        // the source of the Index cell and used to leave HasData false.
                        rowResult = new ExecSummaryLisDrillViewModel
                        {
                            Metric = "Billable",
                            Year = year,
                            SourceLabel = "ClaimLevelData",
                            ComparableDayWindow = dayWindow,
                            IsPmsMismatchDrill = true,
                            DescriptionOverride =
                                "Matches the Executive Summary formula for this row: PMS Billed count (Date of Service) minus LIS Billed count (Request Collect Date) per month. Panel / Top Insurance are not shown — this metric is a period count difference, not a claim-level set.",
                        };
                    }
                    else if (def.IsCash)
                    {
                        rowResult = await _repo.GetCashDrillCoreAsync(
                            config.DbConnectionString, coreSp, year, def, dayWindow, ct);
                    }
                    else if (def.IsPms)
                    {
                        rowResult = await _repo.GetPmsDrillCoreAsync(
                            config.DbConnectionString, coreSp, year, def, dayWindow, ct);
                    }
                    else
                    {
                        // No filter conditions → Total (all); otherwise a filtered count.
                        var rowMetric = def.HasCondition ? "Billable" : "Samples";
                        rowResult = await _repo.GetLisDrillCoreAsync(
                            config.DbConnectionString, coreSp, rowMetric, year, def, dayWindow, ct);
                    }

                    // Refine only when WeekFolder was unparsed (provisional 9).
                    // When WeekFolder parsed, refined == fromFolder already.
                    // Skip re-query for mismatch (ES-backed, not DayWindow Core).
                    if (!titleLooksMismatch
                        && !dayWindowKnownFromFolder
                        && string.IsNullOrWhiteSpace(rowResult.ErrorMessage))
                    {
                        var refined = AnalysisRangeInfo.ResolveComparableDayWindow(
                            analysisRange.WeekFolder, rowResult.Summary.CutoffDate, fallback: 9);
                        if (refined != dayWindow)
                        {
                            dayWindow = refined;
                            if (def.IsCash)
                            {
                                rowResult = await _repo.GetCashDrillCoreAsync(
                                    config.DbConnectionString, coreSp, year, def, dayWindow, ct);
                            }
                            else if (def.IsPms)
                            {
                                rowResult = await _repo.GetPmsDrillCoreAsync(
                                    config.DbConnectionString, coreSp, year, def, dayWindow, ct);
                            }
                            else
                            {
                                var rowMetric = def.HasCondition ? "Billable" : "Samples";
                                rowResult = await _repo.GetLisDrillCoreAsync(
                                    config.DbConnectionString, coreSp, rowMetric, year, def, dayWindow, ct);
                            }
                        }
                        else
                        {
                            dayWindow = refined;
                        }
                    }

                    // Prefer the live ES grid heading when the URL carried it;
                    // fall back to LisDrillRowDef.RowTitle.
                    rowResult.RowTitleOverride =
                        gridRowTitle ?? def.RowTitle;
                    rowResult.BackUrl          = backUrl;
                    rowResult.SelectedValue    = value;
                    rowResult.AnalysisRange    = analysisRange;
                    rowResult.ComparableDayWindow = dayWindow;
                    var (_, _, rowLimsRunId)   = await runInfoTask;
                    rowResult.LimsRunId        = rowLimsRunId;

                    PhiExecutiveSummaryViewModel? esPrefetch = null;
                    if (esPrefetchTask is not null)
                        esPrefetch = await esPrefetchTask;

                    // Total Billed (Claims): companion "Billed Mismatches" from ES
                    // summary (same PMS grid / pmsgrid numbers as Index).
                    if (def.IsPmsTotalBilledClaims
                        && string.IsNullOrWhiteSpace(rowResult.ErrorMessage))
                    {
                        _repo.ApplyPmsBilledMismatchFromSummary(rowResult, esPrefetch, year);
                    }

                    // Billed Mismatch formula row: always map ES monthly columns
                    // into drill Summary / Monthly / N-day (same as Index cell).
                    if (titleLooksMismatch
                        && string.IsNullOrWhiteSpace(rowResult.ErrorMessage))
                    {
                        rowResult.RowTitleOverride ??= gridRowTitle ?? def.RowTitle;
                        _repo.ApplyPmsMismatchDrillFromSummary(
                            rowResult, esPrefetch, year, rowCode);
                    }

                    // Fully Paid: companion "Fully Paid Rate vs. Billed Claims"
                    // from ES summary Fully Paid ÷ Billed (Claims) rows.
                    if ((def.IsPmsFullyPaid || titleLooksFullyPaid)
                        && string.IsNullOrWhiteSpace(rowResult.ErrorMessage))
                    {
                        rowResult.IsPmsFullyPaidDrill = true;
                        rowResult.DescriptionOverride =
                            "Claims fully paid by insurance with no remaining balance.";
                        _repo.ApplyPmsFullyPaidRateFromSummary(
                            rowResult, esPrefetch, year, labName);
                        if (!rowResult.HasFullyPaidRate)
                            _repo.FillFullyPaidRateFromDrillSets(rowResult);
                        _repo.EnsureFullyPaidInsurerPanels(rowResult);
                    }

                    // Parent rows with ES subcategories (Other Samples, …): build stacked
                    // StatusBreakdown from children. Skip when Core already stacked
                    // (Insurance Balance Sec1/2/3) so we never wait on the ES SP.
                    if (mayNeedSubcategoryStack
                        && string.IsNullOrWhiteSpace(rowResult.ErrorMessage))
                    {
                        if (esPrefetch is null
                            && _repo.NeedsEsStackOrPanelBackfill(rowResult))
                        {
                            esPrefetch = await _repo.PrefetchExecutiveSummaryForDrillAsync(
                                config.DbConnectionString, prefix, labName, year, ct);
                        }

                        if (esPrefetch is not null)
                        {
                            _repo.ApplyEsSubcategoryStackFromSummary(
                                rowResult, esPrefetch, year, rowCode, category);
                            // Inhealth (and similar): Core may miss LRNPanelName → "All Panels".
                            // Rebuild By-Panel from ES panel sub-rows under the parent.
                            _repo.ApplyEsPanelsFromSummary(
                                rowResult, esPrefetch, year, rowCode, category);
                        }
                    }

                    // Drop months after WeekRange end (bad future DOS → Aug/Dec stubs).
                    if (string.IsNullOrWhiteSpace(rowResult.ErrorMessage))
                        _repo.ApplyWeekRangeAsOfCutoff(rowResult, analysisRange);

                    return View("LisDrill", rowResult);
                }

                // Core SP missing — still serve mismatch from ES so the formula cell
                // is not a claim-filter dead-end.
                if (def.IsPmsMismatch
                    || ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(def.RowTitle)
                    || ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(gridRowTitle))
                {
                    var esOnly = await _repo.PrefetchExecutiveSummaryForDrillAsync(
                        config.DbConnectionString, prefix, labName, year, ct);
                    var mismatchVm = new ExecSummaryLisDrillViewModel
                    {
                        Metric = "Billable",
                        Year = year,
                        SourceLabel = "ClaimLevelData",
                        ComparableDayWindow = dayWindow,
                        IsPmsMismatchDrill = true,
                        RowTitleOverride = gridRowTitle ?? def.RowTitle,
                        SelectedValue = value,
                        BackUrl = backUrl,
                        AnalysisRange = analysisRange,
                    };
                    _repo.ApplyPmsMismatchDrillFromSummary(mismatchVm, esOnly, year, rowCode);
                    var (_, _, limsRunIdMis) = await _repo.GetRunInfoAsync(config.DbConnectionString, ct);
                    mismatchVm.LimsRunId = limsRunIdMis;
                    return View("LisDrill", mismatchVm);
                }

                // Row def exists but the matching Core SP was not deployed.
                vm.RowTitleOverride = gridRowTitle ?? def.RowTitle ?? rowCode;
                vm.DescriptionOverride = string.Empty;
                vm.ErrorMessage = def.IsCash
                    ? $"Cash drill SP '{coreSp}' is not deployed for '{labName}'. Redeploy usp_GetExecutiveSummaryDetail_CashDrill.sql."
                    : $"Drill SP '{coreSp}' is not deployed for '{labName}' yet.";
                return View("LisDrill", vm);
            }

            // rowCode present but no LisDrillRowDef — ES-only mismatch when the
            // URL title / category clearly identify a formula row.
            if (string.Equals(category, "PMS", StringComparison.OrdinalIgnoreCase)
                && ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(gridRowTitle))
            {
                var esOnly = await _repo.PrefetchExecutiveSummaryForDrillAsync(
                    config.DbConnectionString, prefix, labName, year, ct);
                var mismatchVm = new ExecSummaryLisDrillViewModel
                {
                    Metric = "Billable",
                    Year = year,
                    SourceLabel = "ClaimLevelData",
                    ComparableDayWindow = dayWindow,
                    IsPmsMismatchDrill = true,
                    RowTitleOverride = gridRowTitle,
                    SelectedValue = value,
                    BackUrl = backUrl,
                    AnalysisRange = analysisRange,
                };
                _repo.ApplyPmsMismatchDrillFromSummary(mismatchVm, esOnly, year, rowCode);
                var (_, _, limsRunIdMis2) = await _repo.GetRunInfoAsync(config.DbConnectionString, ct);
                mismatchVm.LimsRunId = limsRunIdMis2;
                return View("LisDrill", mismatchVm);
            }

            // rowCode drill requested but not configured for this lab — say so
            // rather than silently showing the wrong (default) metric.
            vm.RowTitleOverride = gridRowTitle ?? rowCode;
            vm.DescriptionOverride = string.Empty; // suppress generic Samples blurb
            vm.ErrorMessage = string.Equals(category, "Cash", StringComparison.OrdinalIgnoreCase)
                ? $"Cash row '{rowCode}' isn't seeded for '{labName}'. Redeploy LisDrillRowDef_Cash.sql (Source=Cash)."
                : $"This breakdown row isn't set up for drill-through for '{labName}' yet.";
            return View("LisDrill", vm);
        }

        // Prefer the lab-specific wrapper (exact Executive Summary parity);
        // fall back to the generic auto-detecting procedure.
        const string genericSp = "dbo.usp_GetExecutiveSummaryDetail_LisDrill";
        var perLabSp = $"dbo.usp_Get{prefix}_ExecutiveSummaryDetail_LisDrill";

        string drillSp;
        if (await _repo.StoredProcedureExistsAsync(config.DbConnectionString, perLabSp, ct))
            drillSp = perLabSp;
        else if (await _repo.StoredProcedureExistsAsync(config.DbConnectionString, genericSp, ct))
            drillSp = genericSp;
        else
        {
            vm.ErrorMessage =
                $"Drill-through data is not available yet. Neither '{perLabSp}' nor '{genericSp}' exists.";
            return View("LisDrill", vm);
        }

        var result = await _repo.GetLisDrillAsync(config.DbConnectionString, drillSp, metric, year, dayWindow, ct);

        // Only re-query Core when WeekFolder was unparsed (provisional window).
        if (fromFolder <= 0 && string.IsNullOrWhiteSpace(result.ErrorMessage))
        {
            var refinedMetric = AnalysisRangeInfo.ResolveComparableDayWindow(
                analysisRange.WeekFolder, result.Summary.CutoffDate, fallback: 9);
            if (refinedMetric != dayWindow)
            {
                dayWindow = refinedMetric;
                result = await _repo.GetLisDrillAsync(
                    config.DbConnectionString, drillSp, metric, year, dayWindow, ct);
            }
            else
            {
                dayWindow = refinedMetric;
            }
        }

        result.BackUrl       = backUrl;
        result.SelectedValue = value;
        result.ComparableDayWindow = dayWindow;

        // Run/analysis-range banner (Billed Week Range + ReportId + Inserted Date),
        // same source as the Executive Summary header, plus the LIMSMaster RunId.
        result.AnalysisRange = analysisRange;
        var (_, _, limsRunId) = await _repo.GetRunInfoAsync(config.DbConnectionString, ct);
        result.LimsRunId = limsRunId;

        if (string.IsNullOrWhiteSpace(result.ErrorMessage))
            _repo.ApplyWeekRangeAsOfCutoff(result, analysisRange);

        return View("LisDrill", result);
    }

    /// <summary>
    /// Three-Pillar Diagnostic — phase 1 LIS Breakdown.
    /// Trailing months (3/6/9/12) + WeekRange end-day comparable window
    /// (same logic as Executive Summary Insights DayWindow).
    /// URL: /ExecutiveSummary/ThreePillarDiagnostic?lab=Beech_Tree&amp;months=6
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> ThreePillarDiagnostic(
        string? lab,
        int?    months = null,
        int?    year = null, // legacy querystring; ignored when months is set
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var labName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        // Allowed trailing windows (doc / Insights style).
        var allowed = new[] { 3, 6, 9, 12, 19 };
        var trailingMonths = months is int m && allowed.Contains(m) ? m : 12;

        ViewData["Title"]             = "Three-Pillar Diagnostic";
        ViewData["SelectedLab"]       = labName;
        ViewData["DisableLabSwitch"]  = true;
        ViewData["BreadcrumbParent"]    = "Executive Summary";
        ViewData["BreadcrumbParentUrl"] = Url.Action("Index", "ExecutiveSummary", new { lab = labName });

        var backUrl = Url.Action("Index", "ExecutiveSummary", new { lab = labName }) ?? "/ExecutiveSummary";
        var vm = new ExecSummaryThreePillarViewModel
        {
            LabName = labName,
            TrailingMonths = trailingMonths,
            Year = year ?? 0,
            BackUrl = backUrl,
        };

        var isBeechTree = string.Equals(labName, "Beech_Tree", StringComparison.OrdinalIgnoreCase);
        if (!isBeechTree)
        {
            vm.ErrorMessage =
                $"This diagnostic view is a Beech_Tree prototype pending client review — not yet available for '{labName}'.";
            return View(vm);
        }

        if (!_labSettings.Labs.TryGetValue(labName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            vm.ErrorMessage = "Lab not configured.";
            return View(vm);
        }

        // Same WeekRange end / DayWindow resolution as LisDrill / Insights.
        var analysisRange = await _analysisRange.GetAsync(config.DbConnectionString, ct);
        ViewData["AnalysisRange"] = analysisRange;
        var asOf = analysisRange.WeekRangeEndDate?.Date ?? DateTime.Today.Date;
        var dayWindow = AnalysisRangeInfo.ResolveComparableDayWindow(
            analysisRange.WeekFolder, asOf, fallback: 9);

        vm.AsOfDate = asOf;
        vm.DayWindow = dayWindow;
        vm.WeekFolder = analysisRange.WeekFolder;

        // JSON snapshots are written by ClaimLineCSVDataCapture for agent insight
        // generation. The UI keeps the existing stored-procedure path.
        const string lisSp = "dbo.usp_GetBeechTree_ThreePillarLisDiagnostic";
        if (!await _repo.StoredProcedureExistsAsync(config.DbConnectionString, lisSp, ct))
        {
            vm.ErrorMessage =
                $"'{lisSp}' has not been deployed yet. Run SqlScripts/usp_GetBeechTree_ThreePillarLisDiagnostic.sql against the Beech_Tree lab database.";
            return View(vm);
        }

        vm = await _repo.GetBeechTreeThreePillarLisAsync(
            config.DbConnectionString, labName, trailingMonths, dayWindow, asOf, ct);
        vm.BackUrl = backUrl;
        vm.WeekFolder = analysisRange.WeekFolder;
        vm.AsOfDate ??= asOf;
        if (vm.DayWindow <= 0) vm.DayWindow = dayWindow;
        if (vm.TrailingMonths <= 0) vm.TrailingMonths = trailingMonths;
        return View(vm);
    }

    /// <summary>
    /// Lazy-load fragment for Pillar 2 (PMS). Called when the PMS tab is clicked.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> ThreePillarPmsPartial(
        string? lab, int? months = null, CancellationToken ct = default)
    {
        var vm = await BuildThreePillarShellAsync(lab, months, ct);
        if (!string.IsNullOrWhiteSpace(vm.ErrorMessage))
            return PartialView("_ThreePillarPms", vm);

        if (!_labSettings.Labs.TryGetValue(vm.LabName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            vm.ErrorMessage = "Lab not configured.";
            return PartialView("_ThreePillarPms", vm);
        }

        const string sp = "dbo.usp_GetBeechTree_ThreePillarPmsDiagnostic";
        if (!await _repo.StoredProcedureExistsAsync(config.DbConnectionString, sp, ct))
        {
            vm.ErrorMessage =
                $"'{sp}' has not been deployed yet. Run SqlScripts/usp_GetBeechTree_ThreePillarPmsDiagnostic.sql against the Beech_Tree lab database, then click this tab again.";
            return PartialView("_ThreePillarPms", vm);
        }

        var asOf = vm.AsOfDate ?? DateTime.Today.Date;
        var dayWindow = vm.DayWindow > 0 ? vm.DayWindow : 9;
        vm = await _repo.GetBeechTreeThreePillarPmsAsync(
            config.DbConnectionString, vm.LabName, vm.TrailingMonths, dayWindow, asOf, ct);
        return PartialView("_ThreePillarPms", vm);
    }

    /// <summary>
    /// Lazy-load fragment for Pillar 3 (Cash). Called when the Cash tab is clicked.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> ThreePillarCashPartial(
        string? lab, int? months = null, CancellationToken ct = default)
    {
        var vm = await BuildThreePillarShellAsync(lab, months, ct);
        if (!string.IsNullOrWhiteSpace(vm.ErrorMessage))
            return PartialView("_ThreePillarCash", vm);

        if (!_labSettings.Labs.TryGetValue(vm.LabName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            vm.ErrorMessage = "Lab not configured.";
            return PartialView("_ThreePillarCash", vm);
        }

        const string sp = "dbo.usp_GetBeechTree_ThreePillarCashDiagnostic";
        if (!await _repo.StoredProcedureExistsAsync(config.DbConnectionString, sp, ct))
        {
            vm.ErrorMessage =
                $"'{sp}' has not been deployed yet. Run SqlScripts/usp_GetBeechTree_ThreePillarCashDiagnostic.sql against the Beech_Tree lab database, then click this tab again.";
            return PartialView("_ThreePillarCash", vm);
        }

        vm = await _repo.GetBeechTreeThreePillarCashAsync(
            config.DbConnectionString, vm.LabName, vm.TrailingMonths, vm.DayWindow, vm.AsOfDate, ct);
        vm.CashLoaded = true;
        return PartialView("_ThreePillarCash", vm);
    }

    private async Task<ExecSummaryThreePillarViewModel> BuildThreePillarShellAsync(
        string? lab, int? months, CancellationToken ct)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var labName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        var allowed = new[] { 3, 6, 9, 12, 19 };
        var trailingMonths = months is int m && allowed.Contains(m) ? m : 12;
        var vm = new ExecSummaryThreePillarViewModel
        {
            LabName = labName,
            TrailingMonths = trailingMonths,
        };

        if (!string.Equals(labName, "Beech_Tree", StringComparison.OrdinalIgnoreCase))
        {
            vm.ErrorMessage =
                $"This diagnostic view is a Beech_Tree prototype — not yet available for '{labName}'.";
            return vm;
        }

        if (!_labSettings.Labs.TryGetValue(labName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            vm.ErrorMessage = "Lab not configured.";
            return vm;
        }

        var analysisRange = await _analysisRange.GetAsync(config.DbConnectionString, ct);
        var asOf = analysisRange.WeekRangeEndDate?.Date ?? DateTime.Today.Date;
        vm.AsOfDate = asOf;
        vm.DayWindow = AnalysisRangeInfo.ResolveComparableDayWindow(
            analysisRange.WeekFolder, asOf, fallback: 9);
        vm.WeekFolder = analysisRange.WeekFolder;
        return vm;
    }
}
