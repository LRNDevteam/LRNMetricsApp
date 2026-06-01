using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// All Labs Collection Summary — Excel export across every configured lab.
///
/// Behaviour:
/// <list type="bullet">
///   <item>
///     <b>No active filters</b> — uses the pre-generated <c>.xlsx</c> file located in
///     each lab's <c>CollectionSummaryExcelPath</c> folder (most-recently modified file).
///     Labs without a pre-generated file fall back to a live DB query automatically.
///   </item>
///   <item>
///     <b>Active filters</b> — calls the Collection Summary read SPs via
///     <see cref="ICollectionSummaryRepository"/> for every eligible lab.
///   </item>
///   <item>
///     Raw ClaimLevelData / LineLevelData sheets are omitted for any lab whose row count
///     exceeds 200,000 rows; a notice sheet is included instead.
///   </item>
/// </list>
/// </summary>
public class AllLabsCollectionController : Controller
{
    private readonly LabSettings _labSettings;
    private readonly AllLabsCollectionExcelBuilder _builder;
    private readonly ILogger<AllLabsCollectionController> _logger;

    public AllLabsCollectionController(
        LabSettings labSettings,
        AllLabsCollectionExcelBuilder builder,
        ILogger<AllLabsCollectionController> logger)
    {
        _labSettings = labSettings;
        _builder     = builder;
        _logger      = logger;
    }

    // ── Index ─────────────────────────────────────────────────────────────────

    /// <summary>GET /AllLabsCollection</summary>
    public IActionResult Index(
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterCheckDateFrom,
        string? filterCheckDateTo)
    {
        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        var eligibleLabs = _labSettings.Labs
            .Where(kv => kv.Value.EnableCollectionReport
                      && kv.Value.LineClaimEnable
                      && !string.IsNullOrWhiteSpace(kv.Value.DbConnectionString))
            .Select(kv => kv.Key)
            .OrderBy(x => x)
            .ToList();

        var vm = new AllLabsCollectionViewModel
        {
            EligibleLabs        = eligibleLabs,
            FilterPayerNames    = filterPayerNames,
            FilterPanelNames    = filterPanelNames,
            FilterFirstBillFrom = filterFirstBillFrom,
            FilterFirstBillTo   = filterFirstBillTo,
            FilterDosFrom       = filterDosFrom,
            FilterDosTo         = filterDosTo,
            FilterCheckDateFrom = filterCheckDateFrom,
            FilterCheckDateTo   = filterCheckDateTo,
        };

        return View(vm);
    }

    // ── Excel Export ──────────────────────────────────────────────────────────

    /// <summary>
    /// GET /AllLabsCollection/ExportExcel — builds and streams the combined workbook.
    /// </summary>
    public async Task<IActionResult> ExportExcel(
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
        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        try
        {
            var stream = await _builder.BuildAsync(
                _labSettings.Labs,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                filterFirstBillFrom, filterFirstBillTo,
                filterDosFrom, filterDosTo,
                filterCheckDateFrom, filterCheckDateTo,
                ct);

            var fileName = $"AllLabs_CollectionSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            // Signal the browser that the download is ready (reuses the same cookie the
            // single-lab export uses so the existing JS progress overlay works).
            Response.Cookies.Append("csExportDone", "1", new CookieOptions
            {
                Path      = "/",
                HttpOnly  = false,
                SameSite  = SameSiteMode.Lax,
                MaxAge    = TimeSpan.FromSeconds(30),
            });

            return File(
                stream,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "AllLabsCollection Excel export failed.");
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(Index), new
            {
                filterPayerNames,
                filterPanelNames,
                filterFirstBillFrom, filterFirstBillTo,
                filterDosFrom, filterDosTo,
                filterCheckDateFrom, filterCheckDateTo,
            });
        }
    }
}
