using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// View-only Analytics list data: Lab Modes and Lab Medians (Meridian).
/// The /api/analytics prefix is JWT-guarded in Program.cs, so every endpoint
/// here requires an authenticated LRN Metrics user; page-level visibility is
/// governed by the dynamic menu on the dashboard side.
/// </summary>
[ApiController]
[Route("api/analytics")]
public sealed class LabAnalyticsController : ControllerBase
{
    private readonly ILabAnalyticsRepository _repository;

    public LabAnalyticsController(ILabAnalyticsRepository repository)
    {
        _repository = repository;
    }

    [HttpGet("lab-modes")]
    public async Task<ActionResult<PagedResult<LabModeDto>>> Modes([FromQuery] LabRateQuery query, CancellationToken ct)
        => Ok(await _repository.GetModesAsync(query, ct));

    [HttpGet("lab-medians")]
    public async Task<ActionResult<PagedResult<LabMedianDto>>> Medians([FromQuery] LabRateQuery query, CancellationToken ct)
        => Ok(await _repository.GetMediansAsync(query, ct));

    [HttpGet("lab-modes/export")]
    public async Task<IActionResult> ExportModes([FromQuery] LabRateQuery query, CancellationToken ct)
    {
        var bytes = await _repository.ExportModesAsync(query, ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"LabModes_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    [HttpGet("lab-medians/export")]
    public async Task<IActionResult> ExportMedians([FromQuery] LabRateQuery query, CancellationToken ct)
    {
        var bytes = await _repository.ExportMediansAsync(query, ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"LabMedians_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    /// <summary>Distinct values for the searchable filter dropdowns (payerName | panelName | cptCode).</summary>
    [HttpGet("lab-modes/options")]
    public async Task<ActionResult<IReadOnlyList<string>>> ModeOptions(string? field, string? term, int? labId, CancellationToken ct)
        => Ok(await _repository.GetModeFilterOptionsAsync(field, term, labId, ct));

    [HttpGet("lab-medians/options")]
    public async Task<ActionResult<IReadOnlyList<string>>> MedianOptions(string? field, string? term, int? labId, CancellationToken ct)
        => Ok(await _repository.GetMedianFilterOptionsAsync(field, term, labId, ct));

    [HttpGet("labs")]
    public async Task<ActionResult<IReadOnlyList<MasterValueLabOption>>> Labs(CancellationToken ct)
        => Ok(await _repository.GetLabsAsync(ct));
}
