using LRN.PayerPolicyMapper.Core.Abstractions;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Global Payer ID mapping intelligence for the Lab Insurance Master: ranked suggestions,
/// ranked typeahead search, and the three explicit mapping actions (Approve / Manual Map / Reject).
/// </summary>
[ApiController]
[Route("api/master-values")]
public sealed class PayerMappingController : ControllerBase
{
    private readonly IPayerMappingService _mapping;
    private readonly IPayerMapperRunRepository _runs;

    public PayerMappingController(IPayerMappingService mapping, IPayerMapperRunRepository runs)
    {
        _mapping = mapping;
        _runs = runs;
    }

    private bool CanView => PayerMasterRoles.CanViewLab(User);
    // Mapping confirmations write directly (Global Payer ID + alias + audit), so they follow the
    // same authority as other direct Lab writes; approval-routed roles use the legacy confirm flow.
    private bool CanMap => PayerMasterRoles.CanWriteLab(User) && !PayerMasterRoles.LabRequiresApproval(User);
    private string UserName() => PayerMasterRoles.UserName(User);

    /// <summary>MappingStatus counts for the notification bell (Mapped / Unmapped / Pending Review / No Match).</summary>
    [HttpGet("insurance-payers/mapping-summary")]
    public async Task<ActionResult<MappingStatusSummaryDto>> MappingSummary(CancellationToken ct)
    {
        if (!CanView) return Denied();
        return Ok(await _mapping.GetMappingSummaryAsync(ct));
    }

    [HttpGet("insurance-payers/{id:int}/suggestions")]
    public async Task<ActionResult<PayerMappingSuggestionsResponse>> Suggestions(int id, CancellationToken ct)
    {
        if (!CanView) return Denied();
        var response = await _mapping.GetSuggestionsAsync(id, ct);
        return response is null ? NotFound(new { message = "Insurance payer was not found." }) : Ok(response);
    }

    /// <summary>Ranked typeahead against the full Payer Policy master (Step 1A+1B + Step 7 scoring, no family filter).</summary>
    [HttpGet("payer-policy-insurance/search")]
    public async Task<ActionResult<IReadOnlyList<PayerPolicySearchResultDto>>> Search([FromQuery] string? q, [FromQuery] int top = 10, CancellationToken ct = default)
    {
        if (!CanView) return Denied();
        if (string.IsNullOrWhiteSpace(q)) return Ok(Array.Empty<PayerPolicySearchResultDto>());
        return Ok(await _mapping.SearchPolicyPayersAsync(q, Math.Clamp(top, 1, 25), ct));
    }

    [HttpPost("insurance-payers/{id:int}/mapping/approve")]
    public async Task<ActionResult<PayerMappingActionResult>> Approve(int id, PayerMappingActionRequest request, CancellationToken ct)
    {
        if (!CanMap) return Denied();
        var result = await _mapping.ApproveAsync(id, request.PPInsuranceMasterId, UserName(), ct);
        return result.Success ? Ok(result) : BadRequest(new { message = result.Message });
    }

    [HttpPost("insurance-payers/{id:int}/mapping/manual")]
    public async Task<ActionResult<PayerMappingActionResult>> ManualMap(int id, PayerMappingActionRequest request, CancellationToken ct)
    {
        if (!CanMap) return Denied();
        var result = await _mapping.ManualMapAsync(id, request.PPInsuranceMasterId, UserName(), ct);
        return result.Success ? Ok(result) : BadRequest(new { message = result.Message });
    }

    [HttpPost("insurance-payers/{id:int}/mapping/reject")]
    public async Task<ActionResult<PayerMappingActionResult>> Reject(int id, CancellationToken ct)
    {
        if (!CanMap) return Denied();
        var result = await _mapping.RejectAsync(id, UserName(), ct);
        return result.Success ? Ok(result) : BadRequest(new { message = result.Message });
    }

    // ── Payer Service Audit: worker run history + manual trigger ──────────────

    /// <summary>Paged list of service runs (guid, trigger, status, timings, outcome counts).</summary>
    [HttpGet("payer-mapper/runs")]
    public async Task<ActionResult> Runs([FromQuery] int page = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (!CanView) return Denied();
        var (runs, totalCount) = await _runs.GetRunsAsync(page, pageSize, ct);
        return Ok(new { items = runs, totalCount, page, pageSize });
    }

    /// <summary>One run + every Lab payer evaluated/updated under it (audit rows carrying the RunId).</summary>
    [HttpGet("payer-mapper/runs/{runId:guid}")]
    public async Task<ActionResult> RunDetails(Guid runId, CancellationToken ct)
    {
        if (!CanView) return Denied();
        var run = await _runs.GetRunAsync(runId, ct);
        if (run is null) return NotFound(new { message = "Run was not found." });
        var details = await _runs.GetRunDetailsAsync(runId, ct);
        return Ok(new { run, details });
    }

    /// <summary>
    /// Queues a manual run (Status='Requested'); the Windows service claims it within one poll
    /// cycle. Scope 'All' re-evaluates every record (mapped rows are revalidated audit-only,
    /// never overwritten); scope 'UnmappedPending' covers Unmapped + Pending Review rows only.
    /// </summary>
    [HttpPost("payer-mapper/runs/trigger")]
    public async Task<ActionResult> TriggerRun(TriggerRunRequest? request, CancellationToken ct)
    {
        if (!CanMap) return Denied();
        var scope = string.Equals(request?.Scope?.Trim(), "All", StringComparison.OrdinalIgnoreCase)
            ? LRN.PayerPolicyMapper.Core.RunScope.All
            : LRN.PayerPolicyMapper.Core.RunScope.UnmappedPending;
        var runId = await _runs.RequestRunAsync(UserName(), scope, ct);
        return Ok(new { runId, scope = scope.ToString(), status = "Requested", message = "Run queued. The Payer Policy Mapper service will pick it up within one poll cycle." });
    }

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Your role does not permit this action on the Lab Insurance Master." });
}
