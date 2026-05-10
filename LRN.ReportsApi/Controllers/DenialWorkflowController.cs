using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

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

    [HttpGet("summary")]
    public async Task<ActionResult<DenialWorkflowSummary>> Summary([FromQuery] int labId, [FromQuery] string role = "", [FromQuery] string userName = "", CancellationToken ct = default)
        => Ok(await _service.GetSummaryAsync(labId, role, userName, ct));

    [HttpGet("reviewer-summary")]
    public async Task<ActionResult<IReadOnlyList<ReviewerWorkflowSummaryRow>>> ReviewerSummary([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetReviewerSummaryAsync(Normalize(filter), ct));

    [HttpGet("insights")]
    public async Task<ActionResult<PagedResult<DenialWorkflowInsightRow>>> Insights([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetInsightsAsync(Normalize(filter), ct));

    [HttpGet("tasks")]
    public async Task<ActionResult<PagedResult<WorkflowTaskRow>>> Tasks([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetTasksAsync(Normalize(filter), ct));

    [HttpGet("verification")]
    public async Task<ActionResult<PagedResult<VerificationTaskRow>>> Verification([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetVerificationAsync(Normalize(filter), ct));

    [HttpPost("assign-insight")]
    public async Task<ActionResult<DenialWorkflowResult>> AssignByInsight(AssignInsightRequest request, CancellationToken ct)
    {
        var rows = await _service.AssignByInsightAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Assigned successfully." : "No matching task found." });
    }

    [HttpPost("update-task")]
    public async Task<ActionResult<DenialWorkflowResult>> UpdateTask(UpdateTaskRequest request, CancellationToken ct)
    {
        var rows = await _service.UpdateTaskAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Task updated." : "Task update failed." });
    }

    [HttpPost("decide-verification")]
    public async Task<ActionResult<DenialWorkflowResult>> VerificationDecision(VerificationDecisionRequest request, CancellationToken ct)
    {
        var rows = await _service.DecideVerificationAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Verification saved." : "Verification update failed." });
    }

    private static DenialWorkflowFilter Normalize(DenialWorkflowFilter filter)
    {
        if (filter.Page <= 0) filter.Page = 1;
        filter.PageSize = 100;
        return filter;
    }
}
