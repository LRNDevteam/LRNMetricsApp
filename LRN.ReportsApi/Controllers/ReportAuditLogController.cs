using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Report Audit Log - the status of every report in every run, plus that run's info log.
/// Read-only: any role with access to a Master Values screen may view and download the logs.
/// </summary>
[ApiController]
[Route("api/master-values/report-audit-log")]
public sealed class ReportAuditLogController : ControllerBase
{
    private readonly IReportAuditLogService _service;

    public ReportAuditLogController(IReportAuditLogService service) => _service = service;

    private bool CanView => PayerMasterRoles.CanViewLab(User) || PayerMasterRoles.CanViewPolicy(User);

    [HttpGet("runs")]
    public async Task<ActionResult> Runs(
        [FromQuery] string? runId,
        [FromQuery] int? labId,
        [FromQuery] DateTime? fromDate,
        [FromQuery] DateTime? toDate,
        [FromQuery] string? mode,
        [FromQuery] bool includeInactiveReports,
        CancellationToken ct)
    {
        if (!CanView) return Denied();
        var query = new ReportAuditQuery
        {
            RunId = runId,
            LabId = labId,
            FromDate = fromDate,
            ToDate = toDate,
            Mode = mode,
            IncludeInactiveReports = includeInactiveReports
        };
        try { return Ok(await _service.GetRunsAsync(query, ct)); }
        catch (SqlException ex) when (ex.Number == 50000) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpGet("logs")]
    public async Task<ActionResult> Logs(
        [FromQuery] string? runId,
        [FromQuery] string? logType,
        [FromQuery] string? reportType,
        [FromQuery] string? sourceSystem,
        [FromQuery] DateTime? fromDate,
        [FromQuery] DateTime? toDate,
        [FromQuery] bool newest,
        CancellationToken ct)
    {
        if (!CanView) return Denied();
        try { return Ok(await _service.GetLogsAsync(Build(runId, logType, reportType, sourceSystem, fromDate, toDate, newest), ct)); }
        catch (SqlException ex) when (ex.Number == 50000) { return BadRequest(new { message = ex.Message }); }
    }

    /// <summary>CSV of the run's log. Omit <paramref name="logType"/> to download every log type.</summary>
    [HttpGet("logs/export")]
    public async Task<ActionResult> ExportLogs(
        [FromQuery] string? runId,
        [FromQuery] string? logType,
        [FromQuery] string? reportType,
        [FromQuery] string? sourceSystem,
        [FromQuery] DateTime? fromDate,
        [FromQuery] DateTime? toDate,
        [FromQuery] bool newest,
        CancellationToken ct)
    {
        if (!CanView) return Denied();
        try
        {
            var (content, fileName) = await _service.ExportLogsAsync(Build(runId, logType, reportType, sourceSystem, fromDate, toDate, newest), ct);
            return File(content, "text/csv", fileName);
        }
        catch (SqlException ex) when (ex.Number == 50000) { return BadRequest(new { message = ex.Message }); }
    }

    private static ReportRunLogQuery Build(string? runId, string? logType, string? reportType, string? sourceSystem, DateTime? fromDate, DateTime? toDate, bool newest)
        => new()
        {
            RunId = runId,
            LogType = logType,
            ReportType = reportType,
            SourceSystem = sourceSystem,
            FromDate = fromDate,
            ToDate = toDate,
            Newest = newest
        };

    private ActionResult Denied()
        => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Your role does not permit viewing the Report Audit Log." });
}
