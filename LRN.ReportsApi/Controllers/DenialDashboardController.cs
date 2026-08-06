using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

// Denial Dashboard data endpoints. The LabMetricsDashboard web app used to run this SQL itself;
// it now calls these endpoints so all Denial Dashboard database access lives here.
[ApiController]
[Route("api/denial-dashboard")]
public sealed class DenialDashboardController : ControllerBase
{
    private readonly IDenialDashboardRepository _repository;

    public DenialDashboardController(IDenialDashboardRepository repository)
    {
        _repository = repository;
    }

    [HttpGet("health")]
    public IActionResult Health() => Ok("LRN.ReportsApi DenialDashboard running");

    [HttpGet("labs")]
    public async Task<ActionResult<IReadOnlyList<LabOption>>> GetLabs(CancellationToken cancellationToken)
        => Ok(await _repository.GetLabsAsync(cancellationToken));

    [HttpGet("current-run")]
    public async Task<ActionResult<CurrentRunResponse>> GetCurrentRun([FromQuery] int labId, CancellationToken cancellationToken)
        => Ok(new CurrentRunResponse { RunId = await _repository.GetCurrentRunIdAsync(labId, cancellationToken) });

    [HttpGet("run-info")]
    public async Task<ActionResult<DenialRunInfo>> GetRunInfo([FromQuery] int labId, CancellationToken cancellationToken)
        => Ok(await _repository.GetRunInfoAsync(labId, cancellationToken));

    [HttpGet("records")]
    public async Task<ActionResult<IReadOnlyList<DenialRecord>>> GetRecords([FromQuery] int labId, CancellationToken cancellationToken)
        => Ok(await _repository.GetByLabAsync(labId, cancellationToken));

    [HttpGet("insights")]
    public async Task<ActionResult<IReadOnlyList<DenialInsightRecord>>> GetInsights([FromQuery] int labId, CancellationToken cancellationToken)
        => Ok(await _repository.GetInsightTableByLabAsync(labId, cancellationToken));

    [HttpGet("autocomplete")]
    public async Task<ActionResult<DenialFilterAutocompleteOptions>> GetAutocomplete([FromQuery] int labId, CancellationToken cancellationToken)
        => Ok(await _repository.GetFilterAutocompleteOptionsAsync(labId, cancellationToken));

    [HttpPost("line-items")]
    public async Task<ActionResult<IReadOnlyList<DenialLineItemRecord>>> GetLineItems([FromQuery] int labId, [FromQuery] int page, [FromQuery] int pageSize, [FromBody] DenialDashboardFilters filters, CancellationToken cancellationToken)
        => Ok(await _repository.GetLineItemsByLabAsync(labId, page, pageSize, filters ?? new DenialDashboardFilters(), cancellationToken));

    [HttpPost("line-items/count")]
    public async Task<ActionResult<CountResponse>> GetLineItemCount([FromQuery] int labId, [FromBody] DenialDashboardFilters filters, CancellationToken cancellationToken)
        => Ok(new CountResponse { Count = await _repository.GetLineItemCountByLabAsync(labId, filters ?? new DenialDashboardFilters(), cancellationToken) });

    [HttpPost("line-items/export")]
    public async Task<ActionResult<IReadOnlyList<DenialLineItemRecord>>> GetLineItemsForExport([FromQuery] int labId, [FromBody] DenialDashboardFilters filters, CancellationToken cancellationToken)
        => Ok(await _repository.GetLineItemsForExportByLabAsync(labId, filters ?? new DenialDashboardFilters(), cancellationToken));

    [HttpPost("breakdown-source")]
    public async Task<ActionResult<IReadOnlyList<DenialBreakdownSourceRecord>>> GetBreakdownSource([FromQuery] int labId, [FromBody] DenialDashboardFilters filters, CancellationToken cancellationToken)
        => Ok(await _repository.GetBreakdownSourceByLabAsync(labId, filters ?? new DenialDashboardFilters(), cancellationToken));

    [HttpPost("assign-insight")]
    public async Task<ActionResult<RowsAffectedResponse>> AssignInsight([FromBody] AssignInsightRequest request, CancellationToken cancellationToken)
    {
        if (request is null) return BadRequest(new { message = "Request body is required." });
        var rows = await _repository.AssignReviewerByInsightAsync(request.LabId, request.DenialCode ?? string.Empty, request.PayerName ?? string.Empty, request.ReviewerUserName ?? string.Empty, request.RunId, cancellationToken);
        return Ok(new RowsAffectedResponse { RowsAffected = rows });
    }

    [HttpPost("update-task")]
    public async Task<ActionResult<RowsAffectedResponse>> UpdateTask([FromBody] UpdateReviewerTaskRequest request, CancellationToken cancellationToken)
    {
        if (request is null) return BadRequest(new { message = "Request body is required." });
        var rows = await _repository.UpdateReviewerTaskAsync(request.LabId, request.TaskId ?? string.Empty, request.Status ?? string.Empty, request.Comments ?? string.Empty, request.ReviewerUserName ?? string.Empty, request.RunId, cancellationToken);
        return Ok(new RowsAffectedResponse { RowsAffected = rows });
    }

    [HttpPost("task-board/update")]
    public async Task<ActionResult<TaskBoardUploadResult>> UpdateTaskBoard([FromQuery] int labId, [FromBody] List<TaskBoardCsvUpdate> updates, CancellationToken cancellationToken)
        => Ok(await _repository.UpdateTaskBoardAsync(labId, updates ?? new List<TaskBoardCsvUpdate>(), cancellationToken));

    public sealed class CurrentRunResponse
    {
        public string? RunId { get; set; }
    }

    public sealed class CountResponse
    {
        public int Count { get; set; }
    }

    public sealed class RowsAffectedResponse
    {
        public int RowsAffected { get; set; }
    }

    public sealed class AssignInsightRequest
    {
        public int LabId { get; set; }
        public string? DenialCode { get; set; }
        public string? PayerName { get; set; }
        public string? ReviewerUserName { get; set; }
        public string? RunId { get; set; }
    }

    public sealed class UpdateReviewerTaskRequest
    {
        public int LabId { get; set; }
        public string? TaskId { get; set; }
        public string? Status { get; set; }
        public string? Comments { get; set; }
        public string? ReviewerUserName { get; set; }
        public string? RunId { get; set; }
    }
}
