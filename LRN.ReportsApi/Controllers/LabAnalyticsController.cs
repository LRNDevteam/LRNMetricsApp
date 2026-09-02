using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
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
    private readonly ICptLookupRepository _lookup;

    public LabAnalyticsController(ILabAnalyticsRepository repository, ICptLookupRepository lookup)
    {
        _repository = repository;
        _lookup = lookup;
    }

    // ── CPT & Panel Lookup ───────────────────────────────────────────────────
    // Backs the single Analytics > CPT & Panel Lookup screen. The CPT tab joins
    // dbo.CPTAverage to the mode/median rates; the panel tab reads dbo.PanelAverage.

    [HttpGet("cpt-lookup")]
    public async Task<ActionResult<LookupResult<CptLookupRow>>> CptLookup([FromQuery] LookupQuery query, CancellationToken ct)
        => Ok(await _lookup.GetCptAsync(Scoped(query), ct));

    [HttpGet("panel-lookup")]
    public async Task<ActionResult<LookupResult<PanelLookupRow>>> PanelLookup([FromQuery] LookupQuery query, CancellationToken ct)
        => Ok(await _lookup.GetPanelAsync(Scoped(query), ct));

    /// <summary>Every window (YTD / Rolling180 / Rolling90) for one CPT selection — drives the drill-down.</summary>
    [HttpGet("cpt-lookup/windows")]
    public async Task<ActionResult<IReadOnlyList<CptLookupRow>>> CptWindows(
        int labId, string cptCode, string? panelName, string? payer, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(cptCode)) return BadRequest("cptCode is required.");
        if (!CanReadLab(labId)) return LabScopeDenied();
        return Ok(await _lookup.GetCptWindowsAsync(labId, cptCode, panelName, payer, ct));
    }

    [HttpGet("panel-lookup/windows")]
    public async Task<ActionResult<IReadOnlyList<PanelLookupRow>>> PanelWindows(
        int labId, string panelName, string? payer, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(panelName)) return BadRequest("panelName is required.");
        if (!CanReadLab(labId)) return LabScopeDenied();
        return Ok(await _lookup.GetPanelWindowsAsync(labId, panelName, payer, ct));
    }

    [HttpGet("cpt-lookup/options")]
    public async Task<ActionResult<IReadOnlyList<string>>> CptLookupOptions(string? field, string? term, int? labId, CancellationToken ct)
        => Ok(await _lookup.GetCptOptionsAsync(field, term, labId, LabScopeFromToken(), ct));

    [HttpGet("panel-lookup/options")]
    public async Task<ActionResult<IReadOnlyList<string>>> PanelLookupOptions(string? field, string? term, int? labId, CancellationToken ct)
        => Ok(await _lookup.GetPanelOptionsAsync(field, term, labId, LabScopeFromToken(), ct));

    [HttpGet("cpt-lookup/export")]
    public async Task<IActionResult> ExportCptLookup([FromQuery] LookupQuery query, CancellationToken ct)
    {
        var bytes = await _lookup.ExportCptAsync(Scoped(query), ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"CptLookup_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    [HttpGet("panel-lookup/export")]
    public async Task<IActionResult> ExportPanelLookup([FromQuery] LookupQuery query, CancellationToken ct)
    {
        var bytes = await _lookup.ExportPanelAsync(Scoped(query), ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"PanelLookup_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    /// <summary>Labs that have CPTAverage/PanelAverage data, for the lookup screen's lab filter.</summary>
    [HttpGet("lookup-labs")]
    public async Task<ActionResult<IReadOnlyList<MasterValueLabOption>>> LookupLabs(CancellationToken ct)
        => Ok(await _lookup.GetLabsAsync(LabScopeFromToken(), ct));

    // ── Lab scoping ──────────────────────────────────────────────────────────
    // CPTAverage/PanelAverage are LRNMaster-wide: without this, any signed-in user could read
    // every lab's negotiated rates just by clearing the lab filter or editing ?labId=. The
    // ceiling comes from the token's lab_id claims, which the dashboard fills from the user's
    // Assign User Labs mapping - never from the request.

    /// <summary>Labs the caller may read; null for Admin, who is not lab-scoped anywhere else either.</summary>
    private List<int>? LabScopeFromToken()
    {
        if (PayerMasterRoles.IsLrnAdmin(User)) return null;

        return User.Claims
            .Where(c => string.Equals(c.Type, "lab_id", StringComparison.OrdinalIgnoreCase))
            .Select(c => int.TryParse(c.Value, out var id) ? id : 0)
            .Where(id => id > 0)
            .Distinct()
            .ToList();
    }

    private LookupQuery Scoped(LookupQuery query)
    {
        query.AllowedLabIds = LabScopeFromToken();
        return query;
    }

    private bool CanReadLab(int labId)
    {
        var scope = LabScopeFromToken();
        return scope is null || scope.Contains(labId);
    }

    private ActionResult LabScopeDenied() => StatusCode(StatusCodes.Status403Forbidden,
        new { message = "You can view lookup data only for the labs assigned to you." });

    // ── Lab Modes / Lab Medians raw list data ────────────────────────────────

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
