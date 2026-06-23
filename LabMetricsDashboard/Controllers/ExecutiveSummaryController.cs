using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

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
    private readonly ILogger<ExecutiveSummaryController> _logger;

    // Maps LabSettings key → SP prefix used to build "dbo.usp_Get{prefix}_ExecutiveSummary".
    // Keep aligned with PhiExecutiveSummaryController.LabPrefixMap.
    private static readonly Dictionary<string, string> LabPrefixMap =
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
            ["Beech_Tree"]       = "BT",
        };

    public ExecutiveSummaryController(
        LabSettings labSettings,
        SqlPhiExecutiveSummaryRepository repo,
        ILogger<ExecutiveSummaryController> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
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
        // New extended filter params (wired to SP for Cove only)
        DateTime? dosFrom      = null,
        DateTime? dosTo        = null,
        DateTime? receivedFrom = null,
        DateTime? receivedTo   = null,
        DateTime? billedFrom   = null,
        DateTime? billedTo     = null,
        DateTime? postedFrom   = null,
        DateTime? postedTo     = null,
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
            ReceivedFrom = receivedFrom,
            ReceivedTo   = receivedTo,
            BilledFrom   = billedFrom,
            BilledTo     = billedTo,
            PostedFrom   = postedFrom,
            PostedTo     = postedTo,
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
            receivedFrom: receivedFrom,
            receivedTo:   receivedTo,
            billedFrom:   billedFrom,
            billedTo:     billedTo,
            postedFrom:   postedFrom,
            postedTo:     postedTo,
            panels:       panelsStr,
            clinics:      clinicsStr,
            providers:    providersStr,
            reps:         repsStr,
            ct: ct);

        if (vm.AvailableYears.Count == 0)
            vm.AvailableYears = availableYears;

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
            "ExecutiveSummary view rendered for lab='{Lab}' SP='{Sp}' rows={Rows} cols={Cols}",
            labName, spName, vm.Rows.Count, vm.YearMonthColumns.Count);

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
}
