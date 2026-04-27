using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class CodingController : Controller
{
    private readonly LabSettings _labSettings;
    private readonly ICodingValidationRepository _repo;
    private readonly ILogger<CodingController> _logger;

    public CodingController(
        LabSettings labSettings,
        ICodingValidationRepository repo,
        ILogger<CodingController> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
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

        // Resolve the DB lab name (may differ from the config key)
        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        var (insights, summaries, wtdInsights, wtdSummaries, financial, detail, fetchError) =
            await FetchDataAsync(connStr, dbLabName, ct);

        return View(new CodingSummaryViewModel
        {
            LabName        = selectedLab,
            AvailableLabs  = availableLabs,
            InsightRows    = insights,
            SummaryRows    = summaries,
            WtdInsightRows = wtdInsights,
            WtdSummaryRows = wtdSummaries,
            FinancialRows  = financial,
            DetailRows     = detail,
            ErrorMessage   = fetchError,
        });
    }

    /// <summary>
    /// Downloads the current Coding Summary data as a formatted Excel file.
    /// </summary>
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
                await FetchDataAsync(connStr, dbLabName, ct);

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
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_CodingSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            // Signal the client-side progress overlay (csExportDone cookie) so it
            // can stop polling and close once the file download starts.
            Response.Cookies.Append("csExportDone", "1", new CookieOptions
            {
                Path = "/",
                HttpOnly = false,
                SameSite = SameSiteMode.Lax,
                MaxAge = TimeSpan.FromSeconds(30),
            });

            return File(
                stream.ToArray(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Coding Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(Summary), new { lab });
        }
    }

    private async Task<(List<CodingInsightRow> Insights, List<CodingSummaryRow> Summaries,
                         List<CodingWtdInsightRow> WtdInsights, List<CodingWtdSummaryRow> WtdSummaries,
                         List<CodingFinancialSummaryRow> Financial,
                         List<CodingValidationDetailRow> Detail,
                         string? Error)>
        FetchDataAsync(string connStr, string labName, CancellationToken ct)
    {

        try
        {
            var t1 = _repo.GetYtdInsightsAsync(connStr, labName, ct);
            var t2 = _repo.GetYtdSummaryAsync(connStr, labName, ct);
            var t3 = _repo.GetWtdInsightsAsync(connStr, labName, ct);
            var t4 = _repo.GetWtdSummaryAsync(connStr, labName, ct);
            var t5 = _repo.GetFinancialSummaryAsync(connStr, ct);
            var t6 = _repo.GetValidationDetailRowsAsync(connStr, ct);
            await Task.WhenAll(t1, t2, t3, t4, t5, t6);
            return (t1.Result, t2.Result, t3.Result, t4.Result, t5.Result, t6.Result, null);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "FetchDataAsync failed for lab '{LabName}'.", labName);
            return ([], [], [], [], [], [], ex.Message);
        }
    }
}
