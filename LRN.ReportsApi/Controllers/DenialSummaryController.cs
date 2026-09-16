using System.Security.Claims;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Denial Summary observations (spec 4a-4d) and snapshots (4g-4i).
///
/// Anyone who can open the lab's Denial Summary can read both. Writing an observation or taking a
/// snapshot is AR Manager / Admin only, the same people who can assign from that page.
/// </summary>
[ApiController]
[Route("api/denialworkflow/denial-summary")]
[Route("api/denial-workflow/denial-summary")]
public sealed class DenialSummaryController : ControllerBase
{
    internal const int MaxResponsiblePersonLength = 200;
    internal const int MaxSummaryKeyLength = 255;

    private const string ExcelContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private readonly IDenialSummaryRepository _repo;
    private readonly IDenialSummarySnapshotService _snapshots;
    private readonly IDenialWorkflowService _workflowService;

    public DenialSummaryController(IDenialSummaryRepository repo, IDenialSummarySnapshotService snapshots, IDenialWorkflowService workflowService)
    {
        _repo = repo;
        _snapshots = snapshots;
        _workflowService = workflowService;
    }

    [HttpGet("observations")]
    public async Task<ActionResult<IReadOnlyList<DenialSummaryObservation>>> GetObservations([FromQuery] int labId, CancellationToken ct)
    {
        var denied = await GuardReadAsync(labId, ct);
        if (denied != null) return denied;
        return Ok(await _repo.GetObservationsAsync(labId, ct));
    }

    [HttpPut("observations")]
    public async Task<ActionResult<DenialSummaryObservationSaveResult>> SaveObservation([FromQuery] int labId, [FromBody] DenialSummaryObservationRequest request, CancellationToken ct)
    {
        var denied = await GuardWriteAsync(labId, ct);
        if (denied != null) return denied;

        var error = NormalizeAndValidate(request);
        if (error != null) return BadRequest(new { message = error });

        var result = await _repo.SaveObservationAsync(labId, request, CurrentUserName(), ct);
        return result.Conflict
            ? Conflict(new { message = "Someone else updated this observation. The latest version has been loaded; reapply your change.", observation = result.Observation })
            : Ok(result);
    }

    [HttpGet("snapshots")]
    public async Task<ActionResult<IReadOnlyList<DenialSummarySnapshotInfo>>> GetSnapshots([FromQuery] int labId, [FromQuery] bool includeArchived = false, CancellationToken ct = default)
    {
        var denied = await GuardReadAsync(labId, ct);
        if (denied != null) return denied;
        return Ok(await _repo.GetSnapshotsAsync(labId, includeArchived, ct));
    }

    /// <summary>On-demand snapshot of the lab's current summary.</summary>
    [HttpPost("snapshots")]
    public async Task<ActionResult<DenialSummarySnapshotInfo>> TakeSnapshot([FromQuery] int labId, CancellationToken ct)
    {
        var denied = await GuardWriteAsync(labId, ct);
        if (denied != null) return denied;

        var today = _snapshots.Today();
        var info = await _snapshots.CreateSnapshotAsync(labId, DenialSummarySnapshotPeriodTypes.OnDemand, today, today, CurrentUserName(), ct);
        return info is null
            ? Conflict(new { message = "The snapshot could not be saved. Try again." })
            : Ok(info);
    }

    [HttpGet("snapshots/{snapshotId:long}/download")]
    public async Task<IActionResult> DownloadSnapshot([FromRoute] long snapshotId, [FromQuery] int labId, CancellationToken ct)
    {
        var denied = await GuardReadAsync(labId, ct);
        if (denied != null) return denied;

        var file = await _repo.GetSnapshotFileAsync(labId, snapshotId, ct);
        return file is null
            ? NotFound(new { message = "Snapshot was not found." })
            : File(file.Content, ExcelContentType, file.FileName);
    }

    /// <summary>Trims and checks a save request in place. Returns the error message, or null when valid.</summary>
    internal static string? NormalizeAndValidate(DenialSummaryObservationRequest request)
    {
        var summaryType = DenialSummaryTypes.Canonical(request.SummaryType);
        if (summaryType is null) return "Summary type must be Classification or ActionCategory.";
        request.SummaryType = summaryType;

        request.SummaryKey = (request.SummaryKey ?? string.Empty).Trim();
        if (request.SummaryKey.Length == 0) return "Summary row is required.";
        if (request.SummaryKey.Length > MaxSummaryKeyLength) return $"Summary row name cannot exceed {MaxSummaryKeyLength} characters.";

        request.ResponsiblePerson = string.IsNullOrWhiteSpace(request.ResponsiblePerson) ? null : request.ResponsiblePerson.Trim();
        if (request.ResponsiblePerson?.Length > MaxResponsiblePersonLength) return $"Responsible Person cannot exceed {MaxResponsiblePersonLength} characters.";

        request.ObservationHtml = DenialSummaryHtml.Sanitize(request.ObservationHtml);
        if (request.ObservationHtml?.Length > DenialSummaryHtml.MaxSanitizedLength) return "Observation is too long.";

        foreach (var (label, value) in new[]
        {
            ("Observation Date", request.ObservationDate),
            ("Target Date", request.TargetDate),
            ("Follow-up Date", request.FollowUpDate),
            ("Completed Date", request.CompletedDate)
        })
        {
            if (value.HasValue && (value.Value.Year < 2000 || value.Value.Year > 2100)) return $"{label} is not a valid date.";
        }

        request.ObservationDate = request.ObservationDate?.Date;
        request.TargetDate = request.TargetDate?.Date;
        request.FollowUpDate = request.FollowUpDate?.Date;
        request.CompletedDate = request.CompletedDate?.Date;

        if (request.ObservationDate.HasValue && request.CompletedDate.HasValue && request.CompletedDate < request.ObservationDate)
            return "Completed Date cannot be before the Observation Date.";

        return null;
    }

    internal static bool CanWriteRole(string? role)
    {
        var token = new string((role ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        // Lab User is otherwise read-only across the Denial Workflow app (see
        // DenialWorkflowController.DenyWriteForLabUser and its callers), but is explicitly given
        // write access to just this page's Observations - scoped to this one controller, not a
        // change to DenyWriteForLabUser's broader read-only policy.
        return token.Contains("ADMIN") || token.Contains("ARMANAGER") || token.Contains("LABUSER");
    }

    private async Task<ActionResult?> GuardReadAsync(int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        if (!await CanAccessLabAsync(labId, ct))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. You can view the Denial Summary only for your assigned lab." });
        return null;
    }

    private async Task<ActionResult?> GuardWriteAsync(int labId, CancellationToken ct)
    {
        if (!CanWriteRole(FirstClaim(ClaimTypes.Role, "role", "roles")))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Only AR Manager or Admin can update the Denial Summary." });
        return await GuardReadAsync(labId, ct);
    }

    private async Task<bool> CanAccessLabAsync(int labId, CancellationToken ct)
    {
        var tokenLabIds = User.Claims
            .Where(c => string.Equals(c.Type, "lab_id", StringComparison.OrdinalIgnoreCase))
            .Select(c => int.TryParse(c.Value, out var id) ? id : 0)
            .Where(id => id > 0)
            .ToHashSet();
        if (tokenLabIds.Count > 0) return tokenLabIds.Contains(labId);

        var labs = await _workflowService.GetLabsForUserAsync(CurrentUserName(), ct);
        return labs.Any(lab => lab.LabId == labId);
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
