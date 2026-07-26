using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
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

    public AnalyticsController(ILabAnalyticsApiClient api)
    {
        _api = api;
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
            LabsUrl = Url.Action(nameof(LookupLabs)) ?? string.Empty
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
}
