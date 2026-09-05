using System.Diagnostics;
using System.Security.Claims;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using LRN.ReportsApi.Services.ArReports;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// AR follow-up reporting suite. RPT-01 (AR Follow-up Activity Detail) is the only report live
/// here; the catalog endpoint reports the status of the other eight so the Reports screen is driven
/// by data instead of a hard-coded "coming soon" block.
///
/// Routed under /api/denialworkflow so it inherits the workflow JWT gate in Program.cs. Anything
/// outside that prefix runs with no authentication at all, and this endpoint returns note text.
/// </summary>
[ApiController]
[Route("api/denialworkflow/reports")]
[Route("api/denial-workflow/reports")]
public sealed class ArReportsController : ControllerBase
{
    private const string ReportCode = "RPT-01";

    private readonly IArActivityReportRepository _repository;
    private readonly IDenialWorkflowService _workflowService;
    private readonly ILogger<ArReportsController> _logger;

    public ArReportsController(
        IArActivityReportRepository repository,
        IDenialWorkflowService workflowService,
        ILogger<ArReportsController> logger)
    {
        _repository = repository;
        _workflowService = workflowService;
        _logger = logger;
    }

    // ==================================================================================
    // Catalog
    // ==================================================================================

    [HttpGet("catalog")]
    public async Task<ActionResult<IReadOnlyList<ArReportCatalogItem>>> Catalog([FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        return Ok(await _repository.GetCatalogAsync(labId, ct));
    }

    // ==================================================================================
    // RPT-01
    // ==================================================================================

    [HttpGet("rpt01/filter-options")]
    public async Task<ActionResult<ArActivityFilterOptions>> FilterOptions([FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        return Ok(await _repository.GetFilterOptionsAsync(labId, ct));
    }

    [HttpGet("rpt01")]
    public async Task<ActionResult<ArActivityReportResult>> ActivityDetail([FromQuery] ArActivityReportFilter filter, CancellationToken ct)
    {
        if (filter.LabId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(filter.LabId, ct)) return LabAccessDenied();

        ApplyIdentityScope(filter);
        try
        {
            return Ok(await _repository.GetActivityDetailAsync(filter, ct));
        }
        catch (InvalidOperationException ex)
        {
            // Range/paging validation from the repository. These are user-correctable, so they come
            // back as 400 with the guidance instead of the generic 500 support message.
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpGet("rpt01/timeline")]
    public async Task<ActionResult<IReadOnlyList<ArActivityTimelineRow>>> Timeline(
        [FromQuery] int labId, [FromQuery] string claimId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (string.IsNullOrWhiteSpace(claimId)) return BadRequest(new { message = "ClaimId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();

        var filter = new ArActivityReportFilter { LabId = labId };
        ApplyIdentityScope(filter);
        return Ok(await _repository.GetClaimTimelineAsync(filter, claimId, ct));
    }

    [HttpGet("rpt01/export")]
    public async Task<IActionResult> Export([FromQuery] ArActivityReportFilter filter, CancellationToken ct)
    {
        if (filter.LabId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(filter.LabId, ct)) return LabAccessDenied();
        if (!CanDownloadFromToken()) return StatusCode(StatusCodes.Status403Forbidden, new { message = "This role cannot export AR reports." });

        ApplyIdentityScope(filter);

        // An export must contain EVERY filtered row: a paged export cannot satisfy the spec's
        // reconciliation requirement, and the Reconciliation sheet recomputes the summary from the
        // rows actually written.
        filter.IsExport = true;
        filter.Page = 1;
        filter.PageSize = 0;

        var stopwatch = Stopwatch.StartNew();
        ArActivityReportResult report;
        try
        {
            report = await _repository.GetActivityDetailAsync(filter, ct);
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }

        var bytes = ArActivityReportExcelBuilder.Build(report);
        stopwatch.Stop();

        // The screen run was already logged inside GetActivityDetailAsync; this second row records
        // the export itself, so the run log distinguishes "looked at it" from "took it away".
        await _repository.LogRunAsync(report.Metadata, "Excel", report.Detail.Items.Count, (int)stopwatch.ElapsedMilliseconds, ct);
        _logger.LogInformation("RPT-01 export {RunId} lab {LabId}: {Rows} rows in {Ms}ms",
            report.Metadata.RunId, filter.LabId, report.Detail.Items.Count, stopwatch.ElapsedMilliseconds);

        var fileName = $"RPT01_AR_Followup_Activity_Detail_{report.Metadata.LabName.Replace(' ', '_')}_{DateTime.Now:yyyyMMdd_HHmmss}.xlsx";
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
    }

    // ==================================================================================
    // Saved views (spec section 2.6)
    // ==================================================================================

    [HttpGet("rpt01/saved-views")]
    public async Task<ActionResult<IReadOnlyList<ArReportSavedView>>> SavedViews([FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();
        return Ok(await _repository.GetSavedViewsAsync(ReportCode, labId, CurrentUserName(), ct));
    }

    [HttpPost("rpt01/saved-views")]
    public async Task<ActionResult<ArReportSavedView>> SaveView([FromBody] ArReportSavedViewRequest request, CancellationToken ct)
    {
        if (request.LabId <= 0) return BadRequest(new { message = "LabId is required." });
        if (string.IsNullOrWhiteSpace(request.ViewName)) return BadRequest(new { message = "View name is required." });
        if (request.ViewName.Length > 120) return BadRequest(new { message = "View name must be 120 characters or fewer." });
        if ((request.FiltersJson?.Length ?? 0) > 8000) return BadRequest(new { message = "Saved view is too large." });
        if (!await CanAccessLabAsync(request.LabId, ct)) return LabAccessDenied();

        return Ok(await _repository.SaveViewAsync(ReportCode, CurrentUserName(), request, ct));
    }

    [HttpDelete("rpt01/saved-views/{savedViewId:int}")]
    public async Task<IActionResult> DeleteView([FromRoute] int savedViewId, [FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct)) return LabAccessDenied();

        var removed = await _repository.DeleteSavedViewAsync(ReportCode, labId, CurrentUserName(), savedViewId, ct);
        return removed > 0
            ? Ok(new { success = true, message = "Saved view removed." })
            : NotFound(new { message = "Saved view was not found for this user and lab." });
    }

    // ==================================================================================
    // Identity, scope, role
    // ==================================================================================

    /// <summary>
    /// Role and user name always come from the JWT, never from the query string, and an AR Analyst
    /// is narrowed to their own activity (spec section 3.1 primary audience: "AR Analyst (own
    /// authorized activities)"). Doing this before the repository runs means the restriction is
    /// applied inside the SQL, so paging and the summary measures stay consistent with each other.
    /// </summary>
    private void ApplyIdentityScope(ArActivityReportFilter filter)
    {
        var userName = CurrentUserName();
        filter.UserName = userName;
        filter.Role = FirstClaim(ClaimTypes.Role, "role", "roles") ?? string.Empty;
        filter.IsExport = false;

        if (IsAnalystOnly(filter.Role))
        {
            filter.Analyst = userName;
            filter.Manager = string.Empty;
            filter.Team = string.Empty;
        }
    }

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

    private ObjectResult LabAccessDenied()
        => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. You can run AR reports only for your authorized labs." });

    private static string NormalizeRoleToken(string? value)
        => new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private bool IsAdminFromToken() => NormalizeRoleToken(FirstClaim(ClaimTypes.Role, "role", "roles")).Contains("ADMIN");

    /// <summary>
    /// Mirrors DenialWorkflowController.IsReviewerOnly. Both must agree, or the report offers a
    /// scope the rest of the application refuses.
    /// </summary>
    private static bool IsAnalystOnly(string? role)
    {
        var r = NormalizeRoleToken(role);
        return (r.Contains("REVIEWER") || r.Contains("ANALYST") || r.Contains("ANALYSER") || r.Contains("ANALYZER"))
            && !r.Contains("MANAGER")
            && !r.Contains("ADMIN");
    }

    private bool CanDownloadFromToken()
    {
        var r = NormalizeRoleToken(FirstClaim(ClaimTypes.Role, "role", "roles"));
        // Exporting is reading. Every role that can open the report can take it to a spreadsheet -
        // client-facing roles included, because their export is already masked by the repository.
        return r.Contains("ADMIN") || r.Contains("ARMANAGER") || r.Contains("CLIENTMANAGER")
            || r.Contains("ACCOUNTMANAGER") || r.Contains("LABUSER")
            || IsAnalystOnly(FirstClaim(ClaimTypes.Role, "role", "roles"));
    }

    private string CurrentUserName()
        => FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow";

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
