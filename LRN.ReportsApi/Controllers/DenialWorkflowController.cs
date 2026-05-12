using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;
using System.Security.Claims;

namespace LRN.ReportsApi.Controllers;

[ApiController]
[Route("api/denialworkflow")]
[Route("api/denial-workflow")]
public sealed class DenialWorkflowController : ControllerBase
{
    private readonly IDenialWorkflowService _service;
    public DenialWorkflowController(IDenialWorkflowService service) => _service = service;

    [HttpGet("health")]
    public IActionResult Health() => Ok("LRN.ReportsApi DenialWorkflow running");

    [HttpPost("import")]
    public async Task<ActionResult<DenialWorkflowImportResult>> Import(DenialTaskImportRequest request, CancellationToken ct)
    {
        if (request.LabId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(request.RunId)) return BadRequest("RunId is required.");
        return Ok(await _service.ImportAsync(request, ct));
    }

    [HttpGet("me")]
    public async Task<ActionResult<DenialWorkflowUserContext>> Me(CancellationToken ct)
    {
        var userName = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? string.Empty;
        var email = FirstClaim(ClaimTypes.Email, "email") ?? string.Empty;
        var displayName = FirstClaim("display_name", "given_name") ?? userName;
        var role = FirstClaim(ClaimTypes.Role, "role", "roles") ?? string.Empty;
        var labs = await _service.GetLabsForUserAsync(string.IsNullOrWhiteSpace(userName) ? email : userName, ct);
        return Ok(new DenialWorkflowUserContext { UserName = userName, Email = email, DisplayName = displayName, Role = role, Labs = labs });
    }

    [HttpGet("labs")]
    public async Task<ActionResult<IReadOnlyList<DenialWorkflowLabOption>>> Labs(CancellationToken ct)
    {
        var userName = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? FirstClaim(ClaimTypes.Email, "email") ?? string.Empty;
        return Ok(await _service.GetLabsForUserAsync(userName, ct));
    }

    [HttpGet("dashboard")]
    public async Task<ActionResult<DenialWorkflowDashboardSummary>> Dashboard([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetDashboardSummaryAsync(Normalize(filter), ct));

    [HttpGet("filter-options")]
    public async Task<ActionResult<DenialWorkflowFilterOptions>> FilterOptions([FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        return Ok(await _service.GetFilterOptionsAsync(labId, ct));
    }

    [HttpGet("reviewers")]
    public async Task<ActionResult<IReadOnlyList<ReviewerOption>>> Reviewers([FromQuery] int labId = 0, CancellationToken ct = default)
        => Ok(await _service.GetReviewerOptionsAsync(labId, ct));

    [HttpGet("summary")]
    public async Task<ActionResult<DenialWorkflowSummary>> Summary([FromQuery] int labId, [FromQuery] string role = "", [FromQuery] string userName = "", CancellationToken ct = default)
        => Ok(await _service.GetSummaryAsync(labId, role, userName, ct));

    [HttpGet("reviewer-summary")]
    public async Task<ActionResult<IReadOnlyList<ReviewerWorkflowSummaryRow>>> ReviewerSummary([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetReviewerSummaryAsync(Normalize(filter), ct));

    [HttpGet("insights")]
    public async Task<ActionResult<PagedResult<DenialWorkflowInsightRow>>> Insights([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetInsightsAsync(Normalize(filter), ct));

    [HttpGet("claims")]
    [HttpGet("claim-level")]
    public async Task<ActionResult<PagedResult<ClaimLevelRow>>> Claims([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetClaimsAsync(Normalize(filter), ct));

	[HttpGet("claim-tasks")]
	public async Task<ActionResult<IReadOnlyList<WorkflowTaskRow>>> ClaimTasksQuery(
	   [FromQuery] int labId,
	   [FromQuery] string? claimId,
	   CancellationToken ct)
	{
		if (labId <= 0) return BadRequest("LabId is required.");
		if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");

		return Ok(await _service.GetTasksByClaimAsync(labId, claimId.Trim(), ct));
	}

	[HttpGet("claims/{claimId}/tasks")]
	public async Task<ActionResult<IReadOnlyList<WorkflowTaskRow>>> ClaimTasksRoute(
		[FromQuery] int labId,
		[FromRoute] string? claimId,
		CancellationToken ct)
	{
		if (labId <= 0) return BadRequest("LabId is required.");
		if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");

		return Ok(await _service.GetTasksByClaimAsync(labId, claimId.Trim(), ct));
	}

	[HttpGet("tasks")]
    public async Task<ActionResult<PagedResult<WorkflowTaskRow>>> Tasks([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetTasksAsync(Normalize(filter), ct));

    [HttpGet("verification")]
    public async Task<ActionResult<PagedResult<VerificationTaskRow>>> Verification([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetVerificationAsync(Normalize(filter), ct));

    [HttpPost("assign-insight")]
    [HttpPost("assign-by-insight")]
    public async Task<ActionResult<DenialWorkflowResult>> AssignByInsight(AssignInsightRequest request, CancellationToken ct)
    {
        var rows = await _service.AssignByInsightAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Assigned successfully." : "No matching task found." });
    }

    [HttpPost("assign-claims")]
    [HttpPost("assign-by-claim")]
    public async Task<ActionResult<ClaimAssignmentResult>> AssignClaims(AssignClaimRequest request, CancellationToken ct)
    {
        var result = await _service.AssignClaimsAsync(request, ct);
        return Ok(result);
    }

    [HttpPost("update-task")]
    [HttpPost("task/update")]
    public async Task<ActionResult<DenialWorkflowResult>> UpdateTask(UpdateTaskRequest request, CancellationToken ct)
    {
        var rows = await _service.UpdateTaskAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Task updated." : "Task update failed." });
    }

    [HttpPost("decide-verification")]
    [HttpPost("verification/decision")]
    public async Task<ActionResult<DenialWorkflowResult>> VerificationDecision(VerificationDecisionRequest request, CancellationToken ct)
    {
        var rows = await _service.DecideVerificationAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Verification saved." : "Verification update failed." });
    }

    private string? FirstClaim(params string[] names)
    {
        foreach (var name in names)
        {
            var value = User.Claims.FirstOrDefault(c => string.Equals(c.Type, name, StringComparison.OrdinalIgnoreCase))?.Value;
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }
        return null;
    }

    private static DenialWorkflowFilter Normalize(DenialWorkflowFilter filter)
    {
        if (filter.Page <= 0) filter.Page = 1;
        filter.PageSize = filter.PageSize <= 0 ? 50 : Math.Clamp(filter.PageSize, 25, 200);
        return filter;
    }
}
