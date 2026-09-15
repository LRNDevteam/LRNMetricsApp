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
    private readonly IDenialDashboardSnapshotRepository _snapshotRepository;
    private readonly IDenialDashboardSnapshotService _snapshotService;

    public DenialDashboardController(IDenialDashboardRepository repository, IDenialDashboardSnapshotRepository snapshotRepository, IDenialDashboardSnapshotService snapshotService)
    {
        _repository = repository;
        _snapshotRepository = snapshotRepository;
        _snapshotService = snapshotService;
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

    [HttpPost("insight-details")]
    public async Task<ActionResult<RowsAffectedResponse>> UpdateInsightDetails([FromBody] UpdateInsightDetailsRequest request, CancellationToken cancellationToken)
    {
        if (request is null) return BadRequest(new { message = "Request body is required." });
        var rows = await _repository.UpdateInsightDetailsAsync(
            request.LabId, request.DenialCode ?? string.Empty, request.PayerName ?? string.Empty,
            request.FeedbackHtml, request.Responsibility, request.DiscussionDate, request.Eta, request.RunId, cancellationToken);
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

    [HttpGet("snapshots")]
    public async Task<ActionResult<IReadOnlyList<DenialDashboardSnapshotInfo>>> GetSnapshots([FromQuery] int labId, [FromQuery] bool includeArchived, CancellationToken cancellationToken)
        => Ok(await _snapshotRepository.GetSnapshotsAsync(labId, includeArchived, cancellationToken));

    [HttpGet("snapshots/period-exists")]
    public async Task<ActionResult<ExistsResponse>> SnapshotPeriodExists([FromQuery] int labId, [FromQuery] string periodType, [FromQuery] DateTime periodStart, CancellationToken cancellationToken)
        => Ok(new ExistsResponse { Exists = await _snapshotRepository.PeriodSnapshotExistsAsync(labId, periodType, periodStart, cancellationToken) });

    /// <summary>Stores a snapshot LabMetricsDashboard already built (it owns the workbook builder) and applies retention.</summary>
    [HttpPost("snapshots")]
    public async Task<ActionResult<DenialDashboardSnapshotInfo>> SaveSnapshot([FromQuery] int labId, [FromBody] DenialDashboardSnapshotUploadRequest request, CancellationToken cancellationToken)
    {
        if (request is null || request.Content is null || request.Content.Length == 0)
            return BadRequest(new { message = "Snapshot content is required." });

        var info = await _snapshotService.SaveSnapshotAsync(labId, request, cancellationToken);
        return info is null
            ? Conflict(new { message = "A snapshot for this period already exists." })
            : Ok(info);
    }

    [HttpGet("snapshots/{snapshotId:long}/download")]
    public async Task<IActionResult> DownloadSnapshot([FromRoute] long snapshotId, [FromQuery] int labId, CancellationToken cancellationToken)
    {
        var file = await _snapshotRepository.GetSnapshotFileAsync(labId, snapshotId, cancellationToken);
        return file is null
            ? NotFound(new { message = "Snapshot was not found." })
            : File(file.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", file.FileName);
    }

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

    public sealed class ExistsResponse
    {
        public bool Exists { get; set; }
    }

    public sealed class AssignInsightRequest
    {
        public int LabId { get; set; }
        public string? DenialCode { get; set; }
        public string? PayerName { get; set; }
        public string? ReviewerUserName { get; set; }
        public string? RunId { get; set; }
    }

    public sealed class UpdateInsightDetailsRequest
    {
        public int LabId { get; set; }
        public string? DenialCode { get; set; }
        public string? PayerName { get; set; }
        public string? FeedbackHtml { get; set; }
        public string? Responsibility { get; set; }
        public DateTime? DiscussionDate { get; set; }
        public string? Eta { get; set; }
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
