using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class PhiExecutiveSummaryController : Controller
{
    private readonly LabSettings _labSettings;
    private readonly SqlPhiExecutiveSummaryRepository _repo;
    private readonly ILogger<PhiExecutiveSummaryController> _logger;

    // Maps LabSettings key → SP prefix (add any new lab here)
    private static readonly Dictionary<string, string> LabPrefixMap =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["Phi_Life"]          = "Phi",
            ["PhiLife"]           = "Phi",
            ["Augustus"]          = "Aug",
            ["Augustus_Labs"]     = "Aug",
            ["Augustus_LRN"]      = "Aug",
            ["Certus"]            = "Cert",
            ["Certus_LRN"]        = "Cert",
            ["Cove"]              = "Cove",
            ["CoveLRN"]           = "Cove",
            ["Elixir"]            = "Elix",
            ["Elixir_LRN"]        = "Elix",
            ["NorthWest"]         = "NW",
            ["NWL"]               = "NW",
            ["PCRLabsofAmerica"]  = "PCR",
            ["PCRLOA"]            = "PCR",
            ["Beech_Tree"]        = "BT",
            ["RisingTides"]       = "RT",
        };

    public PhiExecutiveSummaryController(
        LabSettings labSettings,
        SqlPhiExecutiveSummaryRepository repo,
        ILogger<PhiExecutiveSummaryController> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    public async Task<IActionResult> Index(
        string?  lab,          // matches the cookie key used by LabSelectionHelper
        int?     yearFrom,
        int?     yearTo,
        int?     monthFrom,
        int?     monthTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();

        // Resolve via cookie → query-string → first lab (same logic as all other pages)
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
            emptyVm.ErrorMessage = $"Data not generated for this lab. Executive Summary is not available for '{labName}'.";
            return View(emptyVm);
        }

        var spName  = $"dbo.usp_Get{prefix}_ExecutiveSummary";
        var connStr = config.DbConnectionString;

        bool spExists = await _repo.StoredProcedureExistsAsync(connStr, spName, ct);
        if (!spExists)
        {
            emptyVm.ErrorMessage = $"Data not generated for this lab. The stored procedure '{spName}' does not exist.";
            return View(emptyVm);
        }

        var availableYears = await _repo.GetAvailableYearsAsync(connStr, ct);

        var vm = await _repo.GetExecutiveSummaryAsync(
            connStr, spName, availableLabs, labName,
            yearFrom, yearTo, monthFrom, monthTo, ct: ct);

        if (vm.AvailableYears.Count == 0)
            vm.AvailableYears = availableYears;

        return View(vm);
    }
}
