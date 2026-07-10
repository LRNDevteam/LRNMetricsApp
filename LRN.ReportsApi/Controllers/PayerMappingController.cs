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

    public PayerMappingController(IPayerMappingService mapping)
    {
        _mapping = mapping;
    }

    private bool CanView => PayerMasterRoles.CanViewLab(User);
    // Mapping confirmations write directly (Global Payer ID + alias + audit), so they follow the
    // same authority as other direct Lab writes; approval-routed roles use the legacy confirm flow.
    private bool CanMap => PayerMasterRoles.CanWriteLab(User) && !PayerMasterRoles.LabRequiresApproval(User);
    private string UserName() => PayerMasterRoles.UserName(User);

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

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Your role does not permit this action on the Lab Insurance Master." });
}
