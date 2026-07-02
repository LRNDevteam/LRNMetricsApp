using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Http;
using System.Security.Claims;
using System.Text;
using ClosedXML.Excel;

namespace LRN.ReportsApi.Controllers;

[ApiController]
[Route("api/denialworkflow")]
[Route("api/denial-workflow")]
public sealed class DenialWorkflowController : ControllerBase
{
    private static readonly object ReactLogLock = new();
    private readonly IDenialWorkflowService _service;
    private readonly IDenialWorkflowExportJobService _exportJobs;
    private readonly IDenialWorkflowSupportService _supportService;
    private readonly IConfiguration _configuration;
    private readonly ILogger<DenialWorkflowController> _logger;
    public DenialWorkflowController(IDenialWorkflowService service, IDenialWorkflowExportJobService exportJobs, IDenialWorkflowSupportService supportService, IConfiguration configuration, ILogger<DenialWorkflowController> logger)
    {
        _service = service;
        _exportJobs = exportJobs;
        _supportService = supportService;
        _configuration = configuration;
        _logger = logger;
    }

    [HttpGet("health")]
    public IActionResult Health() => Ok("LRN.ReportsApi DenialWorkflow running");

    [HttpGet("log-paths")]
    public IActionResult LogPaths()
    {
        string Resolve(string key, string fallback)
        {
            var configured = _configuration[key] ?? fallback;
            return Path.IsPathRooted(configured) ? configured : Path.Combine(AppContext.BaseDirectory, configured);
        }
        return Ok(new
        {
            apiLogs = Resolve("Logging:File:LogDirectory", "Logs/Api"),
            reactLogs = Resolve("Logging:ReactClient:LogDirectory", "Logs/React"),
            workflowIssueLogs = Resolve("DenialWorkflowSupport:IssueLogFolder", "Logs/Issues")
        });
    }

    [HttpPost("client-logs")]
    public IActionResult SaveReactClientLog([FromBody] ReactClientLogRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Message)) return BadRequest(new { message = "Log message is required." });
        var configured = _configuration["Logging:ReactClient:LogDirectory"] ?? "Logs/React";
        var folder = Path.IsPathRooted(configured) ? configured : Path.Combine(AppContext.BaseDirectory, configured);
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, $"react-{DateTime.UtcNow:yyyy-MM-dd}.log");
        var userName = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "anonymous";
        var entry = $"[{DateTime.UtcNow:O}] [{request.Level}] User={userName} URL={request.Url}{Environment.NewLine}Message={request.Message}{Environment.NewLine}Context={request.Context}{Environment.NewLine}UserAgent={request.UserAgent}{Environment.NewLine}Stack={request.Stack}{Environment.NewLine}{new string('-', 100)}{Environment.NewLine}";
        lock (ReactLogLock) System.IO.File.AppendAllText(path, entry, Encoding.UTF8);
        return Accepted();
    }

    [HttpGet("support-contacts")]
    public IActionResult SupportContacts()
    {
        var emails = _configuration.GetSection("DenialWorkflowSupport:AdminEmails").Get<string[]>() ?? Array.Empty<string>();
        return Ok(new { supportEmails = emails.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray() });
    }

    [HttpPost("support-request")]
    public async Task<ActionResult<DenialWorkflowSupportRequestResult>> SupportRequest(DenialWorkflowSupportRequest request, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Subject)) return BadRequest(new { message = "Subject is required." });
        if (string.IsNullOrWhiteSpace(request.Message)) return BadRequest(new { message = "Issue details are required." });
        if (request.Subject.Length > 160) return BadRequest(new { message = "Subject must be 160 characters or fewer." });
        if (request.Message.Length > 4000) return BadRequest(new { message = "Issue details must be 4000 characters or fewer." });

        return Ok(await _supportService.SubmitAsync(HttpContext, request, ct));
    }

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

    [HttpGet("aging-dashboard")]
    [HttpGet("aging")]
    public async Task<ActionResult<AgingDashboardSummary>> AgingDashboard([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetAgingDashboardAsync(Normalize(filter), ct));

    [HttpGet("filter-options")]
    public async Task<ActionResult<DenialWorkflowFilterOptions>> FilterOptions([FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        return Ok(await _service.GetFilterOptionsAsync(labId, ct));
    }

    [HttpGet("last-run-reference")]
    public async Task<ActionResult<DenialWorkflowRunReference?>> LastRunReference([FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        return Ok(await _service.GetLastRunReferenceAsync(labId, ct));
    }

    [HttpGet("reviewers")]
    public async Task<ActionResult<IReadOnlyList<ReviewerOption>>> Reviewers([FromQuery] int labId = 0, CancellationToken ct = default)
        => Ok(await _service.GetReviewerOptionsAsync(labId, ct));

    [HttpGet("summary")]
    public async Task<ActionResult<DenialWorkflowSummary>> Summary([FromQuery] int labId, [FromQuery] string role = "", [FromQuery] string userName = "", CancellationToken ct = default)
        => Ok(await _service.GetSummaryAsync(labId, role, userName, ct));

    [HttpGet("claim-menu-counts")]
    [HttpGet("claim-counts")]
    [HttpGet("claims/status-counts")]
    [HttpGet("my-worklist/counts")]
    public async Task<ActionResult<ClaimSubMenuCounts>> ClaimMenuCounts([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
        => Ok(await _service.GetClaimSubMenuCountsAsync(Normalize(filter), ct));

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

    [HttpPost("claims/export")]
    [HttpPost("claim-level/export")]
    public ActionResult<ClaimExportStartResponse> StartClaimsExport([FromBody] DenialWorkflowFilter? filter)
    {
        if (filter is null || filter.LabId <= 0) return BadRequest("LabId is required.");
        if (!CanDownloadWorkflowFromToken())
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "This role cannot export workflow claims." });
        var normalized = Normalize(filter);
        var requestedBy = normalized.UserName;
        return Accepted(_exportJobs.StartClaimsExport(normalized, requestedBy));
    }

    [HttpGet("claims/export/{jobId}")]
    public ActionResult<ClaimExportStatusResponse> ClaimsExportStatus([FromRoute] string jobId)
    {
        var requestedBy = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? string.Empty;
        var status = _exportJobs.GetStatus(jobId, requestedBy);
        return status is null ? NotFound(new { message = "Export job was not found." }) : Ok(status);
    }

    [HttpGet("claims/export/{jobId}/download")]
    public IActionResult DownloadClaimsExport([FromRoute] string jobId)
    {
        var requestedBy = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? string.Empty;
        var file = _exportJobs.GetCompletedFile(jobId, requestedBy);
        if (file is null) return NotFound(new { message = "Export file is not ready yet." });
        return PhysicalFile(file.FilePath, file.ContentType, file.FileName);
    }

    [HttpDelete("claims/export/{jobId}")]
    public ActionResult<ClaimExportStatusResponse> CancelClaimsExport([FromRoute] string jobId)
    {
        var requestedBy = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? string.Empty;
        var status = _exportJobs.Cancel(jobId, requestedBy);
        return status is null ? NotFound(new { message = "Export job was not found." }) : Ok(status);
    }

    [HttpPost("claims/upload-csv")]
    [RequestFormLimits(MultipartBodyLengthLimit = 104_857_600)]
    [RequestSizeLimit(104_857_600)]
    public async Task<ActionResult<ClaimCsvUploadResult>> UploadClaimsCsv([FromForm] ClaimUploadForm upload, CancellationToken ct)
    {
        var labId = upload.LabId;
        var file = upload.File;
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        var uploadError = await FileUploadGuard.ValidateCsvOrExcelAsync(file, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        var extension = Path.GetExtension(file.FileName);
        if (!string.Equals(extension, ".csv", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(extension, ".xlsx", StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { message = "Only CSV and Excel (.xlsx) upload templates are supported." });

        var role = FirstClaim(ClaimTypes.Role, "role", "roles") ?? string.Empty;
        var userName = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? string.Empty;
        var managerRole = CanAssignFromToken();
        var reviewerOnly = IsReviewerOnly(role);
        if (!managerRole && !reviewerOnly)
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Only AR Manager/Admin and AR Reviewer users can process workflow CSV files." });

        List<Dictionary<string, string>> rows;
        try
        {
            await using var stream = file.OpenReadStream();
            rows = string.Equals(extension, ".xlsx", StringComparison.OrdinalIgnoreCase)
                ? ReadExcelRows(stream, 200_000)
                : await ReadCsvRowsAsync(stream, 200_000, ct);
        }
        catch (InvalidDataException ex)
        {
            return BadRequest(new { message = ex.Message });
        }

        var errors = new List<string>();
        var actionableRows = rows
            .Select((row, index) => new
            {
                Row = row,
                RowNumber = index + 2,
                ClaimId = CsvValue(row, "ClaimUID", "ClaimUid", "ClaimID", "ClaimId"),
                TaskId = CsvValue(row, "TaskID", "TaskId")
            })
            .Where(x => CsvHasClaimAction(x.Row))
            .ToList();
        var skipped = rows.Count - actionableRows.Count;

        // Task-level template when any row has a TaskID column value
        var isTaskLevel = actionableRows.Any(x => !string.IsNullOrWhiteSpace(x.TaskId));

        var claimRows = new List<(int RowNumber, string ClaimId, string TaskId, Dictionary<string, string> Row)>();
        if (isTaskLevel)
        {
            foreach (var r in actionableRows)
            {
                if (string.IsNullOrWhiteSpace(r.ClaimId))
                {
                    AddCsvError(errors, r.RowNumber, "ClaimUID or ClaimID is required.");
                    continue;
                }
                claimRows.Add((r.RowNumber, r.ClaimId, r.TaskId, r.Row));
            }
        }
        else
        {
            foreach (var group in actionableRows.GroupBy(x => x.ClaimId, StringComparer.OrdinalIgnoreCase))
            {
                if (string.IsNullOrWhiteSpace(group.Key))
                {
                    foreach (var missingClaimRow in group) AddCsvError(errors, missingClaimRow.RowNumber, "ClaimUID or ClaimID is required.");
                    continue;
                }
                if (group.Count() > 1)
                {
                    AddCsvError(errors, group.First().RowNumber, $"Claim '{group.Key}' has updates on more than one CSV row. Enter claim-level values on only one row.");
                    continue;
                }
                var claimRow = group.Single();
                claimRows.Add((claimRow.RowNumber, claimRow.ClaimId, string.Empty, claimRow.Row));
            }
        }

        var updatedTasks = 0;
        var addedComments = 0;
        var escalatedClaims = 0;
        var escalationResponses = 0;
        var processedRows = 0;
        foreach (var item in claimRows)
        {
            var allClaimTasks = await _service.GetTasksByClaimAsync(labId, item.ClaimId, ct);
            if (allClaimTasks.Count == 0)
            {
                AddCsvError(errors, item.RowNumber, $"Claim '{item.ClaimId}' was not found.");
                continue;
            }
            var claimTasks = !string.IsNullOrWhiteSpace(item.TaskId)
                ? allClaimTasks.Where(x => string.Equals(x.TaskId?.Trim(), item.TaskId.Trim(), StringComparison.OrdinalIgnoreCase)).ToList()
                : allClaimTasks;
            if (claimTasks.Count == 0)
            {
                AddCsvError(errors, item.RowNumber, $"Task '{item.TaskId}' was not found for claim '{item.ClaimId}'.");
                continue;
            }
            if (reviewerOnly && claimTasks.Any(x => !string.Equals(x.AssignedTo?.Trim(), userName.Trim(), StringComparison.OrdinalIgnoreCase)))
            {
                AddCsvError(errors, item.RowNumber, "AR Reviewers can update only claims whose tasks are assigned to themselves.");
                continue;
            }

            var updateStatusRaw = CsvValue(item.Row, "UpdateStatus", "NewStatus");
            var updateStatus = string.IsNullOrWhiteSpace(updateStatusRaw) ? string.Empty : NormalizeWorkflowStatus(updateStatusRaw);
            var comments = CsvValue(item.Row, "Comments", "ReviewerComments", "Comment");
            var notes = CsvValue(item.Row, "Notes");
            var escalationReason = CsvValue(item.Row, "EscalationReason");
            var otherEscalationReason = CsvValue(item.Row, "OtherEscalationReason");
            var escalationComment = CsvValue(item.Row, "EscalationComment");
            var escalationResponse = CsvValue(item.Row, "EscalationResponse", "RecommendedNextAction");
            var escalationResponseComment = CsvValue(item.Row, "EscalationResponseComment", "ResponseComment");
            var rowChanged = false;
            var hasStatusOrNote = !string.IsNullOrWhiteSpace(updateStatus) || !string.IsNullOrWhiteSpace(comments);
            var hasReviewerEscalation = !string.IsNullOrWhiteSpace(escalationReason) || !string.IsNullOrWhiteSpace(escalationComment);
            var hasManagerResponse = !string.IsNullOrWhiteSpace(escalationResponse) || !string.IsNullOrWhiteSpace(escalationResponseComment);
            if (new[] { hasStatusOrNote, hasReviewerEscalation, hasManagerResponse }.Count(x => x) > 1)
            {
                AddCsvError(errors, item.RowNumber, "Use one claim action per row: status/note, reviewer escalation, or manager escalation response.");
                continue;
            }

            // Save standalone Notes column if provided (task-level template)
            if (!string.IsNullOrWhiteSpace(notes) && string.IsNullOrWhiteSpace(comments) && !hasReviewerEscalation && !hasManagerResponse)
            {
                var noteTask = claimTasks[0];
                await _service.SaveNoteAsync(new SaveDenialNoteRequest
                {
                    LabId = labId, ClaimId = item.ClaimId,
                    NoteLevel = !string.IsNullOrWhiteSpace(item.TaskId) ? "Task" : "Claim",
                    NoteText = notes, Status = NormalizeWorkflowStatus(noteTask.Status), CreatedBy = userName
                }, ct);
                addedComments++;
                rowChanged = true;
            }

            if (!string.IsNullOrWhiteSpace(updateStatus))
            {
                if (string.IsNullOrWhiteSpace(comments))
                {
                    AddCsvError(errors, item.RowNumber, "Comments are required when UpdateStatus is provided.");
                    continue;
                }
                var noteLevel = !string.IsNullOrWhiteSpace(item.TaskId) ? "Task" : "Claim";
                var template = new UpdateTaskRequest
                {
                    LabId = labId, Status = updateStatus, Comments = comments, ActionBy = userName,
                    ActionCompleted = CsvNullableBool(item.Row, "ActionCompleted"),
                    ActualOutcome = CsvValue(item.Row, "ActualOutcome"),
                    DocumentationType = CsvValue(item.Row, "DocumentationType"),
                    FollowUpReason = CsvValue(item.Row, "FollowUpReason"),
                    ClosureReason = CsvValue(item.Row, "ClosureReason"),
                    ValidationStatus = CsvValue(item.Row, "ValidationStatus"),
                    ExpectedResponseDate = CsvNullableDate(item.Row, "ExpectedResponseDate"),
                    UpdateScope = "Claim", UpdateScopeValue = item.ClaimId
                };
                var validationError = ValidateTaskStatusUpdate(template, role);
                if (!string.IsNullOrWhiteSpace(validationError))
                {
                    AddCsvError(errors, item.RowNumber, validationError);
                    continue;
                }
                await _service.SaveNoteAsync(new SaveDenialNoteRequest
                {
                    LabId = labId, ClaimId = item.ClaimId, NoteLevel = noteLevel, NoteText = comments,
                    Status = updateStatus, NextFollowUpDate = template.ExpectedResponseDate, CreatedBy = userName
                }, ct);
                addedComments++;
                foreach (var task in claimTasks)
                {
                    template.TaskId = task.TaskId;
                    if (await _service.UpdateTaskAsync(template, ct) > 0) updatedTasks++;
                }
                rowChanged = true;
            }
            else if (!string.IsNullOrWhiteSpace(comments))
            {
                var noteLevel = !string.IsNullOrWhiteSpace(item.TaskId) ? "Task" : "Claim";
                await _service.SaveNoteAsync(new SaveDenialNoteRequest
                {
                    LabId = labId, ClaimId = item.ClaimId, NoteLevel = noteLevel, NoteText = comments,
                    Status = NormalizeWorkflowStatus(claimTasks[0].Status), CreatedBy = userName
                }, ct);
                updatedTasks += await _service.UpdateClaimCommentsAsync(labId, item.ClaimId, comments, userName, ct);
                addedComments++;
                rowChanged = true;
            }

            if (!string.IsNullOrWhiteSpace(escalationReason) || !string.IsNullOrWhiteSpace(escalationComment))
            {
                if (!reviewerOnly)
                {
                    AddCsvError(errors, item.RowNumber, "EscalationReason upload is for AR Reviewer claim escalation. AR Managers should use EscalationResponse.");
                    continue;
                }
                if (!ReviewerEscalationReasons.Contains(escalationReason))
                {
                    AddCsvError(errors, item.RowNumber, $"'{escalationReason}' is not a valid EscalationReason.");
                    continue;
                }
                if (string.Equals(escalationReason, "Other", StringComparison.OrdinalIgnoreCase) && string.IsNullOrWhiteSpace(otherEscalationReason))
                {
                    AddCsvError(errors, item.RowNumber, "OtherEscalationReason is required when EscalationReason is Other.");
                    continue;
                }
                if (string.IsNullOrWhiteSpace(escalationComment))
                {
                    AddCsvError(errors, item.RowNumber, "EscalationComment is required.");
                    continue;
                }
                var finalReason = string.Equals(escalationReason, "Other", StringComparison.OrdinalIgnoreCase)
                    ? $"Other - {otherEscalationReason}"
                    : escalationReason;
                await _service.SaveEscalationAsync(new SaveDenialEscalationRequest
                {
                    LabId = labId, ClaimId = item.ClaimId, EscalationLevel = "Claim",
                    EscalationScope = "Overall Claim", EscalationScopeValue = item.ClaimId,
                    EscalationScopeDisplay = "Overall Claim",
                    AffectedTaskIds = string.Join(",", claimTasks.Select(x => x.TaskId).Where(x => !string.IsNullOrWhiteSpace(x))),
                    RecommendedNextAction = "Manager review", EscalationReason = finalReason,
                    Comments = escalationComment, Status = finalReason.Contains("write-off decision required", StringComparison.OrdinalIgnoreCase) ? "WriteOffPending" : "Open",
                    NextFollowUpDate = CsvNullableDate(item.Row, "EscalationExpectedResponseDate"), CreatedBy = userName
                }, ct);
                foreach (var task in claimTasks)
                {
                    updatedTasks += await _service.UpdateTaskAsync(new UpdateTaskRequest
                    {
                        LabId = labId, TaskId = task.TaskId, Status = "Escalated to AR Manager",
                        Comments = $"{finalReason} - {escalationComment}", ActionBy = userName,
                        UpdateScope = "Claim", UpdateScopeValue = item.ClaimId
                    }, ct);
                }
                escalatedClaims++;
                rowChanged = true;
            }

            if (!string.IsNullOrWhiteSpace(escalationResponse) || !string.IsNullOrWhiteSpace(escalationResponseComment))
            {
                if (!managerRole)
                {
                    AddCsvError(errors, item.RowNumber, "Only AR Manager/Admin can upload an EscalationResponse.");
                    continue;
                }
                if (!ManagerEscalationResponses.Contains(escalationResponse))
                {
                    AddCsvError(errors, item.RowNumber, $"'{escalationResponse}' is not a valid EscalationResponse.");
                    continue;
                }
                if (string.IsNullOrWhiteSpace(escalationResponseComment))
                {
                    AddCsvError(errors, item.RowNumber, "EscalationResponseComment is required.");
                    continue;
                }
                var escalation = (await _service.GetEscalationsAsync(labId, item.ClaimId, null, null, "Claim", ct))
                    .FirstOrDefault(x => !string.Equals(x.Status, "Resolved", StringComparison.OrdinalIgnoreCase)
                        && !string.Equals(x.Status, "Closed", StringComparison.OrdinalIgnoreCase));
                if (escalation is null)
                {
                    AddCsvError(errors, item.RowNumber, "No active claim-level escalation was found for the response.");
                    continue;
                }
                var affected = await _service.ResolveEscalationAsync(new ResolveDenialEscalationRequest
                {
                    LabId = labId, EscalationId = escalation.EscalationId, ClaimId = item.ClaimId,
                    EscalationLevel = "Claim", ResolutionAction = "rework",
                    ResponseNote = escalationResponseComment, RecommendedNextAction = escalationResponse,
                    ActionBy = userName
                }, ct);
                if (affected > 0)
                {
                    escalationResponses++;
                    rowChanged = true;
                }
                else AddCsvError(errors, item.RowNumber, "Escalation response was not applied.");
            }

            if (rowChanged) processedRows++;
        }

        var result = new ClaimCsvUploadResult
        {
            Success = errors.Count == 0,
            TotalRows = rows.Count,
            ProcessedRows = processedRows,
            SkippedRows = skipped,
            UpdatedTasks = updatedTasks,
            AddedComments = addedComments,
            EscalatedClaims = escalatedClaims,
            EscalationResponses = escalationResponses,
            Errors = errors,
            Message = $"Processed {processedRows} claim row(s): {updatedTasks} task status update(s), {addedComments} claim comment(s), {escalatedClaims} escalation(s), and {escalationResponses} escalation response(s). Skipped {skipped} unchanged row(s).{(errors.Count > 0 ? $" {errors.Count} error(s) require correction." : string.Empty)}"
        };
        return Ok(result);
    }

	[HttpGet("claim-tasks")]
	public async Task<ActionResult<IReadOnlyList<WorkflowTaskRow>>> ClaimTasksQuery(
	   [FromQuery] int labId,
	   [FromQuery] string? claimId,
	   CancellationToken ct,
	   [FromQuery] string taskView = "")
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
		CancellationToken ct,
		[FromQuery] string taskView = "")
	{
		if (labId <= 0) return BadRequest("LabId is required.");
		if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");

		var rows = await _service.GetTasksByClaimAsync(labId, claimId.Trim(), ct);
		return Ok(ScopeRowsForReviewer(rows));
	}

	[HttpGet("tasks")]
    public async Task<ActionResult<PagedResult<WorkflowTaskRow>>> Tasks([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
    {
        if (!CanAccessWorkflowTaskView(filter.TaskView))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "This role cannot access the selected workflow tab." });
        if (string.Equals(filter.TaskView, "verification", StringComparison.OrdinalIgnoreCase) && !CanAssignFromToken())
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Only Admin and AR Manager users can view Verification." });

        return Ok(await _service.GetTasksAsync(Normalize(filter), ct));
    }

    [HttpGet("verification")]
    public async Task<ActionResult<PagedResult<VerificationTaskRow>>> Verification([FromQuery] DenialWorkflowFilter filter, CancellationToken ct)
    {
        if (!CanAssignFromToken())
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Only Admin and AR Manager users can view Verification." });

        return Ok(await _service.GetVerificationAsync(Normalize(filter), ct));
    }

    [HttpPost("assign-insight")]
    [HttpPost("assign-by-insight")]
    public async Task<ActionResult<DenialWorkflowResult>> AssignByInsight(AssignInsightRequest request, CancellationToken ct)
    {
        if (!CanAssignFromToken()) return StatusCode(StatusCodes.Status403Forbidden, new { message = "Only Admin and AR Manager users can assign claims." });
        var rows = await _service.AssignByInsightAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Assigned successfully." : "No matching task found." });
    }

    [HttpPost("assign-claims")]
    [HttpPost("assign-by-claim")]
    public async Task<ActionResult<ClaimAssignmentResult>> AssignClaims(AssignClaimRequest request, CancellationToken ct)
    {
        if (!CanAssignFromToken()) return StatusCode(StatusCodes.Status403Forbidden, new { message = "Only Admin and AR Manager users can assign claims." });
        var result = await _service.AssignClaimsAsync(request, ct);
        return Ok(result);
    }

    [HttpPost("update-task")]
    [HttpPost("task/update")]
    public async Task<ActionResult<DenialWorkflowResult>> UpdateTask(UpdateTaskRequest request, CancellationToken ct)
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        if (IsReadOnlyWorkflowRole(role)) return StatusCode(StatusCodes.Status403Forbidden, new { message = "This role cannot update task status." });
        request.Status = NormalizeWorkflowStatus(request.Status);
        var validationError = ValidateTaskStatusUpdate(request, role);
        if (!string.IsNullOrWhiteSpace(validationError)) return BadRequest(new { message = validationError });
        if (string.IsNullOrWhiteSpace(request.ActionBy))
            request.ActionBy = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow";
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
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        if (request.LabId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(request.ClaimId)) return BadRequest("ClaimId is required.");
        if (string.IsNullOrWhiteSpace(request.NoteText)) return BadRequest("Note text is required.");
        var normalizedStatus = NormalizeWorkflowStatus(request.Status);
        if (request.ValidateWorkflowFields && normalizedStatus == "Payer Follow-up Required" && string.IsNullOrWhiteSpace(request.FollowUpReason))
            return BadRequest(new { success = false, message = "Follow-up reason is required." });
        if (request.ValidateWorkflowFields && (normalizedStatus is "Payer Follow-up Required" or "Pending Payer Response" or "Pending Documentation") && request.NextFollowUpDate is null)
            return BadRequest(new { success = false, message = "Expected response date is required." });
        if (request.ValidateWorkflowFields && normalizedStatus == "Pending Payer Response" && request.ActionCompleted != true)
            return BadRequest(new { success = false, message = "Action completed must be confirmed." });
        if (request.ValidateWorkflowFields && normalizedStatus == "Pending Documentation" && string.IsNullOrWhiteSpace(request.DocumentationType))
            return BadRequest(new { success = false, message = "Documentation type is required." });
        if (request.ValidateWorkflowFields && normalizedStatus == "Write-Off Pending Approval" && string.IsNullOrWhiteSpace(request.ActualOutcome))
            return BadRequest(new { success = false, message = "Actual outcome is required for write-off approval." });
        if (IsClientManagerRole(role) && !await HasClientInfoPendingEscalationAsync(request.LabId, request.ClaimId, request.TaskId, request.CptCode, ct))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Client Manager can update comments only for Client Info Pending escalations." });
        request.CreatedBy = string.IsNullOrWhiteSpace(request.CreatedBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : request.CreatedBy;
        return Ok(await _service.SaveNoteAsync(request, ct));
    }

    [HttpGet("follow-up-notifications")]
    public async Task<ActionResult<IReadOnlyList<FollowUpNotificationRow>>> FollowUpNotifications([FromQuery] int labId, CancellationToken ct)
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        var userName = FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? string.Empty;
        if (labId <= 0) return BadRequest("LabId is required.");
        if (!IsReviewerOnly(role)) return Ok(Array.Empty<FollowUpNotificationRow>());
        return Ok(await _service.GetFollowUpNotificationsAsync(labId, userName, ct));
    }

    [HttpGet("claim-documents")]
    public async Task<ActionResult<IReadOnlyList<ClaimDocumentRow>>> ClaimDocuments([FromQuery] int labId, [FromQuery] string claimId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");
        return Ok(await _service.GetClaimDocumentsAsync(labId, claimId.Trim(), ct));
    }

    [HttpGet("claim-documents/{documentId:long}/download")]
    public async Task<IActionResult> DownloadClaimDocument([FromRoute] long documentId, [FromQuery] int labId, CancellationToken ct)
    {
        if (labId <= 0) return BadRequest("LabId is required.");
        var doc = await _service.GetClaimDocumentAsync(labId, documentId, ct);
        if (doc is null || string.IsNullOrWhiteSpace(doc.FilePath) || !System.IO.File.Exists(doc.FilePath))
            return NotFound("Document was not found.");

        var stream = System.IO.File.OpenRead(doc.FilePath);
        return File(stream, string.IsNullOrWhiteSpace(doc.ContentType) ? "application/octet-stream" : doc.ContentType, doc.OriginalFileName);
    }

    [HttpPost("claim-documents")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<IReadOnlyList<ClaimDocumentRow>>> UploadClaimDocuments([FromForm] int labId, [FromForm] string claimId, [FromForm] string? comment, [FromForm] string? uploadedBy, [FromForm] List<IFormFile> files, CancellationToken ct)
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        if (labId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(claimId)) return BadRequest("ClaimId is required.");
        if ((IsClientManagerRole(role) || IsAccountManagerRole(role)) && !await HasExternalManagerDocumentAccessAsync(labId, claimId, null, null, role, ct))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Client/Account Manager can upload documents only for claims escalated to their role." });
        if (files == null || files.Count == 0) return BadRequest("Select at least one file.");
        if (files.Count > 10) return BadRequest(new { message = "Upload a maximum of 10 files at a time." });
        foreach (var file in files)
        {
            var uploadError = await FileUploadGuard.ValidateDocumentAsync(file, 25 * 1024 * 1024, ct);
            if (uploadError != null) return BadRequest(new { message = $"{Path.GetFileName(file.FileName)}: {uploadError}" });
        }

        uploadedBy = string.IsNullOrWhiteSpace(uploadedBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : uploadedBy;
        var configuredRoot = _configuration["DenialWorkflowFileStorage:UploadRootPath"];
        if (string.IsNullOrWhiteSpace(configuredRoot))
            return StatusCode(StatusCodes.Status500InternalServerError, new { message = "Document upload storage is not configured." });

        var root = Path.Combine(configuredRoot, labId.ToString(), SafePath(claimId));
        try
        {
            Directory.CreateDirectory(root);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unable to create denial workflow upload folder {UploadFolder}.", root);
            return StatusCode(StatusCodes.Status500InternalServerError, new { message = "Document upload storage is not accessible. Please contact support." });
        }
        var saved = new List<ClaimDocumentRow>();
        foreach (var file in files.Where(f => f.Length > 0))
        {
            var ext = Path.GetExtension(file.FileName);
            var stored = $"{Guid.NewGuid():N}{ext}";
            var path = Path.Combine(root, stored);
            try
            {
                await using var fs = System.IO.File.Create(path);
                await file.CopyToAsync(fs, ct);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unable to save denial workflow upload {FileName} to {UploadPath}.", file.FileName, path);
                return StatusCode(StatusCodes.Status500InternalServerError, new { message = "Document upload failed because storage is not accessible. Please contact support." });
            }
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

    [HttpDelete("claim-documents/{documentId:long}")]
    public async Task<IActionResult> DeleteClaimDocument([FromRoute] long documentId, [FromQuery] int labId, CancellationToken ct)
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        if (labId <= 0) return BadRequest("LabId is required.");

        var doc = await _service.GetClaimDocumentAsync(labId, documentId, ct);
        if (doc is null) return NotFound("Document was not found.");

        if ((IsClientManagerRole(role) || IsAccountManagerRole(role)) && !await HasExternalManagerDocumentAccessAsync(labId, doc.ClaimId, null, null, role, ct))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Client/Account Manager can delete documents only for claims escalated to their role." });

        if (!await _service.CanDeleteClaimDocumentAsync(labId, doc.ClaimId, ct))
            return StatusCode(StatusCodes.Status409Conflict, new { message = "Documents can be deleted only while the claim is still in the active editable stage." });

        var deleted = await _service.DeleteClaimDocumentAsync(labId, documentId, ct);
        return deleted > 0 ? NoContent() : NotFound("Document was not found.");
    }

    private static string SafePath(string value)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) value = value.Replace(c, '_');
        return value.Trim();
    }



    [HttpGet("claim-history")]
    [HttpGet("claims/{claimId}/history")]
    public async Task<ActionResult<IReadOnlyList<DenialClaimHistoryRow>>> ClaimHistory([FromQuery] int labId, [FromRoute] string? claimId = null, [FromQuery(Name = "claimId")] string? claimIdQuery = null, [FromQuery] string? taskId = null, [FromQuery] string? cptCode = null, [FromQuery] string historyLevel = "Claim", CancellationToken ct = default)
    {
        var id = !string.IsNullOrWhiteSpace(claimId) ? claimId : claimIdQuery;
        if (labId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(id)) return BadRequest("ClaimId is required.");
        return Ok(await _service.GetClaimHistoryAsync(labId, id.Trim(), taskId, cptCode, historyLevel, ct));
    }

    [HttpGet("escalation-queue")]
    public async Task<ActionResult<PagedResult<DenialEscalationQueueRow>>> EscalationQueue([FromQuery] DenialWorkflowFilter filter, [FromQuery] string escalationLevel = "Claim", CancellationToken ct = default)
    {
        if (filter.LabId <= 0) return BadRequest("LabId is required.");
        if (string.Equals(filter.TaskView, "response", StringComparison.OrdinalIgnoreCase) && IsReadOnlyWorkflowRole(FirstClaim(ClaimTypes.Role, "role", "roles")))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "This role cannot access Escalation Response." });
        return Ok(await _service.GetEscalationQueueAsync(Normalize(filter), escalationLevel, ct));
    }

    [HttpPost("resolve-escalation")]
    public async Task<ActionResult<DenialWorkflowResult>> ResolveEscalation(ResolveDenialEscalationRequest request, CancellationToken ct)
    {
        if (!CanRespondToEscalationFromToken()) return StatusCode(StatusCodes.Status403Forbidden, new { message = "Only Admin, AR Manager, Client Manager and Account Manager users can submit escalation responses." });
        if (request.LabId <= 0) return BadRequest("LabId is required.");
        if (request.EscalationId <= 0) return BadRequest("EscalationId is required.");
        if (string.IsNullOrWhiteSpace(request.ResponseNote)) return BadRequest("Manager response note is required.");
        if (string.IsNullOrWhiteSpace(request.RecommendedNextAction)) return BadRequest("Recommended next action is required.");
        request.ActionBy = string.IsNullOrWhiteSpace(request.ActionBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : request.ActionBy;
        var rows = await _service.ResolveEscalationAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Escalation response saved." : "Escalation response was not saved." });
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
        if (IsReadOnlyWorkflowRole(FirstClaim(ClaimTypes.Role, "role", "roles"))) return StatusCode(StatusCodes.Status403Forbidden, new { message = "This role cannot submit escalations." });
        if (request.LabId <= 0) return BadRequest("LabId is required.");
        if (string.IsNullOrWhiteSpace(request.ClaimId)) return BadRequest("ClaimId is required.");
        if (string.IsNullOrWhiteSpace(request.EscalationReason)) return BadRequest("Escalation reason is required.");
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        if (IsReviewerOnly(role))
        {
            request.EscalationLevel = "Claim";
            request.TaskId = string.Empty;
            request.CptCode = string.Empty;
            request.EscalationScope = "Overall Claim";
            request.EscalationScopeValue = request.ClaimId;
            request.EscalationScopeDisplay = "Overall Claim";
        }
        request.CreatedBy = string.IsNullOrWhiteSpace(request.CreatedBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : request.CreatedBy;
        return Ok(await _service.SaveEscalationAsync(request, ct));
    }

    [HttpPost("update-escalation")]
    public async Task<ActionResult<DenialWorkflowResult>> UpdateEscalation(UpdateDenialEscalationRequest request, CancellationToken ct)
    {
        if (IsReadOnlyWorkflowRole(FirstClaim(ClaimTypes.Role, "role", "roles"))) return StatusCode(StatusCodes.Status403Forbidden, new { message = "This role cannot update escalations." });
        if (request.LabId <= 0) return BadRequest("LabId is required.");
        if (request.EscalationId <= 0) return BadRequest("EscalationId is required.");
        if (string.IsNullOrWhiteSpace(request.ClaimId)) return BadRequest("ClaimId is required.");
        if (string.IsNullOrWhiteSpace(request.EscalationReason)) return BadRequest("Escalation reason is required.");
        request.ActionBy = string.IsNullOrWhiteSpace(request.ActionBy) ? (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow") : request.ActionBy;
        var rows = await _service.UpdateEscalationAsync(request, ct);
        return Ok(new DenialWorkflowResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? "Escalation updated." : "Escalation update failed." });
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

        var tokenUserName = (FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? filter.UserName ?? string.Empty).Trim();
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
        else if (IsClientManagerRole(tokenRole) || IsAccountManagerRole(tokenRole))
        {
            // Client Manager and Account Manager downloads use the visible lab/tab/filter scope,
            // but are never assigned-to restricted.
            filter.AssignedTo = string.Empty;
            filter.Reviewer = string.Empty;
        }

        return filter;
    }

    private async Task<bool> HasClientInfoPendingEscalationAsync(int labId, string claimId, string? taskId, string? cptCode, CancellationToken ct)
    {
        static bool HasClientInfo(IEnumerable<DenialEscalationRow> rows)
            => rows.Any(x =>
                (x.EscalationReason ?? string.Empty).Contains("Client Info Pending", StringComparison.OrdinalIgnoreCase) ||
                (x.EscalationReason ?? string.Empty).Contains("Client Information Pending", StringComparison.OrdinalIgnoreCase) ||
                (x.Comments ?? string.Empty).Contains("Client Info Pending", StringComparison.OrdinalIgnoreCase) ||
                (x.Comments ?? string.Empty).Contains("Client Information Pending", StringComparison.OrdinalIgnoreCase));

        var claimRows = await _service.GetEscalationsAsync(labId, claimId.Trim(), null, null, "Claim", ct);
        if (HasClientInfo(claimRows)) return true;

        // When taskId/cptCode are blank, repository returns all line-level escalations for the claim.
        var lineRows = await _service.GetEscalationsAsync(labId, claimId.Trim(), taskId, cptCode, "Line", ct);
        if (HasClientInfo(lineRows)) return true;

        return false;
    }

    private async Task<bool> HasExternalManagerDocumentAccessAsync(int labId, string claimId, string? taskId, string? cptCode, string? role, CancellationToken ct)
    {
        static bool HasClientInfo(IEnumerable<DenialEscalationRow> rows)
            => rows.Any(x =>
                (x.EscalationReason ?? string.Empty).Contains("Client Info Pending", StringComparison.OrdinalIgnoreCase) ||
                (x.EscalationReason ?? string.Empty).Contains("Client Information Pending", StringComparison.OrdinalIgnoreCase) ||
                (x.Comments ?? string.Empty).Contains("Client Info Pending", StringComparison.OrdinalIgnoreCase) ||
                (x.Comments ?? string.Empty).Contains("Client Information Pending", StringComparison.OrdinalIgnoreCase));

        bool IsEscalatedToRole(DenialEscalationRow row)
        {
            var target = NormalizeRoleToken($"{row.EscalatedToRole} {row.EscalatedTo}");
            return IsClientManagerRole(role)
                ? target.Contains("CLIENTMANAGER")
                : IsAccountManagerRole(role) && target.Contains("ACCOUNTMANAGER");
        }

        var claimRows = await _service.GetEscalationsAsync(labId, claimId.Trim(), null, null, "Claim", ct);
        if (HasClientInfo(claimRows) || claimRows.Any(IsEscalatedToRole)) return true;

        var lineRows = await _service.GetEscalationsAsync(labId, claimId.Trim(), taskId, cptCode, "Line", ct);
        return HasClientInfo(lineRows) || lineRows.Any(IsEscalatedToRole);
    }

    private bool CanAssignFromToken()
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        var r = NormalizeRoleToken(role);
        return r.Contains("ADMIN") || r.Contains("ARMANAGER");
    }

    private bool CanRespondToEscalationFromToken()
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        var r = NormalizeRoleToken(role);
        return r.Contains("ADMIN") || r.Contains("ARMANAGER") || r.Contains("CLIENTMANAGER") || r.Contains("ACCOUNTMANAGER");
    }

    private bool CanAccessWorkflowTaskView(string? taskView)
    {
        var view = NormalizeRoleToken(taskView);
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        if (IsReviewerOnly(role) && view.Contains("INTERNALESCALATION")) return false;
        if ((IsClientManagerRole(role) || IsAccountManagerRole(role))
            && (view.Contains("INTERNALESCALATION") || view.Contains("ESCALATIONRESPONSE") || view == "RESPONSE"))
            return false;
        return true;
    }

    private bool CanDownloadWorkflowFromToken()
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        var r = NormalizeRoleToken(role);
        return r.Contains("ADMIN")
            || r.Contains("ARMANAGER")
            || IsReviewerOnly(role)
            || r.Contains("CLIENTMANAGER")
            || r.Contains("ACCOUNTMANAGER");
    }

    private static bool IsReadOnlyWorkflowRole(string? role) => IsClientManagerRole(role) || IsAccountManagerRole(role);
    private static bool IsClientManagerRole(string? role) => NormalizeRoleToken(role).Contains("CLIENTMANAGER");
    private static bool IsAccountManagerRole(string? role) => NormalizeRoleToken(role).Contains("ACCOUNTMANAGER");

    private static bool IsReviewerOnly(string? role)
    {
        var r = NormalizeRoleToken(role);
        return (r.Contains("ARREVIEWER") || r.Contains("ARANALYSER") || r.Contains("ARANALYZER") || r.Contains("REVIEWER"))
            && !r.Contains("MANAGER")
            && !r.Contains("ADMIN");
    }

    private static readonly HashSet<string> CanonicalLineStatuses = new(StringComparer.OrdinalIgnoreCase)
    {
        "New",
        "Unassigned",
        "Assigned",
        "Payer Follow-up Required",
        "Pending Payer Response",
        "Pending Documentation",
        "Write-Off Pending Approval",
        "Escalated to AR Manager",
        "Rework",
        "Closed"
    };

    private static readonly HashSet<string> AnalystSelectableStatuses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Assigned",
        "Payer Follow-up Required",
        "Pending Payer Response",
        "Pending Documentation",
        "Write-Off Pending Approval",
        "Escalated to AR Manager",
        "Closed"
    };

    private static readonly HashSet<string> ReviewerEscalationReasons = new(StringComparer.OrdinalIgnoreCase)
    {
        "Denial reason unclear",
        "Action clarification required",
        "Denial-action mapping unclear",
        "Payer policy conflict",
        "Appeal eligibility unclear",
        "Rebill eligibility unclear",
        "Write-off decision required",
        "Payer follow-up guidance needed",
        "Documentation requirement unclear",
        "EOB / payer response clarification",
        "Other"
    };

    private static readonly HashSet<string> ManagerEscalationResponses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Proceed with Appeal",
        "Proceed with Rebill",
        "Proceed with Write-Off Request",
        "Perform Payer Follow-up",
        "Request Documentation",
        "Additional Information Needed",
        "No Further Action Required",
        "Close Claim / Line",
        "Other"
    };

    private static string NormalizeWorkflowStatus(string? status)
    {
        var value = (status ?? string.Empty).Trim();
        return value.ToLowerInvariant() switch
        {
            "" or "open" or "in progress" or "in-progress" or "pending review" => "Assigned",
            "pending payer" => "Pending Payer Response",
            "escalated" or "internal escalation" or "external escalation" => "Escalated to AR Manager",
            "completed" => "Closed",
            "required review" or "returned for rework" => "Rework",
            _ => value
        };
    }

    private static string ValidateTaskStatusUpdate(UpdateTaskRequest request, string? role)
    {
        if (!CanonicalLineStatuses.Contains(request.Status))
            return $"'{request.Status}' is not a valid denial workflow status.";

        if (IsReviewerOnly(role) && !AnalystSelectableStatuses.Contains(request.Status))
            return "AR Analyst users can only select active analyst workflow statuses.";

        static bool Missing(string? value) => string.IsNullOrWhiteSpace(value);
        var commentsMissing = Missing(request.Comments);

        return request.Status switch
        {
            "Payer Follow-up Required" when Missing(request.FollowUpReason) => "Follow-up reason is required.",
            "Payer Follow-up Required" when request.ExpectedResponseDate is null => "Expected response date is required.",
            "Payer Follow-up Required" when commentsMissing => "Comments are required.",
            "Pending Payer Response" when request.ActionCompleted is null => "Action completed must be confirmed.",
            "Pending Payer Response" when request.ExpectedResponseDate is null => "Expected response date is required.",
            "Pending Payer Response" when commentsMissing => "Comments are required.",
            "Pending Documentation" when Missing(request.DocumentationType) => "Documentation type is required.",
            "Pending Documentation" when request.ExpectedResponseDate is null => "Expected response date is required.",
            "Pending Documentation" when commentsMissing => "Comments are required.",
            "Closed" when Missing(request.ActualOutcome) => "Actual outcome is required.",
            "Closed" when commentsMissing => "Closure comments are required.",
            "Write-Off Pending Approval" when Missing(request.ActualOutcome) => "Actual outcome is required for write-off approval.",
            _ => string.Empty
        };
    }

    private static string NormalizeRoleToken(string? value)
        => new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private static string CsvValue(IReadOnlyDictionary<string, string> row, params string[] names)
    {
        foreach (var name in names)
            if (row.TryGetValue(name, out var value))
                return (value ?? string.Empty).Trim().TrimStart('\uFEFF').TrimStart('\'');
        return string.Empty;
    }

    private static bool CsvHasClaimAction(IReadOnlyDictionary<string, string> row)
        => new[]
        {
            "UpdateStatus", "NewStatus", "Comments", "ReviewerComments", "Comment",
            "EscalationReason", "OtherEscalationReason", "EscalationComment",
            "EscalationExpectedResponseDate", "EscalationResponse",
            "RecommendedNextAction", "EscalationResponseComment", "ResponseComment"
        }.Any(name => row.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value));

    private static bool? CsvNullableBool(IReadOnlyDictionary<string, string> row, params string[] names)
    {
        var value = CsvValue(row, names);
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (bool.TryParse(value, out var parsed)) return parsed;
        if (value is "1" or "Y" or "Yes" or "yes") return true;
        if (value is "0" or "N" or "No" or "no") return false;
        return null;
    }

    private static DateTime? CsvNullableDate(IReadOnlyDictionary<string, string> row, params string[] names)
        => DateTime.TryParse(CsvValue(row, names), out var parsed) ? parsed.Date : null;

    private static void AddCsvError(List<string> errors, int rowNumber, string message)
    {
        if (errors.Count >= 200) return;
        errors.Add(rowNumber > 0 ? $"Row {rowNumber}: {message}" : message);
    }

    private static async Task<List<Dictionary<string, string>>> ReadCsvRowsAsync(Stream stream, int maxRows, CancellationToken ct)
    {
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 64 * 1024, leaveOpen: true);
        var records = new List<string[]>();
        var fields = new List<string>();
        var field = new StringBuilder();
        var inQuotes = false;
        var buffer = new char[64 * 1024];

        void FinishField()
        {
            fields.Add(field.ToString());
            field.Clear();
        }
        void FinishRecord()
        {
            FinishField();
            if (fields.Any(x => !string.IsNullOrWhiteSpace(x))) records.Add(fields.ToArray());
            fields.Clear();
            if (records.Count > maxRows + 1) throw new InvalidDataException($"CSV contains more than the supported {maxRows:N0} data rows.");
        }

        int read;
        while ((read = await reader.ReadAsync(buffer.AsMemory(0, buffer.Length), ct)) > 0)
        {
            for (var i = 0; i < read; i++)
            {
                var ch = buffer[i];
                if (inQuotes)
                {
                    if (ch == '"')
                    {
                        if (i + 1 < read && buffer[i + 1] == '"') { field.Append('"'); i++; }
                        else if (i + 1 == read && reader.Peek() == '"') { field.Append('"'); await reader.ReadAsync(buffer.AsMemory(0, 1), ct); }
                        else inQuotes = false;
                    }
                    else field.Append(ch);
                }
                else if (ch == '"') inQuotes = true;
                else if (ch == ',') FinishField();
                else if (ch == '\n') FinishRecord();
                else if (ch != '\r') field.Append(ch);
            }
        }
        if (inQuotes) throw new InvalidDataException("CSV contains an unterminated quoted field.");
        if (field.Length > 0 || fields.Count > 0) FinishRecord();
        if (records.Count == 0) throw new InvalidDataException("CSV is empty.");

        var headers = records[0].Select(x => x.Trim().TrimStart('\uFEFF')).ToArray();
        if (headers.Distinct(StringComparer.OrdinalIgnoreCase).Count() != headers.Length)
            throw new InvalidDataException("CSV contains duplicate column names.");
        if (!headers.Any(x => string.Equals(x, "ClaimUID", StringComparison.OrdinalIgnoreCase) || string.Equals(x, "ClaimID", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("CSV must contain ClaimUID or ClaimID.");

        return records.Skip(1).Select(values =>
        {
            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < headers.Length; i++) row[headers[i]] = i < values.Length ? values[i] : string.Empty;
            return row;
        }).ToList();
    }

    private static List<Dictionary<string, string>> ReadExcelRows(Stream stream, int maxRows)
    {
        using var workbook = new XLWorkbook(stream);
        // Must match the worksheet name WriteClaimUploadTemplateAsync actually creates
        // (workbook.Worksheets.Add("Task Upload")) — these had drifted apart, so every
        // downloaded template failed to re-upload with "There isn't a worksheet named
        // 'Claim Upload'".
        var sheet = workbook.Worksheet("Task Upload");
        var used = sheet.RangeUsed() ?? throw new InvalidDataException("The Task Upload worksheet is empty.");
        var headerRow = used.FirstRow();
        var headers = headerRow.Cells().Select(x => x.GetString().Trim()).ToArray();
        if (!headers.Any(x => string.Equals(x, "ClaimID", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("Excel template must contain ClaimID.");
        if (headers.Distinct(StringComparer.OrdinalIgnoreCase).Count() != headers.Length)
            throw new InvalidDataException("Excel template contains duplicate column names.");

        var rows = new List<Dictionary<string, string>>();
        foreach (var excelRow in used.RowsUsed().Skip(1))
        {
            if (rows.Count >= maxRows) throw new InvalidDataException($"Excel template contains more than the supported {maxRows:N0} data rows.");
            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < headers.Length; i++)
                row[headers[i]] = excelRow.Cell(i + 1).GetFormattedString().Trim();
            if (row.Values.Any(x => !string.IsNullOrWhiteSpace(x))) rows.Add(row);
        }
        return rows;
    }
}
