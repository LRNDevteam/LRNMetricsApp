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

        var labsFromToken = LabsFromToken();
        var labs = labsFromToken.Count > 0
            ? labsFromToken
            : await _service.GetLabsForUserAsync(string.IsNullOrWhiteSpace(userName) ? email : userName, ct);

        return Ok(new DenialWorkflowUserContext { UserName = userName, Email = email, DisplayName = displayName, Role = role, Labs = labs });
    }

    [HttpGet("labs")]
    public async Task<ActionResult<IReadOnlyList<DenialWorkflowLabOption>>> Labs(CancellationToken ct)
    {
        var labsFromToken = LabsFromToken();
        if (labsFromToken.Count > 0) return Ok(labsFromToken);

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

		var rows = await _service.GetTasksByClaimAsync(labId, claimId.Trim(), ct);
		return Ok(ScopeRowsForReviewer(rows));
	}

	[HttpGet("claims/{claimId}/tasks")]
	public async Task<ActionResult<IReadOnlyList<WorkflowTaskRow>>> ClaimTasksRoute(
		[FromQuery] int labId,
		[FromRoute] string? claimId,
		CancellationToken ct)
	{
		if (labId <= 0) return BadRequest("LabId is required.");
		if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");

		var rows = await _service.GetTasksByClaimAsync(labId, claimId.Trim(), ct);
		return Ok(ScopeRowsForReviewer(rows));
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



    [HttpGet("notes")]
    public async Task<ActionResult<IReadOnlyList<DenialNoteRow>>> Notes([FromQuery] int labId, [FromQuery] string claimId, [FromQuery] string? taskId, [FromQuery] string? cptCode, [FromQuery] string noteLevel = "Claim", CancellationToken ct = default)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");
        return Ok(await _service.GetNotesAsync(labId, claimId.Trim(), taskId, cptCode, noteLevel, ct));
    }

    [HttpPost("notes")]
    public async Task<ActionResult<DenialNoteRow>> SaveNote(SaveDenialNoteRequest request, CancellationToken ct)
    {
        if (request.LabId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(request.ClaimId)) return BadRequest("ClaimId is required.");
        if (string.IsNullOrWhiteSpace(request.NoteText)) return BadRequest("Note text is required.");
        request.CreatedBy = string.IsNullOrWhiteSpace(request.CreatedBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : request.CreatedBy;
        return Ok(await _service.SaveNoteAsync(request, ct));
    }

    [HttpGet("claim-documents")]
    public async Task<ActionResult<IReadOnlyList<ClaimDocumentRow>>> ClaimDocuments([FromQuery] int labId, [FromQuery] string claimId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");
        return Ok(await _service.GetClaimDocumentsAsync(labId, claimId.Trim(), ct));
    }

    [HttpPost("claim-documents")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<IReadOnlyList<ClaimDocumentRow>>> UploadClaimDocuments([FromForm] int labId, [FromForm] string claimId, [FromForm] string? comment, [FromForm] string? uploadedBy, [FromForm] List<IFormFile> files, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");
        if (files == null || files.Count == 0) return BadRequest("Select at least one file.");

        uploadedBy = string.IsNullOrWhiteSpace(uploadedBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : uploadedBy;
        var root = Path.Combine(AppContext.BaseDirectory, "ClaimDocuments", labId.ToString(), SafePath(claimId));
        Directory.CreateDirectory(root);
        var saved = new List<ClaimDocumentRow>();
        foreach (var file in files.Where(f => f.Length > 0))
        {
            var ext = Path.GetExtension(file.FileName);
            var stored = $"{Guid.NewGuid():N}{ext}";
            var path = Path.Combine(root, stored);
            await using (var fs = System.IO.File.Create(path)) await file.CopyToAsync(fs, ct);
            saved.Add(await _service.SaveClaimDocumentAsync(new ClaimDocumentRow
            {
                LabId = labId,
                ClaimId = claimId.Trim(),
                OriginalFileName = Path.GetFileName(file.FileName),
                StoredFileName = stored,
                ContentType = file.ContentType ?? "application/octet-stream",
                FileSizeBytes = file.Length,
                FilePath = path,
                Comment = comment ?? string.Empty,
                UploadedBy = uploadedBy ?? "ReactWorkflow"
            }, ct));
        }
        return Ok(saved);
    }

    private static string SafePath(string value)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) value = value.Replace(c, '_');
        return value.Trim();
    }


    [HttpGet("escalations")]
    public async Task<ActionResult<IReadOnlyList<DenialEscalationRow>>> Escalations([FromQuery] int labId, [FromQuery] string claimId, [FromQuery] string? taskId, [FromQuery] string? cptCode, [FromQuery] string escalationLevel = "Claim", CancellationToken ct = default)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");
        return Ok(await _service.GetEscalationsAsync(labId, claimId.Trim(), taskId, cptCode, escalationLevel, ct));
    }

    [HttpPost("escalations")]
    public async Task<ActionResult<DenialEscalationRow>> SaveEscalation(SaveDenialEscalationRequest request, CancellationToken ct)
    {
        if (request.LabId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(request.ClaimId)) return BadRequest("ClaimId is required.");
        if (string.IsNullOrWhiteSpace(request.EscalationReason)) return BadRequest("Escalation reason is required.");
        request.CreatedBy = string.IsNullOrWhiteSpace(request.CreatedBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : request.CreatedBy;
        return Ok(await _service.SaveEscalationAsync(request, ct));
    }

    [HttpPost("decide-verification")]
    [HttpPost("verification/decision")]
    public async Task<ActionResult<DenialWorkflowResult>> VerificationDecision(VerificationDecisionRequest request, CancellationToken ct)
    {
        var rows = await _service.DecideVerificationAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Verification saved." : "Verification update failed." });
    }


    private IReadOnlyList<WorkflowTaskRow> ScopeRowsForReviewer(IReadOnlyList<WorkflowTaskRow> rows)
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles") ?? string.Empty;
        if (!IsReviewerOnly(role)) return rows;

        var userName = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? string.Empty;
        return rows
            .Where(r => string.Equals((r.AssignedTo ?? string.Empty).Trim(), userName.Trim(), StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    private IReadOnlyList<DenialWorkflowLabOption> LabsFromToken()
    {
        var ids = User.Claims.Where(c => string.Equals(c.Type, "lab_id", StringComparison.OrdinalIgnoreCase)).Select(c => c.Value).ToList();
        var names = User.Claims.Where(c => string.Equals(c.Type, "lab_name", StringComparison.OrdinalIgnoreCase)).Select(c => c.Value).ToList();
        var result = new List<DenialWorkflowLabOption>();

        for (var i = 0; i < ids.Count; i++)
        {
            if (!int.TryParse(ids[i], out var labId) || labId <= 0) continue;
            var labName = i < names.Count ? names[i] : string.Empty;
            result.Add(new DenialWorkflowLabOption { LabId = labId, LabName = labName });
        }

        return result
            .GroupBy(x => x.LabId)
            .Select(g => g.First())
            .OrderBy(x => x.LabName)
            .ToList();
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

    private DenialWorkflowFilter Normalize(DenialWorkflowFilter filter)
    {
        if (filter.Page <= 0) filter.Page = 1;
        filter.PageSize = filter.PageSize <= 0 ? 50 : Math.Clamp(filter.PageSize, 25, 200);

        var tokenUserName = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? filter.UserName ?? string.Empty;
        var tokenRole = FirstClaim(ClaimTypes.Role, "role", "roles") ?? filter.Role ?? string.Empty;

        // Never trust role/userName passed from React query string. Always scope from JWT.
        filter.UserName = tokenUserName;
        filter.Role = tokenRole;

        if (IsReviewerOnly(tokenRole))
        {
            // AR Reviewer must see only claims/tasks assigned to himself/herself.
            filter.AssignedTo = tokenUserName;
            filter.Reviewer = tokenUserName;
        }

        return filter;
    }

    private static bool IsReviewerOnly(string? role)
    {
        var r = NormalizeRoleToken(role);
        return (r.Contains("ARREVIEWER") || r.Contains("ARANALYSER") || r.Contains("ARANALYZER") || r.Contains("REVIEWER"))
            && !r.Contains("MANAGER")
            && !r.Contains("ADMIN");
    }

    private static string NormalizeRoleToken(string? value)
        => new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
}
