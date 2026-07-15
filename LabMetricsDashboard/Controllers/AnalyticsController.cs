using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Analytics reference lists backed by LRN.ReportsApi: Modes (dbo.LabModes)
/// and Median (dbo.LabMedians). View-only — no add/edit/delete.
/// </summary>
[Authorize]
public sealed class AnalyticsController : Controller
{
    private readonly ILabAnalyticsApiClient _api;

    public AnalyticsController(ILabAnalyticsApiClient api)
    {
        _api = api;
    }

    private static readonly IReadOnlyList<LabRateColumn> SharedLeadColumns = new[]
    {
        new LabRateColumn("payerName", "Payer Name", "text"),
        new LabRateColumn("panelName", "Panel Name", "text"),
        new LabRateColumn("cptCode", "CPT Code", "text"),
        new LabRateColumn("allowedAmount", "Allowed Amount", "money"),
        new LabRateColumn("insurancePayment", "Insurance Payment", "money"),
        new LabRateColumn("distinctAllowedPaymentCount", "Distinct Allowed Payment Count", "int")
    };

    [HttpGet]
    public IActionResult Modes()
    {
        ViewData["PageLabel"] = "Modes";
        return View("LabRates", new LabRatePageViewModel
        {
            Title = "Modes",
            Subtitle = "Mode allowed and insurance payment amounts by payer, panel, and CPT code. View-only.",
            DataUrl = Url.Action(nameof(ModesData)) ?? string.Empty,
            LabsUrl = Url.Action(nameof(RateLabs)) ?? string.Empty,
            ExportUrl = Url.Action(nameof(ExportModes)) ?? string.Empty,
            OptionsUrl = Url.Action(nameof(ModesOptions)) ?? string.Empty,
            Columns = SharedLeadColumns.Concat(new[]
            {
                new LabRateColumn("modeAllowedAmount", "Mode Allowed Amount", "money"),
                new LabRateColumn("modeInsurancePaymentAmount", "Mode Insurance Payment", "money"),
                new LabRateColumn("allowedAmountPerUnitMode", "Allowed Amount / Unit (Mode)", "money"),
                new LabRateColumn("insurancePaymentPerUnitMode", "Insurance Payment / Unit (Mode)", "money"),
                new LabRateColumn("labName", "Lab", "text")
            }).ToList()
        });
    }

    [HttpGet]
    public IActionResult Median()
    {
        ViewData["PageLabel"] = "Median";
        return View("LabRates", new LabRatePageViewModel
        {
            Title = "Median",
            Subtitle = "Median allowed and insurance payment amounts by payer, panel, and CPT code. View-only.",
            DataUrl = Url.Action(nameof(MedianData)) ?? string.Empty,
            LabsUrl = Url.Action(nameof(RateLabs)) ?? string.Empty,
            ExportUrl = Url.Action(nameof(ExportMedian)) ?? string.Empty,
            OptionsUrl = Url.Action(nameof(MedianOptions)) ?? string.Empty,
            Columns = SharedLeadColumns.Concat(new[]
            {
                new LabRateColumn("medianAllowedAmount", "Median Allowed Amount", "money"),
                new LabRateColumn("medianInsurancePaymentAmount", "Median Insurance Payment", "money"),
                new LabRateColumn("allowedAmountPerUnitMedian", "Allowed Amount / Unit (Median)", "money"),
                new LabRateColumn("insurancePaymentPerUnitMedian", "Insurance Payment / Unit (Median)", "money"),
                new LabRateColumn("labName", "Lab", "text")
            }).ToList()
        });
    }

    [HttpGet]
    public async Task<IActionResult> ModesData(CancellationToken ct)
        => Json(await _api.GetModesAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> MedianData(CancellationToken ct)
        => Json(await _api.GetMediansAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> RateLabs(CancellationToken ct)
        => Json(await _api.GetLabsAsync(ct));

    [HttpGet]
    public async Task<IActionResult> ModesOptions(CancellationToken ct)
        => Json(await _api.GetModeOptionsAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> MedianOptions(CancellationToken ct)
        => Json(await _api.GetMedianOptionsAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> ExportModes(CancellationToken ct)
    {
        var result = await _api.ExportModesAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }

    [HttpGet]
    public async Task<IActionResult> ExportMedian(CancellationToken ct)
    {
        var result = await _api.ExportMediansAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }
}
