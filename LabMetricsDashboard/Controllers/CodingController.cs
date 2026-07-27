using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;

namespace LabMetricsDashboard.Controllers;

public class CodingController : Controller
{
    private static readonly TimeSpan CodingCacheDuration = TimeSpan.FromMinutes(5);

    private readonly LabSettings _labSettings;
    private readonly ICodingValidationRepository _repo;
    private readonly LabCsvFileResolver _fileResolver;
    private readonly IMemoryCache _cache;
    private readonly ILogger<CodingController> _logger;

    public CodingController(
        LabSettings labSettings,
        ICodingValidationRepository repo,
        LabCsvFileResolver fileResolver,
        IMemoryCache cache,
        ILogger<CodingController> logger)
    {
        _labSettings  = labSettings;
        _repo         = repo;
        _fileResolver = fileResolver;
        _cache        = cache;
        _logger       = logger;
    }

    /// <summary>GET /Coding/Summary?lab=PCRLabsofAmerica</summary>
    public async Task<IActionResult> Summary(string? lab, CancellationToken ct)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (string.IsNullOrWhiteSpace(selectedLab))
            return View(new CodingSummaryViewModel { AvailableLabs = availableLabs });

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var config))
        {
            return View(new CodingSummaryViewModel
            {
                LabName       = selectedLab,
                AvailableLabs = availableLabs,
                ErrorMessage  = $"Configuration not found for {selectedLab}.",
            });
        }

        if (!config.EnableCoding)
        {
            return View(new CodingSummaryViewModel
            {
                LabName       = selectedLab,
                AvailableLabs = availableLabs,
                ErrorMessage  = $"Coding Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
            });
        }

        if (!config.DBEnabled)
        {
            return View(new CodingSummaryViewModel
            {
                LabName       = selectedLab,
                AvailableLabs = availableLabs,
                ErrorMessage  = $"Coding Summary is currently not available for {selectedLab}. Please contact your administrator for more details.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return View(new CodingSummaryViewModel
            {
                LabName       = selectedLab,
                AvailableLabs = availableLabs,
                ErrorMessage  = $"Coding Summary is currently not available for {selectedLab}. Please contact your administrator for more details.",
            });
        }

        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        // Initial page: summary tabs + KPIs only. Heavy insight/detail tabs load on first click.
        var (summaries, wtdSummaries, financial, fetchError) =
            await FetchInitialDataAsync(connStr, selectedLab, dbLabName, ct);

        return View(new CodingSummaryViewModel
        {
            LabName               = selectedLab,
            AvailableLabs         = availableLabs,
            SummaryRows           = summaries,
            WtdSummaryRows        = wtdSummaries,
            FinancialRows         = financial,
            ErrorMessage          = fetchError,
            PackageAverageFiles   = !string.IsNullOrWhiteSpace(config.Avgs),
        });
    }

    /// <summary>Lazy-load YTD or WTD Coding Insights tab content (heavy CPT pill rendering).</summary>
    [HttpGet]
    public async Task<IActionResult> InsightsPane(string? lab, string type, CancellationToken ct)
    {
        var availableLabs = _labSettings.Labs.Keys.ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.EnableCoding
            || !config.DBEnabled
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return NotFound();

        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;
        var connStr   = config.DbConnectionString;

        try
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            if (string.Equals(type, "ytd", StringComparison.OrdinalIgnoreCase))
            {
                var insights = await GetCachedAsync(
                    $"Coding_YtdInsights_{selectedLab}",
                    () => _repo.GetYtdInsightsAsync(connStr, dbLabName, ct));
                sw.Stop();
                _logger.LogInformation(
                    "InsightsPane YTD for '{Lab}' {Count} rows in {Ms} ms.",
                    selectedLab, insights.Count, sw.ElapsedMilliseconds);
                return PartialView("_YtdCodingInsightsPane", new CodingSummaryViewModel
                {
                    LabName     = selectedLab,
                    InsightRows = insights,
                });
            }

            if (string.Equals(type, "wtd", StringComparison.OrdinalIgnoreCase))
            {
                var wtdInsights = await GetCachedAsync(
                    $"Coding_WtdInsights_{selectedLab}",
                    () => _repo.GetWtdInsightsAsync(connStr, dbLabName, ct));
                sw.Stop();
                _logger.LogInformation(
                    "InsightsPane WTD for '{Lab}' {Count} rows in {Ms} ms.",
                    selectedLab, wtdInsights.Count, sw.ElapsedMilliseconds);
                return PartialView("_WtdCodingInsightsPane", new CodingSummaryViewModel
                {
                    LabName        = selectedLab,
                    WtdInsightRows = wtdInsights,
                });
            }

            return BadRequest("Unknown insight type.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "InsightsPane failed for lab '{LabName}' type '{Type}'.", selectedLab, type);
            return Content(
                $"<div class=\"alert alert-danger m-3\">Failed to load insights: {System.Net.WebUtility.HtmlEncode(ex.Message)}</div>",
                "text/html");
        }
    }

    [HttpGet]
    public async Task<IActionResult> DetailPane(string? lab, CancellationToken ct)
    {
        var availableLabs = _labSettings.Labs.Keys.ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.EnableCoding
            || !config.DBEnabled
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return NotFound();

        try
        {
            var detail = await GetCachedAsync(
                $"Coding_Detail_{selectedLab}",
                () => _repo.GetValidationDetailRowsAsync(config.DbConnectionString!, ct));

            return PartialView("_CodingDetailPane", new CodingSummaryViewModel
            {
                LabName    = selectedLab,
                DetailRows = detail,
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "DetailPane failed for lab '{LabName}'.", selectedLab);
            return Content(
                $"<div class=\"alert alert-danger m-3\">Failed to load validation detail: {System.Net.WebUtility.HtmlEncode(ex.Message)}</div>",
                "text/html");
        }
    }

    /// <summary>
    /// Returns a partial view explaining Lost Revenue / Revenue at Risk for one
    /// Year+Panel, Week+Panel, or Financial week row.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> CalculationDetail(
        string? lab,
        string scope = "ytd",
        int? year = null,
        string? week = null,
        string? panel = null,
        string? missing = null,
        string? additional = null,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.EnableCoding
            || !config.DBEnabled
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return NotFound();

        scope = (scope ?? "ytd").Trim().ToLowerInvariant();
        if (scope is not ("ytd" or "wtd" or "financial"))
            return BadRequest("Unknown scope.");

        if (scope == "ytd" && !year.HasValue)
            return BadRequest("Year is required for YTD calculation detail.");
        if ((scope == "wtd" || scope == "financial") && string.IsNullOrWhiteSpace(week))
            return BadRequest("Week is required for WTD/Financial calculation detail.");
        if (scope != "financial" && string.IsNullOrWhiteSpace(panel))
            return BadRequest("Panel is required for this calculation detail.");

        try
        {
            var detail = await _repo.GetCalculationDetailAsync(
                config.DbConnectionString!,
                selectedLab,
                scope,
                year,
                week,
                panel,
                missing,
                additional,
                ct);

            return PartialView("_CodingCalculationDetail", detail);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "CalculationDetail failed for lab '{LabName}'.", selectedLab);
            return Content(
                $"<div class=\"alert alert-danger m-3\">Failed to load calculation: {System.Net.WebUtility.HtmlEncode(ex.Message)}</div>",
                "text/html");
        }
    }

    /// <summary>Downloads the current Coding Summary data as a formatted Excel file.</summary>
    public async Task<IActionResult> ExportCodingExcel(string? lab, CancellationToken ct)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.EnableCoding
            || !config.DBEnabled
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            TempData["ExportError"] = "Coding Summary export is not available for the selected lab.";
            return RedirectToAction(nameof(Summary), new { lab });
        }

        var connStr   = config.DbConnectionString;
        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        try
        {
            var (insights, summaries, wtdInsights, wtdSummaries, financial, detail, fetchError) =
                await FetchAllDataAsync(connStr, selectedLab, dbLabName, ct);

            if (!string.IsNullOrWhiteSpace(fetchError))
            {
                TempData["ExportError"] = $"Export failed: {fetchError}";
                return RedirectToAction(nameof(Summary), new { lab });
            }

            var vm = new CodingSummaryViewModel
            {
                LabName        = selectedLab,
                InsightRows    = insights,
                SummaryRows    = summaries,
                WtdInsightRows = wtdInsights,
                WtdSummaryRows = wtdSummaries,
                FinancialRows  = financial,
                DetailRows     = detail,
            };

            using var workbook = CodingExcelExportBuilder.CreateWorkbook(vm, selectedLab);

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            var excelBytes = stream.ToArray();

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var stamp = DateTime.Now.ToString("yyyyMMddHHmmss");
            var excelName = $"{safeLabName}_CodingSummary_{stamp}.xlsx";

            Response.Cookies.Append("csExportDone", "1", new CookieOptions
            {
                Path = "/",
                HttpOnly = false,
                SameSite = SameSiteMode.Lax,
                MaxAge = TimeSpan.FromSeconds(30),
            });

            // When Avgs is configured (e.g. Cove), package Excel + CptAverage + PanelAverage.
            var averages = _fileResolver.ResolveCodingAverageFiles(selectedLab);
            if (CodingExportPackageBuilder.ShouldPackage(averages))
            {
                var zipBytes = CodingExportPackageBuilder.BuildZip(excelBytes, excelName, averages);
                var zipName = $"{safeLabName}_CodingSummary_{stamp}.zip";
                _logger.LogInformation(
                    "Coding export package for '{Lab}': Excel + Cpt={HasCpt} Panel={HasPanel} week={Week}",
                    selectedLab,
                    !string.IsNullOrWhiteSpace(averages.CptAveragePath),
                    !string.IsNullOrWhiteSpace(averages.PanelAveragePath),
                    averages.WeekFolder);
                return File(zipBytes, "application/zip", zipName);
            }

            return File(
                excelBytes,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                excelName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Coding Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(Summary), new { lab });
        }
    }

    private async Task<(List<CodingSummaryRow> Summaries, List<CodingWtdSummaryRow> WtdSummaries,
                         List<CodingFinancialSummaryRow> Financial, string? Error)>
        FetchInitialDataAsync(string connStr, string cacheLabKey, string dbLabName, CancellationToken ct)
    {
        try
        {
            var total = System.Diagnostics.Stopwatch.StartNew();
            var t1 = Timed("YtdSummary", GetCachedAsync($"Coding_YtdSummary_{cacheLabKey}",
                () => _repo.GetYtdSummaryAsync(connStr, dbLabName, ct)));
            var t2 = Timed("WtdSummary", GetCachedAsync($"Coding_WtdSummary_{cacheLabKey}",
                () => _repo.GetWtdSummaryAsync(connStr, dbLabName, ct)));
            var t3 = Timed("Financial", GetCachedAsync($"Coding_Financial_{cacheLabKey}",
                () => _repo.GetFinancialSummaryAsync(connStr, ct)));
            await Task.WhenAll(t1, t2, t3);
            total.Stop();
            _logger.LogInformation(
                "Coding fetch [Initial] for '{LabName}' took {Ms} ms total.",
                cacheLabKey, total.ElapsedMilliseconds);
            return (t1.Result, t2.Result, t3.Result, null);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "FetchInitialDataAsync failed for lab '{LabName}'.", cacheLabKey);
            return ([], [], [], ex.Message);
        }
    }

    private async Task<(List<CodingInsightRow> Insights, List<CodingSummaryRow> Summaries,
                         List<CodingWtdInsightRow> WtdInsights, List<CodingWtdSummaryRow> WtdSummaries,
                         List<CodingFinancialSummaryRow> Financial,
                         List<CodingValidationDetailRow> Detail,
                         string? Error)>
        FetchAllDataAsync(string connStr, string cacheLabKey, string dbLabName, CancellationToken ct)
    {
        try
        {
            var t1 = GetCachedAsync($"Coding_YtdInsights_{cacheLabKey}", () => _repo.GetYtdInsightsAsync(connStr, dbLabName, ct));
            var t2 = GetCachedAsync($"Coding_YtdSummary_{cacheLabKey}", () => _repo.GetYtdSummaryAsync(connStr, dbLabName, ct));
            var t3 = GetCachedAsync($"Coding_WtdInsights_{cacheLabKey}", () => _repo.GetWtdInsightsAsync(connStr, dbLabName, ct));
            var t4 = GetCachedAsync($"Coding_WtdSummary_{cacheLabKey}", () => _repo.GetWtdSummaryAsync(connStr, dbLabName, ct));
            var t5 = GetCachedAsync($"Coding_Financial_{cacheLabKey}", () => _repo.GetFinancialSummaryAsync(connStr, ct));
            var t6 = GetCachedAsync($"Coding_Detail_{cacheLabKey}", () => _repo.GetValidationDetailRowsAsync(connStr, ct));
            await Task.WhenAll(t1, t2, t3, t4, t5, t6);
            return (t1.Result, t2.Result, t3.Result, t4.Result, t5.Result, t6.Result, null);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "FetchAllDataAsync failed for lab '{LabName}'.", cacheLabKey);
            return ([], [], [], [], [], [], ex.Message);
        }
    }

    private Task<T> GetCachedAsync<T>(string cacheKey, Func<Task<T>> factory) =>
        _cache.GetOrCreateAsync(cacheKey, async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = CodingCacheDuration;
            return await factory();
        })!;

    private async Task<T> Timed<T>(string name, Task<T> task)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var result = await task;
        sw.Stop();
        _logger.LogInformation("Coding fetch [{Dataset}] took {Ms} ms.", name, sw.ElapsedMilliseconds);
        return result;
    }
}
