using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Backend for the Report Control Board landing page: the latest run per lab with every report's
/// status, and the error detail behind a failed cell.
///
/// Read-only and open to any authenticated LRN Metrics user - the board is a landing page, and the
/// dashboard filters the rows down to the labs the signed-in user is assigned to. The JWT itself is
/// still required (see the /api/report-board entry in the auth middleware allow-list in Program.cs).
/// </summary>
[ApiController]
[Route("api/report-board")]
public sealed class ReportBoardController : ControllerBase
{
    private readonly IReportAuditLogService _service;
    private readonly ILogger<ReportBoardController> _logger;

    public ReportBoardController(IReportAuditLogService service, ILogger<ReportBoardController> logger)
    {
        _service = service;
        _logger = logger;
    }

    /// <summary>
    /// One row per lab from usp_ReportsWorkflowTracker_Pivot. The report columns are whatever the
    /// proc returned - the caller must not assume a fixed set or order.
    /// </summary>
    [HttpGet("latest")]
    public async Task<ActionResult> Latest(
        [FromQuery] string? mode,
        [FromQuery] int? labId,
        [FromQuery] bool includeInactiveReports,
        CancellationToken ct)
    {
        var query = new ReportAuditQuery
        {
            // The board is a "where does every lab stand right now" view, so Latest is the default.
            Mode = string.IsNullOrWhiteSpace(mode) ? "Latest" : mode,
            LabId = labId,
            IncludeInactiveReports = includeInactiveReports
        };
        try { return Ok(await _service.GetRunsAsync(query, ct)); }
        catch (SqlException ex) when (ex.Number == 50000) { return BadRequest(new { message = ex.Message }); }
    }

    /// <summary>
    /// Everything known about why a run failed: pipeline failures from LRN_Error_Log plus the run's
    /// Error entries from ReportRunIdInfoLog. Either source being unavailable is reported in the
    /// payload rather than failing the request - the page must still name the run it could not read.
    /// </summary>
    [HttpGet("run-errors")]
    public async Task<ActionResult> RunErrors(
        [FromQuery] string? runId,
        [FromQuery] string? labName,
        [FromQuery] string? reportType,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(runId))
            return BadRequest(new { message = "A run id is required." });

        var warnings = new List<string>();

        IReadOnlyList<PipelineErrorEntry> pipeline = [];
        try { pipeline = await _service.GetPipelineErrorsAsync(runId, labName, ct); }
        catch (SqlException ex)
        {
            _logger.LogWarning(ex, "LRN_Error_Log unavailable for run {RunId}.", runId);
            warnings.Add("The pipeline error log (dbo.LRN_Error_Log) could not be read.");
        }

        IReadOnlyList<ReportRunLogEntry> log = [];
        try
        {
            log = await _service.GetLogsAsync(new ReportRunLogQuery
            {
                RunId = runId,
                LogType = "Error",
                ReportType = reportType,
                Newest = true
            }, ct);
        }
        catch (SqlException ex)
        {
            _logger.LogWarning(ex, "ReportRunIdInfoLog unavailable for run {RunId}.", runId);
            warnings.Add("The run info log (dbo.ReportRunIdInfoLog) could not be read.");
        }

        return Ok(new { runId, labName, reportType, pipelineErrors = pipeline, runLog = log, warnings });
    }
}
