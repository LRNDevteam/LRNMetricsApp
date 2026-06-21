using System.Security.Claims;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

[ApiController]
[Route("api/denialworkflow/denial-action-verification")]
[Route("api/denial-workflow/denial-action-verification")]
public sealed class DenialActionVerificationController : ControllerBase
{
    private readonly IDenialActionChangeVerificationRepository _repo;
    private readonly IDenialWorkflowService _workflowService;

    public DenialActionVerificationController(IDenialActionChangeVerificationRepository repo, IDenialWorkflowService workflowService)
    {
        _repo = repo;
        _workflowService = workflowService;
    }

    [HttpGet]
    public async Task<ActionResult<PagedResult<DenialActionChangeVerification>>> ReadVerificationItems([FromQuery] DenialActionChangeQuery query, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (query.LabId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(query.LabId, ct)) return LabAccessDenied();
        return Ok(await _repo.GetVerificationItemsAsync(query, ct));
    }

    [HttpGet("batch/{batchId:long}")]
    public async Task<ActionResult<DenialActionChangeBatch>> Batch([FromRoute] long batchId, [FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        var batch = await _repo.GetBatchAsync(labId, batchId, ct);
        return batch is null ? NotFound(new { message = "Verification batch was not found." }) : Ok(batch);
    }

    [HttpGet("lookups")]
    public async Task<ActionResult<DenialActionChangeLookups>> Lookups([FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        return Ok(await _repo.GetLookupsAsync(labId, ct));
    }

    [HttpPost("{verificationId:long}/confirm")]
    public async Task<ActionResult<DenialActionChangeResult>> Confirm([FromRoute] long verificationId, [FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        return Ok(await _repo.ConfirmAsync(labId, verificationId, CurrentUserName(), ct));
    }

    [HttpPost("confirm-selected")]
    public async Task<ActionResult<DenialActionChangeResult>> ConfirmSelected([FromQuery] int labId, [FromBody] IReadOnlyList<long> verificationIds, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        if (verificationIds.Count == 0) return BadRequest(new { message = "Select at least one verification row." });
        return Ok(await _repo.ConfirmSelectedAsync(labId, verificationIds, CurrentUserName(), ct));
    }

    [HttpPost("batch/{batchId:long}/confirm-all")]
    public async Task<ActionResult<DenialActionChangeResult>> ConfirmAll([FromRoute] long batchId, [FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        return Ok(await _repo.ConfirmAllAsync(labId, batchId, CurrentUserName(), ct));
    }

    [HttpPost("{verificationId:long}/ignore")]
    public async Task<ActionResult<DenialActionChangeResult>> Ignore([FromRoute] long verificationId, [FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        return Ok(await _repo.IgnoreAsync(labId, verificationId, CurrentUserName(), ct));
    }

    [HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] DenialActionChangeQuery query, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (query.LabId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(query.LabId, ct)) return LabAccessDenied();
        var bytes = await _repo.ExportAsync(query, ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"Denial_Action_Change_Verification_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    private ActionResult AccessDenied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Action Change Verification is available only for AR Manager." });
    private ActionResult LabAccessDenied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. You can verify denial actions only for your assigned lab." });

    private async Task<bool> CanAccessLabAsync(int labId, CancellationToken ct)
    {
        if (IsAdminFromToken()) return true;
        var tokenLabIds = User.Claims
            .Where(c => string.Equals(c.Type, "lab_id", StringComparison.OrdinalIgnoreCase))
            .Select(c => int.TryParse(c.Value, out var id) ? id : 0)
            .Where(id => id > 0)
            .ToHashSet();
        if (tokenLabIds.Count > 0) return tokenLabIds.Contains(labId);

        var labs = await _workflowService.GetLabsForUserAsync(CurrentUserName(), ct);
        return labs.Any(lab => lab.LabId == labId);
    }

    private bool IsAdminFromToken()
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        var token = new string((role ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        return token.Contains("ADMIN");
    }

    private bool IsArManagerFromToken()
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        var token = new string((role ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        return token.Contains("ARMANAGER") || token.Contains("ADMIN");
    }

    private string CurrentUserName() => FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow";

    private string? FirstClaim(params string[] names)
    {
        foreach (var name in names)
        {
            var value = User.Claims.FirstOrDefault(c => string.Equals(c.Type, name, StringComparison.OrdinalIgnoreCase))?.Value;
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }
        return null;
    }
}
