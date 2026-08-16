using System.Security.Claims;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Analytics &gt; CPT &amp; Panel Lookup — a single view-only screen backed by
/// LRN.ReportsApi over four LRNMaster tables: dbo.CPTAverage and dbo.PanelAverage
/// (averages) plus dbo.LabModes and dbo.LabMedians (mode/median rates).
///
/// This replaces the previous separate Modes and Median list pages; both data
/// sets now appear as rate columns on the CPT tab of this screen.
/// </summary>
[Authorize]
public sealed class AnalyticsController : Controller
{
    private readonly ILabAnalyticsApiClient _api;
    private readonly UserReportService _reports;
    private readonly ILogger<AnalyticsController> _logger;

    public AnalyticsController(
        ILabAnalyticsApiClient api,
        UserReportService reports,
        ILogger<AnalyticsController> logger)
    {
        _api     = api;
        _reports = reports;
        _logger  = logger;
    }

    // GET /Analytics/CptLookup
    [HttpGet]
    public IActionResult CptLookup()
    {
        ViewData["PageLabel"] = "CPT & Panel Lookup";
        return View(new CptLookupPageViewModel
        {
            CptDataUrl = Url.Action(nameof(CptData)) ?? string.Empty,
            PanelDataUrl = Url.Action(nameof(PanelData)) ?? string.Empty,
            CptWindowsUrl = Url.Action(nameof(CptWindows)) ?? string.Empty,
            PanelWindowsUrl = Url.Action(nameof(PanelWindows)) ?? string.Empty,
            CptOptionsUrl = Url.Action(nameof(CptOptions)) ?? string.Empty,
            PanelOptionsUrl = Url.Action(nameof(PanelOptions)) ?? string.Empty,
            CptExportUrl = Url.Action(nameof(ExportCpt)) ?? string.Empty,
            PanelExportUrl = Url.Action(nameof(ExportPanel)) ?? string.Empty,
            LabsUrl = Url.Action(nameof(LookupLabs)) ?? string.Empty,
            QueueExportUrl = Url.Action(nameof(QueueExport)) ?? string.Empty,
            BackgroundExportEnabled = _reports.SharedReportLab is not null
        });
    }

    [HttpGet]
    public async Task<IActionResult> CptData(CancellationToken ct)
        => Json(await _api.GetCptLookupAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> PanelData(CancellationToken ct)
        => Json(await _api.GetPanelLookupAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> CptWindows(CancellationToken ct)
        => Json(await _api.GetCptWindowsAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> PanelWindows(CancellationToken ct)
        => Json(await _api.GetPanelWindowsAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> CptOptions(CancellationToken ct)
        => Json(await _api.GetCptOptionsAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> PanelOptions(CancellationToken ct)
        => Json(await _api.GetPanelOptionsAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> LookupLabs(CancellationToken ct)
        => Json(await _api.GetLabsAsync(ct));

    [HttpGet]
    public async Task<IActionResult> ExportCpt(CancellationToken ct)
    {
        var result = await _api.ExportCptAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }

    [HttpGet]
    public async Task<IActionResult> ExportPanel(CancellationToken ct)
    {
        var result = await _api.ExportPanelAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }

    /// <summary>
    /// POST /Analytics/QueueExport — hands the export to LRN.ReportWorker and returns immediately.
    ///
    /// Building this workbook inline (ExportCpt / ExportPanel above) has to finish inside the
    /// dashboard's 120s HttpClient timeout; an export with no lab and no window filter does not,
    /// and the user got a TaskCanceledException rather than a file. Queued, the same work runs
    /// without a request clock and lands in the Reports panel.
    ///
    /// Queued against the SHARED lab, not a real one: the data is LRNMaster-wide and the Lab
    /// filter is optional, so no single lab owns the job.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> QueueExport([FromForm] string? tab, CancellationToken ct)
    {
        var lab = _reports.SharedReportLab;
        if (lab is null)
            return BadRequest(new { message = "Background export is not configured. Use the direct download instead." });

        var panel = string.Equals(tab, "panel", StringComparison.OrdinalIgnoreCase);
        var labId = int.TryParse(Request.Query["labId"], out var id) ? id : (int?)null;

        // Resolve the lab's display name for the file name; LabId alone would not name the file.
        string? labName = null;
        if (labId is not null)
        {
            try
            {
                labName = (await _api.GetLabsAsync(ct))
                    .FirstOrDefault(l => l.LabId == labId)?.LabName;
            }
            catch (Exception ex)
            {
                // Cosmetic only — the export still runs, the file is just named by id.
                _logger.LogWarning(ex, "Could not resolve lab name for LabId {LabId}; queuing anyway.", labId);
            }
        }

        var filters = new CptLookupReportFilters(
            CptCode:       Blank(Request.Query["cptCode"]),
            PanelName:     Blank(Request.Query["panelName"]),
            Payer:         Blank(Request.Query["payer"]),
            WindowType:    Blank(Request.Query["windowType"]),
            LabId:         labId,
            SortColumn:    Blank(Request.Query["sortColumn"]),
            SortDirection: Blank(Request.Query["sortDirection"]),
            LabName:       labName);

        try
        {
            var reportId = await _reports.QueueAsync(
                lab,
                panel ? ReportTypes.PanelLookup : ReportTypes.CptLookup,
                User.Identity?.Name ?? string.Empty,
                int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null,
                filters.ToJson(),
                ct);

            return Json(new { reportId, status = "Queued" });
        }
        catch (DuplicateReportRequestException)
        {
            return Conflict(new { message = "This export is already being generated for you. Check the Reports badge." });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 208 or 2812)
        {
            // 208 = invalid object name (UserReqReports not deployed to LRNMaster)
            // 2812 = queue stored procedures missing.
            // 400 rather than 500 on purpose: the page treats 400 as "queue unavailable" and
            // falls back to the direct download, so the user still gets a file.
            _logger.LogError(ex,
                "CPT/Panel export queue failed on lab {Lab}: report queue objects are not deployed there.", lab);
            return BadRequest(new { message = "The report queue is not available. Downloading directly instead." });
        }

        static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
    }
}
