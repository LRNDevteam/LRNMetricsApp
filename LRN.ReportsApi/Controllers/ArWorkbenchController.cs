using System.Security.Claims;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using LRN.ReportsApi.Services.ArWorkbench;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// AR Workbench (new denial application, React app LRN.ARWorkbench). Reads the dbo.ARWB_* tables in
/// each lab database, populated from dbo.ClaimLevelData / dbo.LineLevelData by
/// dbo.ARWB_usp_LoadClaimsFromSource. Separate from the Denial Workflow (/api/denialworkflow) and its
/// dbo.Denial* tables, which are left unchanged.
///
/// /api/ar-workbench is listed in the workflow JWT gate in Program.cs. Anything outside that list
/// runs with no authentication at all.
///
/// Two layers of access on every call:
///   1. lab access   - the JWT lab_id claims (or the user's dbo.UserLabs list)
///   2. AR Workbench role - one of the 8 'AR Workbench - ...' roles in LRNMaster dbo.Roles (via
///      dbo.UserRoles), with permissions in dbo.RoleFeatureAccess and the clinic / provider in
///      dbo.ARWorkbenchUserScope. Scope is applied inside the SQL. The one exception is the site
///      admin roles: Super Admin (and Admin / LRN Admin) and Lab Admin get every page, with no
///      AR Workbench role needed.
/// </summary>
[ApiController]
[Route("api/ar-workbench")]
public sealed class ArWorkbenchController : ControllerBase
{
    private readonly IArWorkbenchRepository _repository;
    private readonly IDenialWorkflowService _workflowService;
    private readonly IDenialMapperRepository _mapper;
    private readonly IDenialMapperExcelService _mapperExcel;
    private readonly IWorkflowMasterValuesRepository _mapperMasters;
    private readonly ILogger<ArWorkbenchController> _logger;

    public ArWorkbenchController(IArWorkbenchRepository repository, IDenialWorkflowService workflowService,
        IDenialMapperRepository mapper, IDenialMapperExcelService mapperExcel, IWorkflowMasterValuesRepository mapperMasters,
        ILogger<ArWorkbenchController> logger)
    {
        _repository = repository;
        _workflowService = workflowService;
        _mapper = mapper;
        _mapperExcel = mapperExcel;
        _mapperMasters = mapperMasters;
        _logger = logger;
    }

    [HttpGet("health")]
    public IActionResult Health() => Ok("LRN.ReportsApi AR Workbench running");

    [HttpGet("labs")]
    public async Task<ActionResult<IReadOnlyList<DenialWorkflowLabOption>>> Labs(CancellationToken ct)
    {
        IReadOnlyList<DenialWorkflowLabOption> labs = LabsFromToken();
        if (labs.Count == 0) labs = await _workflowService.GetLabsForUserAsync(CurrentUserName(), ct);
        // T068: a deactivated client is hidden except from those who can reactivate it.
        if (IsClientAdminByRole()) return Ok(labs);
        var inactive = await _repository.GetInactiveClientLabIdsAsync(ct);
        return Ok(labs.Where(l => !inactive.Contains(l.LabId)).ToList());
    }

    // Site admins and AR Workbench System Administrators (role names in the token).
    private bool IsClientAdminByRole() =>
        SiteAdminRole() is not null
        || User.Claims.Any(c => (c.Type == ClaimTypes.Role || string.Equals(c.Type, "role", StringComparison.OrdinalIgnoreCase))
                                && c.Value.Contains("System Administrator", StringComparison.OrdinalIgnoreCase));

    [HttpGet("me")]
    public async Task<ActionResult<ArWorkbenchUserContext>> Me([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        return denied ?? Ok(user);
    }

    [HttpGet("queues")]
    public async Task<ActionResult<ArWorkbenchQueueSummary>> Queues([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetQueueSummaryAsync(labId, user!, ct));
    }

    /// <summary>The Dashboard screen: KPI tiles, charts and tables, all within the caller's scope.</summary>
    [HttpGet("dashboard")]
    public async Task<ActionResult<ArWorkbenchDashboard>> Dashboard([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetDashboardAsync(labId, user!, ct));
    }

    /// <summary>
    /// T071 Recovery &amp; Financial Analytics: recovered vs outstanding by client, payer, panel,
    /// denial category, agent and AR queue, plus the Follow-Up Comments Breakdown. Every role opens
    /// it; the figures are limited to the caller's scope in SQL.
    /// </summary>
    [HttpGet("analytics")]
    public async Task<ActionResult<ArWorkbenchAnalytics>> Analytics([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetAnalyticsAsync(labId, user!, ct));
    }

    // ---- Reports (T073 / T074 / T075) - every role; the internal reports are refused to viewers ---

    /// <summary>The reports this user can open, and where each of RPT-01..09 lives in the AR Workbench.</summary>
    [HttpGet("reports")]
    public async Task<ActionResult<ArWorkbenchReportCatalog>> Reports([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(new ArWorkbenchReportCatalog
        {
            Reports = ArWorkbenchReportRules.Catalog.Where(r => CanOpenReport(user!, r.Id)).ToList(),
            Rpt = ArWorkbenchReportRules.RptCatalog.Where(r => r.ReportId is null || CanOpenReport(user!, r.ReportId)).ToList()
        });
    }

    /// <param name="from">Event reports only: first day (default 30 days before <paramref name="to"/>).</param>
    /// <param name="to">Event reports only: last day, inclusive (default today).</param>
    [HttpGet("reports/{reportId}")]
    public async Task<ActionResult<ArWorkbenchReport>> Report([FromRoute] string reportId, [FromQuery] int labId, [FromQuery] DateTime? from, [FromQuery] DateTime? to, CancellationToken ct)
    {
        var (report, denied) = await LoadReportAsync(reportId, labId, from, to, ct);
        return denied ?? Ok(report);
    }

    /// <summary>The report as Excel: title, data date, the table (totals bold, detail rows indented), insights and note.</summary>
    [HttpGet("reports/{reportId}/export")]
    public async Task<ActionResult> ReportExport([FromRoute] string reportId, [FromQuery] int labId, [FromQuery] DateTime? from, [FromQuery] DateTime? to, CancellationToken ct)
    {
        var (report, denied) = await LoadReportAsync(reportId, labId, from, to, ct);
        if (denied is not null) return denied;
        var bytes = ArWorkbenchReportExcel.Build(report!);
        _logger.LogInformation("AR Workbench report {Report} exported for lab {LabId} by {User}", report!.Id, labId, CurrentUserName());
        return File(bytes, XlsxContentType, $"ARWorkbench_{report.Title.Replace(" ", string.Empty)}_{DateTime.Now:yyyyMMdd_HHmm}.xlsx");
    }

    private static bool CanOpenReport(ArWorkbenchUserContext user, string reportId)
        => user.SiteAdmin || user.RoleCode != "viewer" || !ArWorkbenchReportRules.InternalOnly.Contains(reportId);

    private async Task<(ArWorkbenchReport? Report, ActionResult? Denied)> LoadReportAsync(string reportId, int labId, DateTime? from, DateTime? to, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return (null, denied);
        if (!CanOpenReport(user!, reportId)) return (null, Forbidden("This report is only available to the AR team."));
        var (range, rangeError) = ArWorkbenchReportRules.ResolveRange(from, to, DateTime.UtcNow.Date);
        if (rangeError is not null) return (null, BadRequest(new { message = rangeError }));
        var report = await _repository.GetReportAsync(labId, reportId, range!, user!, ct);
        return report is null ? (null, NotFound(new { message = "Report not found." })) : (report, null);
    }

    // ---- Operational SLA targets (RPT-09) - ARWorkbench.ManageSettings, like the TFL limits -------

    [HttpGet("settings/sla")]
    public async Task<ActionResult<ArWorkbenchSlaSettings>> SlaSettings([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetSlaSettingsAsync(labId, ct));
    }

    [HttpPut("settings/sla")]
    public async Task<ActionResult> SaveSlaSettings([FromQuery] int labId, [FromBody] ArWorkbenchSlaSettingsRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var (values, error) = ArWorkbenchReportRules.ValidateSlaTargets(request?.Targets);
        if (error is not null) return BadRequest(new { message = error });
        return ToResult(await _repository.SaveSlaSettingsAsync(labId, values!, request!.Confirmed, user!.UserName, ct));
    }

    [HttpGet("claims")]
    public async Task<ActionResult<ArWorkbenchPagedResult<ArWorkbenchClaimRow>>> Claims([FromQuery] ArWorkbenchClaimFilter filter, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        return Ok(await _repository.GetClaimsAsync(filter, user!, ct));
    }

    /// <summary>
    /// Option lists (with counts) for the multi-select filters, over the caller's scope. With
    /// cascade=true the query string carries the page's current filters (same names as GET claims)
    /// and each list is narrowed by the others (T047).
    /// </summary>
    [HttpGet("claims/filter-options")]
    public async Task<ActionResult<ArWorkbenchFilterOptions>> ClaimFilterOptions([FromQuery] ArWorkbenchClaimFilter filter, [FromQuery] bool cascade, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        return Ok(await _repository.GetFilterOptionsAsync(filter.LabId, user!, ct, cascade ? filter : null));
    }

    [HttpGet("claims/{claimKey:long}")]
    public async Task<ActionResult<ArWorkbenchClaimDetail>> ClaimDetail([FromRoute] long claimKey, [FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        var detail = await _repository.GetClaimDetailAsync(labId, claimKey, user!, ct);
        // Out-of-scope and missing look the same, so a scoped user cannot probe for claim keys.
        if (detail is null) return NotFound(new { message = "Claim not found." });
        detail.DenialCodeInfo = (await CodeMasterInfoForClaimAsync(detail, ct)).ToList();
        detail.QaReview = await _repository.GetCurrentQaReviewAsync(labId, claimKey, ct);
        // Client users never see Awaiting QA / Pending Approval cases or internal history.
        if (user!.RoleCode != "viewer") detail.CipCases = await _repository.GetClaimCipCasesAsync(labId, claimKey, ct);
        return Ok(detail);
    }

    [HttpGet("master-data")]
    public async Task<ActionResult<ArWorkbenchMasterData>> MasterData([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetMasterDataAsync(labId, ct));
    }

    [HttpGet("data-processing/runs")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchRefreshRun>>> RefreshRuns([FromQuery] int labId, [FromQuery] int top = 10, CancellationToken ct = default)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!IsAdminOrManager(user!)) return Forbidden("Only an Administrator or RCM Manager can view data processing.");
        return Ok(await _repository.GetRefreshRunsAsync(labId, top, ct));
    }

    /// <summary>T038: the nightly queue snapshots on file (Data Processing), newest first.</summary>
    [HttpGet("data-processing/snapshots")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchSnapshotDay>>> Snapshots([FromQuery] int labId, [FromQuery] int top, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!IsAdminOrManager(user!)) return Forbidden("Only an Administrator or RCM Manager can view data processing.");
        return Ok(await _repository.GetSnapshotHistoryAsync(labId, top <= 0 ? 14 : top, ct));
    }

    /// <summary>T038: take (or retake) today's snapshot now instead of waiting for the night run.</summary>
    [HttpPost("data-processing/snapshots/run")]
    public async Task<ActionResult> RunSnapshot([FromQuery] int labId, [FromServices] Microsoft.Extensions.Options.IOptions<ArWorkbenchSnapshotOptions> options, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!IsAdminOrManager(user!)) return Forbidden("Only an Administrator or RCM Manager can run a snapshot.");
        var date = options.Value.LocalNow(DateTime.UtcNow).Date;
        try
        {
            var rows = await _repository.RunSnapshotAsync(labId, date, ct);
            _logger.LogInformation("AR Workbench snapshot {Date:yyyy-MM-dd} for lab {LabId} run by {User}: {Rows} claims", date, labId, user!.UserName, rows);
            return Ok(new { rows, message = $"Snapshot for {date:MM/dd/yyyy} taken: {rows:N0} claims (claims recalculated first)." });
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("already running", StringComparison.OrdinalIgnoreCase))
        {
            return Conflict(new { message = ex.Message });
        }
    }

    /// <summary>Runs dbo.ARWB_usp_LoadClaimsFromSource: every claim-level row -> dbo.ARWB_Claim, every line -> dbo.ARWB_ClaimLine.</summary>
    [HttpPost("data-processing/run")]
    public async Task<ActionResult<ArWorkbenchRefreshRun>> RunRefresh([FromQuery] int labId, [FromBody] ArWorkbenchRunRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!IsAdminOrManager(user!)) return Forbidden("Only an Administrator or RCM Manager can run data processing.");
        if ((request?.Note?.Length ?? 0) > 1000) return BadRequest(new { message = "Note must be 1000 characters or fewer." });

        _logger.LogInformation("AR Workbench refresh requested for lab {LabId} by {User}", labId, user!.UserName);
        return Ok(await _repository.RunRefreshAsync(labId, user.UserName, request?.Note, ct));
    }

    public sealed class ArWorkbenchRunRequest
    {
        public string? Note { get; set; }
    }

    // ==========================================================================================
    // Follow-up notes - ARWorkbench.EditClaim. An agent reaches only their own claims (scope is
    // applied in SQL); the claim must not already be waiting for QA.
    // ==========================================================================================

    /// <summary>My Work quick-filter tiles and Follow-Up Management window tiles, over the caller's scope.</summary>
    [HttpGet("work-summary")]
    public async Task<ActionResult<ArWorkbenchWorkSummary>> WorkSummary([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetWorkSummaryAsync(labId, user!, ct));
    }

    // ==========================================================================================
    // CIP - Client Escalations - T061 / T062. The internal queue and decisions need
    // ARWorkbench.Approve (System Administrator, RCM Manager, Team Lead); the client's response
    // comes from a viewer (client) user, within their clinic / provider scope.
    // ==========================================================================================

    [HttpGet("cip")]
    public async Task<ActionResult<ArWorkbenchCipQueue>> CipQueue([FromQuery] ArWorkbenchCipFilter filter, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if (!user!.Permissions.Approve) return Forbidden("Only a Team Lead, RCM Manager or System Administrator can manage CIP escalations.");
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        return Ok(await _repository.GetCipQueueAsync(filter, user, clientView: false, ct));
    }

    /// <summary>The client's Escalation Requests: cases sent to them, what they answered, and what was sent back.</summary>
    [HttpGet("client-cip")]
    public async Task<ActionResult<ArWorkbenchCipQueue>> ClientCipQueue([FromQuery] ArWorkbenchCipFilter filter, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if (!CanViewClientCip(user!)) return Forbidden("Escalation Requests are for client users.");
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        return Ok(await _repository.GetCipQueueAsync(filter, user!, clientView: true, ct));
    }

    [HttpPost("cip/{caseId:long}/action")]
    public async Task<ActionResult> CipAction([FromRoute] long caseId, [FromQuery] int labId, [FromBody] ArWorkbenchCipActionRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (ArWorkbenchCipRules.Parse(request?.Action) is not { } action) return BadRequest(new { message = "Unknown CIP action." });
        if (ArWorkbenchCipRules.IsClientAction(action) ? !CanRespondToCip(user!) : !user!.Permissions.Approve)
            return Forbidden(ArWorkbenchCipRules.IsClientAction(action) ? "Only a client user can respond to an escalation." : "Only a Team Lead, RCM Manager or System Administrator can decide CIP escalations.");
        var noteError = ArWorkbenchCipRules.ValidateNote(action, request!.Note);
        if (noteError is not null) return BadRequest(new { message = noteError });

        var (outcome, caseNumber, status) = await _repository.CipActionAsync(labId, caseId, action, request.Note?.Trim() is { Length: > 0 } n ? n : null, user!, null, ct);
        return outcome switch
        {
            "notfound" => NotFound(new { message = "That escalation was not found or is outside your access." }),
            "wrongstage" => Conflict(new { message = $"{caseNumber} is now {status}; it may have just been decided. Reload." }),
            _ => Ok(new { message = CipMessage(action, caseNumber), status })
        };
    }

    /// <summary>Bulk Approve / Bulk Reject-Send Back over a mixed selection: each case gets the action for its own stage.</summary>
    [HttpPost("cip/bulk")]
    public async Task<ActionResult<ArWorkbenchCipBulkResult>> CipBulk([FromQuery] int labId, [FromBody] ArWorkbenchCipBulkRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!user!.Permissions.Approve) return Forbidden("Only a Team Lead, RCM Manager or System Administrator can decide CIP escalations.");
        var positive = (request?.Decision ?? string.Empty).Trim().ToLowerInvariant() switch { "approve" => true, "sendback" => false, _ => (bool?)null };
        if (positive is null) return BadRequest(new { message = "Decision must be approve or sendback." });
        var ids = (request!.CaseIds ?? []).Where(i => i > 0).Distinct().ToList();
        if (ids.Count == 0) return BadRequest(new { message = "Select the escalations." });
        if (ids.Count > 1000) return BadRequest(new { message = "At most 1,000 escalations at a time." });
        var note = request.Note?.Trim();
        if (positive == false && string.IsNullOrEmpty(note)) return BadRequest(new { message = "Add a reason - it is applied to every case sent back." });
        if (note is { Length: > ArWorkbenchCipRules.NoteMaxLength }) return BadRequest(new { message = "The note is too long." });
        var tagged = string.IsNullOrEmpty(note) ? "Bulk action - no additional note." : $"Bulk action: {note}";

        var stages = await _repository.GetCipStatusesAsync(labId, ids, user, ct);
        var batch = Guid.NewGuid();
        var result = new ArWorkbenchCipBulkResult();
        foreach (var id in ids)
        {
            if (!stages.TryGetValue(id, out var stage) || ArWorkbenchCipRules.ForStage(stage, positive.Value) is not { } action) { result.Skipped++; continue; }
            var (outcome, _, _) = await _repository.CipActionAsync(labId, id, action, tagged, user, batch, ct);
            if (outcome != "ok") { result.Skipped++; continue; }
            switch (action)
            {
                case ArWorkbenchCipAction.Approve: result.SentToClient++; break;
                case ArWorkbenchCipAction.Insufficient: result.ResentToClient++; break;
                default: result.ReturnedToAgent++; break;
            }
        }
        var parts = new List<string>();
        if (result.SentToClient > 0) parts.Add($"{result.SentToClient:N0} sent to the client");
        if (result.ReturnedToAgent > 0) parts.Add($"{result.ReturnedToAgent:N0} returned to the agent");
        if (result.ResentToClient > 0) parts.Add($"{result.ResentToClient:N0} re-sent to the client");
        if (result.Skipped > 0) parts.Add($"{result.Skipped:N0} skipped (not awaiting a decision)");
        result.Message = parts.Count == 0 ? "Nothing selected was awaiting a decision." : string.Join(" · ", parts) + ".";
        _logger.LogInformation("AR Workbench CIP bulk {Decision} lab {LabId} by {User}: {Message}", request.Decision, labId, user.UserName, result.Message);
        return Ok(result);
    }

    /// <summary>T063: bring the Denial Workflow's external escalations / responses into CIP Escalations (preview first).</summary>
    [HttpPost("cip/convert-legacy")]
    public async Task<ActionResult<ArWorkbenchLegacyCipResult>> ConvertLegacyCip([FromQuery] int labId, [FromQuery] bool preview, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!IsAdminOrManager(user!)) return Forbidden("Only an Administrator or RCM Manager can convert legacy escalations.");
        try
        {
            var r = await _repository.ConvertLegacyEscalationsAsync(labId, user!.UserName, preview, ct);
            r.Message = r.Note ?? (preview
                ? $"{r.Candidates:N0} external escalation(s) not yet converted: {r.SentToClient:N0} would be Sent to Client, {r.ClientResponded:N0} Client Responded, {r.ReturnedToAgent:N0} Returned to Agent; {r.NoMatchingClaim:N0} have no matching claim in the workbench and would be skipped."
                : $"{r.Converted:N0} escalation(s) converted ({r.SentToClient:N0} Sent to Client, {r.ClientResponded:N0} Client Responded, {r.ReturnedToAgent:N0} Returned to Agent); {r.NoMatchingClaim:N0} skipped - no matching claim.");
            if (!preview) _logger.LogInformation("AR Workbench legacy CIP conversion lab {LabId} by {User}: {Message}", labId, user.UserName, r.Message);
            return Ok(r);
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("not installed", StringComparison.OrdinalIgnoreCase))
        {
            return BadRequest(new { message = ex.Message });
        }
    }

    // ---- Client Management (T068) - ARWorkbench.ViewClientMgmt; activation also ManageSettings ---

    [HttpGet("clients")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchClientCard>>> Clients([FromQuery] int labId, CancellationToken ct)
    {
        var (user, labs, denied) = await ResolveClientAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var statuses = await _repository.GetClientStatusesAsync(ct);
        var cards = new List<ArWorkbenchClientCard>();
        foreach (var lab in labs)
        {
            var status = statuses.GetValueOrDefault(lab.LabId);
            cards.Add(new ArWorkbenchClientCard
            {
                LabId = lab.LabId, LabName = lab.LabName, IsActive = status?.IsActive ?? true, StatusNote = status?.StatusNote,
                ChangedBy = status?.ChangedBy, ChangedOn = status?.ChangedOn,
                Stats = await _repository.GetClientStatsAsync(lab.LabId, ct)
            });
        }
        return Ok(cards.OrderBy(c => c.LabName, StringComparer.OrdinalIgnoreCase).ToList());
    }

    [HttpPost("clients/{targetLabId:int}/active")]
    public async Task<ActionResult> SetClientActive([FromRoute] int targetLabId, [FromQuery] int labId, [FromBody] ArWorkbenchClientActiveRequest? request, CancellationToken ct)
    {
        var (user, labs, denied) = await ResolveClientAdminAsync(labId, ct);
        if (denied is not null) return denied;
        if (!user!.SiteAdmin && !user.Permissions.ManageSettings) return Forbidden("Only an administrator can activate or deactivate a client.");
        if (!labs.Any(l => l.LabId == targetLabId)) return Forbidden("You can only change clients you manage.");
        if (request is null) return BadRequest(new { message = "Send the new status." });
        var note = string.IsNullOrWhiteSpace(request.Note) ? null : request.Note.Trim();
        if (note is { Length: > 500 }) return BadRequest(new { message = "The note must be 500 characters or fewer." });
        if (!request.IsActive && note is null) return BadRequest(new { message = "Add a reason for deactivating the client." });
        var result = await _repository.SetClientActiveAsync(targetLabId, request.IsActive, note, user.UserName, ct);
        if (result.Status == ArWorkbenchSaveStatus.Ok)
            _logger.LogWarning("AR Workbench client lab {Target} {State} by {User}: {Note}", targetLabId, request.IsActive ? "reactivated" : "deactivated", user.UserName, note);
        return ToResult(result);
    }

    // Super Admin: every lab configured for the AR Workbench; others: their own dbo.UserLabs among those.
    private async Task<(ArWorkbenchUserContext? User, IReadOnlyList<ArWorkbenchLabOption> Labs, ActionResult? Denied)> ResolveClientAdminAsync(int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return (null, [], denied);
        if (!user!.Permissions.ViewClientMgmt) return (null, [], Forbidden("Only an AR Workbench System Administrator can manage clients."));
        var configured = _repository.GetConfiguredLabIds().ToHashSet();
        var every = (await _repository.GetAllLabsAsync(ct)).Where(l => configured.Contains(l.LabId)).ToList();
        var site = SiteAdminRole();
        var allLabs = site is not null && AllLabAdminRoles.Contains(site.Replace(" ", string.Empty).ToUpperInvariant());
        if (allLabs) return (user, every, null);
        var mine = user.LabUserId is int id ? await _repository.GetUserLabIdsAsync(id, ct) : new HashSet<int>();
        return (user, every.Where(l => mine.Contains(l.LabId)).ToList(), null);
    }

    // ---- Audit Logs (T067) - ARWorkbench.ViewAudit (System Administrator, RCM Manager) ---------

    [HttpGet("audit")]
    public async Task<ActionResult<ArWorkbenchAuditPage>> AuditLog([FromQuery] ArWorkbenchAuditFilter filter, [FromQuery] bool options, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if (!user!.Permissions.ViewAudit) return Forbidden("Only a System Administrator or RCM Manager can view the audit log.");
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        filter.PageSize = Math.Clamp(filter.PageSize, 5, 200);
        return Ok(await _repository.GetAuditLogAsync(filter, user, options, ct));
    }

    /// <summary>Every matching entry (up to 50,000) as Excel.</summary>
    [HttpGet("audit/export")]
    public async Task<ActionResult> AuditExport([FromQuery] ArWorkbenchAuditFilter filter, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if (!user!.Permissions.ViewAudit) return Forbidden("Only a System Administrator or RCM Manager can view the audit log.");
        filter.Page = 1;
        filter.PageSize = 50_000;
        var page = await _repository.GetAuditLogAsync(filter, user, false, ct);

        using var wb = new ClosedXML.Excel.XLWorkbook();
        var ws = wb.Worksheets.Add("Audit Log");
        string[] headers = ["Timestamp (UTC)", "Claim ID", "Client", "User", "Role", "Action", "Previous Value", "New Value", "Description", "System"];
        for (var i = 0; i < headers.Length; i++) DenialExcelTheme.StyleHeaderCell(ws.Cell(1, i + 1).SetValue(headers[i]));
        var row = 2;
        foreach (var a in page.Rows.Items)
        {
            ws.Cell(row, 1).Value = a.ActivityOn;
            ws.Cell(row, 2).SetValue(a.ClaimID);
            ws.Cell(row, 3).Value = a.LabName;
            ws.Cell(row, 4).Value = a.UserName;
            ws.Cell(row, 5).Value = a.RoleCode;
            ws.Cell(row, 6).Value = a.ActionType;
            ws.Cell(row, 7).Value = a.PreviousValue;
            ws.Cell(row, 8).Value = a.NewValue;
            ws.Cell(row, 9).Value = a.Detail;
            ws.Cell(row, 10).Value = a.IsSystem ? "Yes" : "No";
            row++;
        }
        ws.Column(1).Style.DateFormat.Format = "yyyy-mm-dd hh:mm:ss";
        ws.SheetView.FreezeRows(1);
        ws.Columns().AdjustToContents(1, 200);
        ws.Column(9).Width = Math.Min(ws.Column(9).Width, 90);
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        _logger.LogInformation("AR Workbench audit export lab {LabId} by {User}: {Rows} rows", filter.LabId, user.UserName, page.Rows.Items.Count);
        return File(ms.ToArray(), XlsxContentType, $"ARWorkbench_AuditLog_{DateTime.Now:yyyyMMdd_HHmm}.xlsx");
    }

    // ---- Client portal (T064 / T065 / T066) ------------------------------------------------------

    public const int MaxCipAttachments = 3;

    /// <summary>T064: the client's response with up to 3 attachments (multipart: note + files).</summary>
    [HttpPost("cip/{caseId:long}/respond")]
    [RequestSizeLimit(80_000_000)]
    public async Task<ActionResult> CipRespond([FromRoute] long caseId, [FromQuery] int labId, [FromForm] string? note, [FromForm] List<IFormFile>? files,
        [FromServices] IArWorkbenchDocumentStore store, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!CanRespondToCip(user!)) return Forbidden(CipReadOnlyMessage(user!));
        var noteError = ArWorkbenchCipRules.ValidateNote(ArWorkbenchCipAction.Respond, note);
        if (noteError is not null) return BadRequest(new { message = noteError });

        var uploads = (files ?? []).Where(f => f.Length > 0).ToList();
        if (uploads.Count > MaxCipAttachments) return BadRequest(new { message = $"Attach at most {MaxCipAttachments} files." });
        var (maxBytes, allowed) = await AttachmentRulesAsync(labId, ct);
        foreach (var f in uploads)
        {
            var ext = Path.GetExtension(f.FileName).TrimStart('.').ToLowerInvariant();
            if (!allowed.Contains(ext)) return BadRequest(new { message = $"{Path.GetFileName(f.FileName)}: file type .{ext} is not allowed ({string.Join(", ", allowed)})." });
            var error = await FileUploadGuard.ValidateDocumentAsync(f, maxBytes, ct);
            if (error is not null) return BadRequest(new { message = $"{Path.GetFileName(f.FileName)}: {error}" });
        }

        // Files first; if the response is refused (wrong stage, not found) they are removed again.
        var stored = new List<(string FileName, string? ContentType, StoredDocument Stored)>();
        try
        {
            foreach (var f in uploads)
            {
                await using var s = f.OpenReadStream();
                stored.Add((Path.GetFileName(f.FileName), f.ContentType, await store.SaveAsync(labId, s, Path.GetExtension(f.FileName), ct)));
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            foreach (var s in stored) store.Delete(s.Stored.Container, s.Stored.Path);
            _logger.LogError(ex, "AR Workbench attachment storage failed for lab {LabId}", labId);
            return StatusCode(StatusCodes.Status500InternalServerError, new { message = "The attachments could not be stored. Please contact support." });
        }

        var (outcome, caseNumber, status) = await _repository.CipActionAsync(labId, caseId, ArWorkbenchCipAction.Respond, note!.Trim(), user!, null, ct);
        if (outcome != "ok")
        {
            foreach (var s in stored) store.Delete(s.Stored.Container, s.Stored.Path);
            return outcome == "notfound"
                ? NotFound(new { message = "That escalation was not found or is outside your access." })
                : Conflict(new { message = $"{caseNumber} is {status}; it is no longer waiting for your response." });
        }
        if (stored.Count > 0)
            await _repository.AddCipResponseDocumentsAsync(labId, caseId, stored, user!, HttpContext.Connection.RemoteIpAddress?.ToString(), ct);
        return Ok(new { message = $"Response submitted for {caseNumber}{(stored.Count > 0 ? $" with {stored.Count} attachment(s)" : "")} - your AR team will review it.", status });
    }

    /// <summary>Download an attachment (scope-checked, logged). Clients reach only CIP responses.</summary>
    [HttpGet("documents/{documentId:long}")]
    public async Task<ActionResult> DownloadDocument([FromRoute] long documentId, [FromQuery] int labId, [FromServices] IArWorkbenchDocumentStore store, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        var doc = await _repository.GetDocumentForDownloadAsync(labId, documentId, user!, HttpContext.Connection.RemoteIpAddress?.ToString(), ct);
        if (doc is null) return NotFound(new { message = "Document not found." });
        var stream = store.OpenRead(doc.Value.Container, doc.Value.Path);
        if (stream is null) return NotFound(new { message = "The file is no longer in storage." });
        return File(stream, string.IsNullOrWhiteSpace(doc.Value.Info.ContentType) ? "application/octet-stream" : doc.Value.Info.ContentType!, doc.Value.Info.FileName);
    }

    private static readonly string[] CipTemplateHeaders =
        ["Case ID", "Claim ID", "Patient Acct", "DOS", "Rendering Provider", "Payer", "CIP Category", "Required Information", "Request From AR Team", "Response", "Attachment Notes"];

    /// <summary>T065: CSV of the requests awaiting the client's response, to fill the Response column.</summary>
    [HttpGet("client-cip/template")]
    public async Task<ActionResult> ClientCipTemplate([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!CanRespondToCip(user!)) return Forbidden(CipReadOnlyMessage(user!));
        var rows = new List<ArWorkbenchCipCaseRow>();
        for (var page = 1; ; page++)
        {
            var q = await _repository.GetCipQueueAsync(new ArWorkbenchCipFilter { LabId = labId, Status = ["Sent to Client"], Page = page, PageSize = 200, SortBy = "requestedOn" }, user!, clientView: true, ct);
            rows.AddRange(q.Rows.Items);
            if (q.Rows.Items.Count < 200 || rows.Count >= 5000) break;
        }
        var csv = ArWorkbenchCsv.Write(CipTemplateHeaders, rows.Select(r => (IReadOnlyList<string?>)new[]
        {
            r.CaseNumber, r.ClaimID, r.PatientID, r.DateOfService?.ToString("MM/dd/yyyy"), r.ReferringProvider, r.PayerName,
            r.CipCategory, r.RequiredInfo, r.CipComment, string.Empty, string.Empty
        }));
        return File(System.Text.Encoding.UTF8.GetPreamble().Concat(System.Text.Encoding.UTF8.GetBytes(csv)).ToArray(), "text/csv", $"EscalationRequests_ResponseTemplate_{DateTime.Now:yyyyMMdd}.csv");
    }

    /// <summary>T065: upload the filled template - every row with a Response answers its open request.</summary>
    [HttpPost("client-cip/template")]
    [RequestSizeLimit(10_000_000)]
    public async Task<ActionResult<ArWorkbenchCipBulkResponseResult>> ClientCipUpload([FromQuery] int labId, [FromForm] DenialCodeMasterImportRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!CanRespondToCip(user!)) return Forbidden(CipReadOnlyMessage(user!));
        var uploadError = await FileUploadGuard.ValidateCsvOrExcelAsync(request.File, 5 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });

        string text;
        using (var reader = new StreamReader(request.File!.OpenReadStream(), System.Text.Encoding.UTF8, detectEncodingFromByteOrderMarks: true))
            text = await reader.ReadToEndAsync(ct);
        var rows = ArWorkbenchCsv.Parse(text);
        if (rows.Count < 2) return BadRequest(new { message = "That file has no rows." });
        var header = rows[0].Select(h => h.Trim().ToLowerInvariant()).ToList();
        int iCase = header.IndexOf("case id"), iResp = header.IndexOf("response"), iNote = header.IndexOf("attachment notes");
        if (iCase < 0 || iResp < 0) return BadRequest(new { message = "That doesn't look like the response template - the Case ID / Response columns are missing." });

        var index = await _repository.GetClientCipIndexAsync(labId, user!, ct);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new ArWorkbenchCipBulkResponseResult();
        foreach (var row in rows.Skip(1))
        {
            string Cell(int i) => i >= 0 && i < row.Count ? row[i].Trim() : string.Empty;
            var caseNumber = Cell(iCase);
            if (caseNumber.Length == 0) continue;
            if (!index.TryGetValue(caseNumber, out var c)) { result.SkippedNotFound++; continue; }
            if (!seen.Add(caseNumber) || c.Status != "Sent to Client") { result.SkippedNotOpen++; continue; }
            var response = Cell(iResp);
            if (response.Length == 0) { result.SkippedBlank++; continue; }
            var notes = Cell(iNote);
            var combined = notes.Length > 0 ? $"{response}\n\nAttachment notes: {notes}" : response;
            if (combined.Length > ArWorkbenchCipRules.NoteMaxLength) { result.Errors.Add($"{caseNumber}: the response is longer than {ArWorkbenchCipRules.NoteMaxLength:N0} characters."); continue; }
            var (outcome, _, _) = await _repository.CipActionAsync(labId, c.CipCaseId, ArWorkbenchCipAction.Respond, combined, user!, null, ct);
            if (outcome == "ok") result.Updated++; else result.SkippedNotOpen++;
        }
        var parts = new List<string> { $"{result.Updated:N0} updated" };
        if (result.SkippedBlank > 0) parts.Add($"{result.SkippedBlank:N0} skipped - no response text");
        if (result.SkippedNotOpen > 0) parts.Add($"{result.SkippedNotOpen:N0} skipped - already responded or not awaiting a response");
        if (result.SkippedNotFound > 0) parts.Add($"{result.SkippedNotFound:N0} skipped - case not found (was the Case ID edited?)");
        if (result.Errors.Count > 0) parts.Add($"{result.Errors.Count:N0} with errors");
        result.Message = string.Join(" · ", parts) + ".";
        return Ok(result);
    }

    private async Task<(long MaxBytes, HashSet<string> Allowed)> AttachmentRulesAsync(int labId, CancellationToken ct)
    {
        var settings = (await _repository.GetMasterDataAsync(labId, ct)).Settings;
        var max = settings.TryGetValue("AttachmentMaxBytes", out var m) && long.TryParse(m, out var mb) && mb > 0 ? mb : 15L * 1024 * 1024;
        var types = settings.TryGetValue("AttachmentAllowedTypes", out var t) && !string.IsNullOrWhiteSpace(t) ? t : "pdf,png,jpg,jpeg,tif,tiff,gif,doc,docx,xls,xlsx,csv,txt";
        return (max, types.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(x => x.TrimStart('.').ToLowerInvariant()).ToHashSet());
    }

    /// <summary>
    /// T066: client (viewer) users with whole-client access respond; Clinic and Provider Viewers see
    /// their clinic's / provider's requests read-only. Administrators may respond on a client's behalf.
    /// </summary>
    private static bool CanRespondToCip(ArWorkbenchUserContext user) =>
        user.SiteAdmin || user.Permissions.ManageSettings
        || (user.RoleCode == "viewer" && user.Access.Level is not ("clinic" or "provider"));

    private static string CipReadOnlyMessage(ArWorkbenchUserContext user) =>
        user.RoleCode == "viewer" ? "Your access is limited to a clinic or provider, so escalation requests are read-only for you." : "Only a client user can respond to an escalation.";

    // Viewers (any scope) see their requests; the API decides who may respond.
    private static bool CanViewClientCip(ArWorkbenchUserContext user) => user.RoleCode == "viewer" || user.SiteAdmin || user.Permissions.ManageSettings;

    private static string CipMessage(ArWorkbenchCipAction action, string caseNumber) => action switch
    {
        ArWorkbenchCipAction.Approve => $"{caseNumber} approved - now visible to the client.",
        ArWorkbenchCipAction.Reject => $"{caseNumber} returned to the AR agent (not sent to the client).",
        ArWorkbenchCipAction.Respond => $"Response submitted for {caseNumber} - your AR team will review it.",
        ArWorkbenchCipAction.ApproveResponse => $"{caseNumber}: response approved - the claim is back with the AR agent.",
        _ => $"{caseNumber} marked insufficient - re-sent to the client (next round)."
    };

    // ==========================================================================================
    // QA Verification Queue - T059 / T060. ARWorkbench.QaDecide (System Administrator, RCM
    // Manager, Team Lead, QA Reviewer). Nobody decides their own note or a claim they hold.
    // ==========================================================================================

    [HttpGet("qa")]
    public async Task<ActionResult<ArWorkbenchQaQueue>> QaQueue([FromQuery] ArWorkbenchQaFilter filter, CancellationToken ct)
    {
        var (user, denied) = await ResolveQaUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        return Ok(await _repository.GetQaQueueAsync(filter, user!, ct));
    }

    [HttpPost("qa/{claimKey:long}/decision")]
    public async Task<ActionResult> QaDecision([FromRoute] long claimKey, [FromQuery] int labId, [FromBody] ArWorkbenchQaDecisionRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveQaUserAsync(labId, ct);
        if (denied is not null) return denied;
        var (decision, error) = ArWorkbenchQaRules.Validate(request, await QaErrorTypesAsync(labId, ct));
        if (decision is null) return BadRequest(new { message = error });

        var (outcome, claimId, esc, wo) = await _repository.DecideQaAsync(labId, claimKey, decision, user!, null, ct);
        return outcome switch
        {
            "notfound" => NotFound(new { message = "Claim not found." }),
            "notawaiting" => Conflict(new { message = $"Claim {claimId} has no note waiting for QA (it may have just been decided). Reload." }),
            "ownwork" => Conflict(new { message = "Business rule: you cannot QA your own work (you wrote this note or hold the claim)." }),
            _ => Ok(new
            {
                message = decision.Approve
                    ? $"QA approved {claimId}: claim Completed." + (esc ? " The CIP escalation is now Pending Approval." : "") + (wo ? " The write-off is approved; post it in the PMS." : "")
                    : $"QA rejected {claimId}: returned to the same agent under QA Rejected."
            })
        };
    }

    /// <summary>Approve Selected: each claim on its own; own work and already-decided claims are skipped and counted.</summary>
    [HttpPost("qa/bulk-approve")]
    public async Task<ActionResult<ArWorkbenchQaBulkResult>> QaBulkApprove([FromQuery] int labId, [FromBody] ArWorkbenchQaBulkApproveRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveQaUserAsync(labId, ct);
        if (denied is not null) return denied;
        var keys = (request?.ClaimKeys ?? []).Where(k => k > 0).Distinct().ToList();
        if (keys.Count == 0) return BadRequest(new { message = "Select the claims to approve." });
        if (keys.Count > 1000) return BadRequest(new { message = "Approve at most 1,000 claims at a time." });
        var note = string.IsNullOrWhiteSpace(request!.Note) ? null : request.Note.Trim();
        if (note is { Length: > ArWorkbenchQaRules.NoteMaxLength }) return BadRequest(new { message = "The note is too long." });

        var batch = Guid.NewGuid();
        var result = new ArWorkbenchQaBulkResult();
        foreach (var key in keys)
        {
            var (outcome, _, esc, wo) = await _repository.DecideQaAsync(labId, key, new ArWorkbenchQaDecision(true, null, note, null), user!, batch, ct);
            switch (outcome)
            {
                case "ok": result.Approved++; if (esc) result.EscalationsReleased++; if (wo) result.WriteOffsApproved++; break;
                case "ownwork": result.SkippedOwnWork++; break;
                case "notawaiting": result.SkippedNotAwaiting++; break;
                default: result.SkippedNotFound++; break;
            }
        }
        var parts = new List<string> { $"{result.Approved:N0} approved" };
        if (result.EscalationsReleased > 0) parts.Add($"{result.EscalationsReleased:N0} CIP escalation(s) now Pending Approval");
        if (result.WriteOffsApproved > 0) parts.Add($"{result.WriteOffsApproved:N0} write-off(s) approved");
        if (result.SkippedOwnWork > 0) parts.Add($"{result.SkippedOwnWork:N0} skipped - your own work");
        if (result.SkippedNotAwaiting > 0) parts.Add($"{result.SkippedNotAwaiting:N0} skipped - already decided");
        if (result.SkippedNotFound > 0) parts.Add($"{result.SkippedNotFound:N0} not found");
        result.Message = string.Join(" · ", parts) + ".";
        _logger.LogInformation("AR Workbench QA bulk approve lab {LabId} by {User}: {Message}", labId, user!.UserName, result.Message);
        return Ok(result);
    }

    private async Task<(ArWorkbenchUserContext? User, ActionResult? Denied)> ResolveQaUserAsync(int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return (null, denied);
        if (!user!.Permissions.QaDecide)
            return (null, Forbidden("Only a QA Reviewer, Team Lead, RCM Manager or System Administrator can use the QA Verification Queue."));
        return (user, null);
    }

    private async Task<IReadOnlyCollection<string>> QaErrorTypesAsync(int labId, CancellationToken ct)
    {
        var lists = (await _repository.GetMasterDataAsync(labId, ct)).Lists;
        return lists.TryGetValue("QA_ERROR_TYPE", out var list) && list.Count > 0
            ? list
            : ["Incomplete Documentation", "Incorrect Denial Category", "Missed Follow-Up", "Financial Update Error", "Other"];
    }

    // ==========================================================================================
    // Bulk Update (Excel) - T030. Template (pre-filled with the page's claims, the selection, or
    // blank) with dropdowns, then an upload that runs as a background job (the Denial Workflow's
    // upload job runner) and returns a per-row result with a downloadable log.
    // Assign To needs ARWorkbench.Assign; the follow-up columns need ARWorkbench.EditClaim.
    // ==========================================================================================

    [HttpPost("bulk-update/template")]
    public async Task<ActionResult> BulkUpdateTemplate([FromQuery] int labId, [FromBody] ArWorkbenchBulkTemplateRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!user!.Permissions.Assign && !user.Permissions.EditClaim)
            return Forbidden("Your role cannot assign claims or log follow-up notes.");

        var mode = (request?.Mode ?? "filtered").Trim().ToLowerInvariant();
        var claims = new List<ArWorkbenchClaimRow>();
        if (mode != "blank")
        {
            var filter = request?.Filter ?? new ArWorkbenchClaimFilter();
            filter.LabId = labId;
            if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
            HashSet<long>? wanted = null;
            if (mode == "selected")
            {
                wanted = (request?.ClaimKeys ?? []).Where(k => k > 0).ToHashSet();
                if (wanted.Count == 0) return BadRequest(new { message = "Select the claims to put in the template." });
                if (wanted.Count > ArWorkbenchBulkUpdate.MaxRows) return BadRequest(new { message = $"Select at most {ArWorkbenchBulkUpdate.MaxRows:N0} claims." });
                filter = new ArWorkbenchClaimFilter { LabId = labId, SortBy = filter.SortBy, SortDesc = filter.SortDesc };
                filter.ClaimKeys = wanted.ToList();
            }
            filter.PageSize = 500;
            for (filter.Page = 1; claims.Count < ArWorkbenchBulkUpdate.MaxRows; filter.Page++)
            {
                var page = await _repository.GetClaimsAsync(filter, user, ct);
                claims.AddRange(page.Items);
                if (page.Items.Count < filter.PageSize) break;
            }
            if (claims.Count > ArWorkbenchBulkUpdate.MaxRows) claims.RemoveRange(ArWorkbenchBulkUpdate.MaxRows, claims.Count - ArWorkbenchBulkUpdate.MaxRows);
        }

        var states = await _repository.GetBulkClaimStatesAsync(labId, claims.Select(c => c.ClaimID).ToList(), user, ct);
        var versions = states.Values.ToDictionary(s => s.ClaimKey, s => s.Version);
        var lists = (await _repository.GetMasterDataAsync(labId, ct)).Lists;
        var agents = user.Permissions.Assign ? await _repository.GetAgentsAsync(labId, ct) : [];
        var labName = LabsFromToken().FirstOrDefault(l => l.LabId == labId)?.LabName ?? $"Lab {labId}";
        var bytes = ArWorkbenchBulkUpdate.BuildTemplate(claims, versions, lists, agents,
            $"AR WORKBENCH - BULK UPDATE — {labName} — {claims.Count:N0} claim(s) — downloaded {DateTime.Now:MM/dd/yyyy HH:mm} by {user.UserName}");
        return File(bytes, XlsxContentType, $"ARWorkbench_BulkUpdate_{DateTime.Now:yyyyMMdd_HHmm}.xlsx");
    }

    [HttpPost("bulk-update")]
    [RequestSizeLimit(30_000_000)]
    public async Task<ActionResult<ClaimUploadStartResponse>> BulkUpdateUpload([FromQuery] int labId, [FromForm] DenialCodeMasterImportRequest request,
        [FromServices] IDenialWorkflowUploadJobService jobs, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!user!.Permissions.Assign && !user.Permissions.EditClaim)
            return Forbidden("Your role cannot assign claims or log follow-up notes.");
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });

        List<ArWorkbenchBulkRow>? rows;
        string? parseError;
        await using (var stream = request.File!.OpenReadStream())
            (rows, parseError) = ArWorkbenchBulkUpdate.Parse(stream);
        if (rows is null) return BadRequest(new { message = parseError });
        if (rows.Count == 0) return BadRequest(new { message = "The file has no rows to update." });

        var fileName = $"AR Workbench bulk update · {request.File.FileName}";
        _logger.LogInformation("AR Workbench bulk update upload by {User} for lab {LabId}: {File}, {Rows} rows", user.UserName, labId, request.File.FileName, rows.Count);
        var start = jobs.StartUpload(labId, fileName, rows.Count, user.UserName,
            (services, token) => ArWorkbenchBulkUpdate.ProcessAsync(services.GetRequiredService<IArWorkbenchRepository>(), labId, rows, user, token));
        return Ok(start);
    }

    [HttpGet("bulk-update/jobs/{jobId}")]
    public async Task<ActionResult<ClaimUploadStatusResponse>> BulkUpdateStatus([FromRoute] string jobId, [FromQuery] int labId,
        [FromServices] IDenialWorkflowUploadJobService jobs, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        var status = jobs.GetStatus(jobId, user!.UserName);
        if (status is null) return NotFound(new { message = "That upload is no longer available." });
        status.DownloadUrl = null;      // the workbench downloads the log from bulk-update/jobs/{id}/log
        return Ok(status);
    }

    [HttpGet("bulk-update/jobs/{jobId}/log")]
    public async Task<ActionResult> BulkUpdateLog([FromRoute] string jobId, [FromQuery] int labId,
        [FromServices] IDenialWorkflowUploadJobService jobs, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        var log = jobs.GetLogFile(jobId, user!.UserName);
        if (log is null) return NotFound(new { message = "The result log is no longer available." });
        return PhysicalFile(log.FilePath, log.ContentType, log.FileName.Replace("UploadLog_", "ARWorkbench_BulkUpdateLog_"));
    }

    // ==========================================================================================
    // Denial Code Descriptions - the central Denial Code Master (LRNMaster dbo.ARWB_DenialCodeMaster).
    // It serves every lab, so like the Super Master only an administrator maintains it. "Apply
    // Non-Collectible codes" changes one lab and needs ManageSettings there.
    // ==========================================================================================

    [HttpGet("code-master")]
    public async Task<ActionResult<ArWorkbenchCodeMasterData>> CodeMaster([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var (installed, rows) = await _repository.GetCodeMasterAsync(ct);
        return Ok(new ArWorkbenchCodeMasterData { Installed = installed, Rows = rows.ToList(), Options = await CodeMasterOptionsAsync(labId, rows, ct) });
    }

    [HttpPost("code-master")]
    public Task<ActionResult> AddCodeMasterRow([FromQuery] int labId, [FromBody] ArWorkbenchCodeMasterSaveRequest? request, CancellationToken ct)
        => SaveCodeMasterRow(labId, request, isNew: true, ct);

    [HttpPut("code-master")]
    public Task<ActionResult> UpdateCodeMasterRow([FromQuery] int labId, [FromBody] ArWorkbenchCodeMasterSaveRequest? request, CancellationToken ct)
        => SaveCodeMasterRow(labId, request, isNew: false, ct);

    private async Task<ActionResult> SaveCodeMasterRow(int labId, ArWorkbenchCodeMasterSaveRequest? request, bool isNew, CancellationToken ct)
    {
        var (user, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var (row, error) = ArWorkbenchCodeMasterRules.Validate(request);
        if (row is null) return BadRequest(new { message = error });
        return ToResult(await _repository.SaveCodeMasterRowAsync(row, isNew, user!.UserName, ct));
    }

    [HttpDelete("code-master")]
    public async Task<ActionResult> DeleteCodeMasterRow([FromQuery] int labId, [FromQuery] string? code, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var normalized = ArWorkbenchMasterRules.NormalizeDenialCode(code);
        if (normalized is null) return BadRequest(new { message = "Denial Code is required." });
        return ToResult(await _repository.DeleteCodeMasterRowAsync(normalized, ct));
    }

    /// <summary>
    /// Imports the business workbook as it is (any sheet with a "Denial Code" header; a
    /// "Non-collectible" sheet is the complete non-collectible list) or this screen's export.
    /// Nothing is written when any row has an error.
    /// </summary>
    [HttpPost("code-master/import")]
    [RequestSizeLimit(30_000_000)]
    public async Task<ActionResult<ArWorkbenchCodeMasterImportResult>> ImportCodeMaster([FromQuery] int labId, [FromForm] DenialCodeMasterImportRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });

        ArWorkbenchCodeMasterParsed? parsed;
        string? parseError;
        await using (var stream = request.File!.OpenReadStream())
            (parsed, parseError) = ArWorkbenchCodeMasterExcel.Parse(stream);
        if (parsed is null) return BadRequest(new { message = parseError });

        var (installed, rows) = await _repository.GetCodeMasterAsync(ct);
        if (!installed) return BadRequest(new { message = "The Denial Code master is not installed. Run LRN.ReportsApi/Sql/ArWorkbench/LRNMaster_02_ARWB_DenialCodeMaster.sql in LRNMaster." });

        var options = await CodeMasterOptionsAsync(labId, rows, ct);
        var merge = ArWorkbenchCodeMasterRules.Merge(rows.ToDictionary(r => r.DenialCode, StringComparer.OrdinalIgnoreCase), parsed, options);
        var result = new ArWorkbenchCodeMasterImportResult
        {
            RowsRead = merge.RowsRead, Inserted = merge.Inserts.Count, Updated = merge.Updates.Count, Unchanged = merge.Unchanged,
            NonCollectibleCodes = merge.NonCollectibleCodes, Errors = merge.Errors.Take(200).ToList(), Warnings = merge.Warnings.Take(200).ToList()
        };
        if (merge.Errors.Count > 0)
        {
            result.Inserted = result.Updated = 0;
            result.Message = $"Nothing was imported: {merge.Errors.Count} row(s) have errors. Fix them and import again.";
            return BadRequest(result);
        }

        var saved = await _repository.ApplyCodeMasterImportAsync(merge, user!.UserName, ct);
        if (saved.Status != ArWorkbenchSaveStatus.Ok) return ToResult(saved);
        _logger.LogInformation("AR Workbench code master import by {User}: {File}, {Inserted} added, {Updated} updated", user.UserName, request.File.FileName, result.Inserted, result.Updated);
        result.Message = $"{result.Inserted:N0} code(s) added, {result.Updated:N0} updated, {result.Unchanged:N0} unchanged."
            + (parsed.NonCollectibleCodes is not null ? $" Non-collectible list set to {merge.NonCollectibleCodes:N0} code(s) - use Apply to Lab to route claims." : "");
        return Ok(result);
    }

    [HttpGet("code-master/export")]
    public async Task<ActionResult> ExportCodeMaster([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var (_, rows) = await _repository.GetCodeMasterAsync(ct);
        return File(ArWorkbenchCodeMasterExcel.Build(rows, await CodeMasterOptionsAsync(labId, rows, ct)), XlsxContentType, "ARWorkbench_DenialCodeDescriptions.xlsx");
    }

    [HttpGet("code-master/template")]
    public async Task<ActionResult> CodeMasterTemplate([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var (_, rows) = await _repository.GetCodeMasterAsync(ct);
        return File(ArWorkbenchCodeMasterExcel.Build([], await CodeMasterOptionsAsync(labId, rows, ct)), XlsxContentType, "ARWorkbench_DenialCodeDescriptions_Template.xlsx");
    }

    /// <summary>Preview: how this lab's Non-Collectible list differs from the master.</summary>
    [HttpGet("code-master/non-collectible-sync")]
    public async Task<ActionResult<ArWorkbenchNonCollectibleSync>> NonCollectibleSyncPreview([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await PlanNonCollectibleSyncAsync(labId, ct));
    }

    [HttpPost("code-master/non-collectible-sync")]
    public async Task<ActionResult<ArWorkbenchNonCollectibleSync>> ApplyNonCollectibleSync([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var plan = await PlanNonCollectibleSyncAsync(labId, ct);
        if (plan.MasterCodes.Count == 0)
            return BadRequest(new { message = "The Denial Code master has no active Non-Collectible codes; applying it would empty this lab's list." });

        (plan.ClaimsRecalculated, plan.ClaimsWithNonCollectibleDenial) =
            await _repository.ApplyNonCollectibleCodesAsync(labId, plan.ToAdd, plan.ToDeactivate, user!.UserName, ct);
        _logger.LogInformation("AR Workbench non-collectible sync lab {LabId} by {User}: +{Add} -{Off}", labId, user.UserName, plan.ToAdd.Count, plan.ToDeactivate.Count);
        plan.Message = $"Non-Collectible list updated ({plan.ToAdd.Count} added, {plan.ToDeactivate.Count} switched off). "
            + $"{plan.ClaimsRecalculated:N0} claims recalculated; {plan.ClaimsWithNonCollectibleDenial:N0} have a non-collectible denial.";
        return Ok(plan);
    }

    private async Task<ArWorkbenchNonCollectibleSync> PlanNonCollectibleSyncAsync(int labId, CancellationToken ct)
    {
        var (_, rows) = await _repository.GetCodeMasterAsync(ct);
        var masterCodes = rows.Where(r => r.IsActive && r.IsNonCollectible).Select(r => r.DenialCode).ToList();
        var labCodes = await _repository.GetLabNonCollectibleCodesAsync(labId, ct);
        var (toAdd, toDeactivate, unchanged) = ArWorkbenchCodeMasterRules.PlanNonCollectibleSync(masterCodes, labCodes);
        return new ArWorkbenchNonCollectibleSync
        {
            MasterCodes = masterCodes.OrderBy(ArWorkbenchCodeMasterRules.SortKey, StringComparer.Ordinal).ToList(),
            ToAdd = toAdd, ToDeactivate = toDeactivate, Unchanged = unchanged
        };
    }

    /// <summary>Dropdowns: Denial Mapper lists (active values) and Action Categories in use plus the lab's Denial Root Causes.</summary>
    private async Task<ArWorkbenchCodeMasterOptions> CodeMasterOptionsAsync(int labId, IReadOnlyList<ArWorkbenchCodeMasterRow> rows, CancellationToken ct)
    {
        var mapper = await _mapperMasters.GetAllAsync(ct);
        List<string> Active(string type) => mapper.Lists.FirstOrDefault(l => string.Equals(l.Type, type, StringComparison.OrdinalIgnoreCase))?
            .Values.Where(v => v.IsActive).OrderBy(v => v.SortOrder).ThenBy(v => v.Value).Select(v => v.Value).ToList() ?? [];

        var masterData = await _repository.GetMasterDataAsync(labId, ct);
        var rootCauses = masterData.Lists.TryGetValue("DENIAL_ROOT_CAUSE", out var rc) ? rc : [];
        var actions = rows.Select(r => r.ActionCategory).Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v!)
            .Concat(rootCauses).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v, StringComparer.OrdinalIgnoreCase).ToList();
        return new ArWorkbenchCodeMasterOptions
        {
            ActionCategories = actions,
            DenialClassifications = Active("DenialClassification"),
            CoverageStatuses = Active("CoverageStatus"),
            ICDComplianceStatuses = Active("ICDComplianceStatus"),
            DenialValidities = Active("DenialValidity")
        };
    }

    /// <summary>The master rows for a claim's primary and line-level codes (normalized). Never fails the claim view.</summary>
    private async Task<IReadOnlyList<ArWorkbenchCodeMasterRow>> CodeMasterInfoForClaimAsync(ArWorkbenchClaimDetail detail, CancellationToken ct)
    {
        var codes = new List<string>();
        if (detail.Claim.TryGetValue("PrimaryDenialCode", out var primary) && primary is string p) codes.Add(p);
        if (detail.Claim.TryGetValue("LineDenialCodes", out var lineCodes) && lineCodes is string l)
            codes.AddRange(l.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        var normalized = codes.Select(ArWorkbenchMasterRules.NormalizeDenialCode).Where(c => c is not null).Select(c => c!).ToList();
        try
        {
            return await _repository.GetCodeMasterInfoAsync(normalized, ct);
        }
        catch (Exception ex) when (ex is Microsoft.Data.SqlClient.SqlException or InvalidOperationException)
        {
            _logger.LogWarning(ex, "AR Workbench: Denial Code master lookup failed; the claim view shows the claim without it.");
            return [];
        }
    }

    // ==========================================================================================
    // Automatic Adjustment (non-collectible / auto-adjust denials) - run by a System
    // Administrator, RCM Manager or Team Lead (ARWorkbench.Assign), as in the mockup's Work Queue.
    // ==========================================================================================

    private const int MaxAdjustmentKeys = 5000;

    /// <summary>The confirmation figures: how many claims and how much would be adjusted.</summary>
    [HttpPost("auto-adjustments/preview")]
    public Task<ActionResult<ArWorkbenchAdjustmentResult>> PreviewAutoAdjustments([FromQuery] int labId, [FromBody] ArWorkbenchAdjustmentRequest? request, CancellationToken ct)
        => RunAutoAdjustments(labId, request, previewOnly: true, ct);

    /// <summary>Single (one claim key), selected, or every eligible claim (no keys).</summary>
    [HttpPost("auto-adjustments/process")]
    public Task<ActionResult<ArWorkbenchAdjustmentResult>> ProcessAutoAdjustments([FromQuery] int labId, [FromBody] ArWorkbenchAdjustmentRequest? request, CancellationToken ct)
        => RunAutoAdjustments(labId, request, previewOnly: false, ct);

    private async Task<ActionResult<ArWorkbenchAdjustmentResult>> RunAutoAdjustments(int labId, ArWorkbenchAdjustmentRequest? request, bool previewOnly, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        var keys = request?.ClaimKeys?.Where(k => k > 0).Distinct().ToList();
        if (keys is { Count: 0 }) return BadRequest(new { message = "Select the claims to adjust, or send none to adjust every eligible claim." });
        if (keys is { Count: > MaxAdjustmentKeys }) return BadRequest(new { message = $"Adjust at most {MaxAdjustmentKeys:N0} selected claims at a time." });

        var result = await _repository.ProcessAutoAdjustmentsAsync(labId, keys, previewOnly, user!, ct);
        if (!previewOnly)
        {
            _logger.LogInformation("AR Workbench auto-adjustment: lab {LabId}, {Count} claims, {Amount} by {User}", labId, result.ClaimCount, result.TotalAmount, user!.UserName);
            result.Message = result.ClaimCount == 0
                ? "No eligible claims to adjust."
                : $"{result.ClaimCount:N0} claim(s) totaling ${result.TotalAmount.ToString("N2", System.Globalization.CultureInfo.InvariantCulture)} automatically adjusted and moved to Auto Adjustments. Post the adjustments in the PMS, then Mark as Posted.";
        }
        return Ok(result);
    }

    [HttpPost("auto-adjustments/mark-posted")]
    public async Task<ActionResult> MarkAdjustmentsPosted([FromQuery] int labId, [FromBody] ArWorkbenchAdjustmentRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        var keys = request?.ClaimKeys?.Where(k => k > 0).Distinct().ToList() ?? [];
        if (keys.Count == 0) return BadRequest(new { message = "Select the claims whose adjustment was posted." });
        if (keys.Count > MaxAdjustmentKeys) return BadRequest(new { message = $"Mark at most {MaxAdjustmentKeys:N0} claims at a time." });

        var posted = await _repository.MarkAdjustmentsPostedAsync(labId, keys, user!, ct);
        var skipped = keys.Count - posted;
        return Ok(new
        {
            postedClaims = posted,
            message = posted == 0
                ? "None of the selected claims has an adjustment waiting to be posted."
                : $"{posted:N0} claim(s) marked as posted in the PMS.{(skipped > 0 ? $" {skipped:N0} skipped (no adjustment pending)." : "")}"
        });
    }

    // ==========================================================================================
    // User Management - ARWorkbench.ManageUsers. Super Admin manages every lab; an AR Workbench
    // System Administrator (or Lab Admin) manages the labs assigned to them in dbo.UserLabs.
    // ==========================================================================================

    [HttpGet("users")]
    public async Task<ActionResult<ArWorkbenchUserManagement>> Users([FromQuery] int labId, CancellationToken ct)
    {
        var (manager, denied) = await ResolveUserManagerAsync(labId, ct);
        if (denied is not null) return denied;
        var users = (await _repository.GetManagedUsersAsync(manager!.User.LabUserId, manager.AllLabs, manager.Labs, ct)).ToList();
        return Ok(new ArWorkbenchUserManagement
        {
            Users = users,
            Labs = manager.Labs.ToList(),
            Roles = (await _repository.GetAssignableRolesAsync(ct)).ToList(),
            Managers = ManagerOptions(users),
            Teams = users.Select(u => u.TeamName).Where(t => !string.IsNullOrWhiteSpace(t)).Select(t => t!)
                .Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(t => t, StringComparer.OrdinalIgnoreCase).ToList(),
            AllLabs = manager.AllLabs
        });
    }

    /// <summary>T054 access picker: the clinics or referring providers on one lab's claims.</summary>
    [HttpGet("users/scope-options")]
    public async Task<ActionResult<IReadOnlyList<string>>> UserScopeOptions([FromQuery] int labId, [FromQuery] int targetLabId, [FromQuery] string? level, CancellationToken ct)
    {
        var (manager, denied) = await ResolveUserManagerAsync(labId, ct);
        if (denied is not null) return denied;
        if (!manager!.LabIds.Contains(targetLabId)) return Forbidden("You can only set access for labs you manage.");
        var lvl = string.Equals(level, "provider", StringComparison.OrdinalIgnoreCase) ? "provider" : "clinic";
        try
        {
            return Ok(await _repository.GetScopeOptionsAsync(targetLabId, lvl, ct));
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = $"That lab has no AR Workbench claims to choose from yet ({ex.Message})" });
        }
    }

    // Managers: active AR Workbench System Administrators, RCM Managers and Team Leads the caller can see.
    private static List<ArWorkbenchManagerOption> ManagerOptions(IEnumerable<ArWorkbenchManagedUser> users) => users
        .Where(u => u.IsActive && u.Roles.Any(r => ArWorkbenchUserRules.ManagerRoleLabels.Contains(r.Label, StringComparer.OrdinalIgnoreCase)))
        .Select(u => new ArWorkbenchManagerOption { LabUserId = u.LabUserId, UserName = u.UserName, Label = $"{u.UserName} ({string.Join(", ", u.Roles.Select(r => r.Label))})" })
        .OrderBy(m => m.UserName, StringComparer.OrdinalIgnoreCase).ToList();

    private async Task<(ArWorkbenchUserProfile? Profile, string? Error)> ValidateUserProfileAsync(UserManager manager, int roleId, IReadOnlyList<int> labIds,
        IReadOnlyList<ArWorkbenchUserScopeValue>? scopes, int? managerUserId, string? teamName, int? targetLabUserId, CancellationToken ct)
    {
        var roleScope = (await _repository.GetAssignableRolesAsync(ct)).FirstOrDefault(r => r.RoleId == roleId)?.Scope;
        var choices = new Dictionary<int, IReadOnlyList<string>>();
        if (roleScope is not null)
        {
            foreach (var lab in labIds)
            {
                try { choices[lab] = await _repository.GetScopeOptionsAsync(lab, roleScope, ct); }
                catch (InvalidOperationException) { return (null, $"Lab {manager.Labs.FirstOrDefault(l => l.LabId == lab)?.LabName ?? lab.ToString()} has no AR Workbench claims yet, so a clinic / provider cannot be chosen there."); }
            }
        }
        var allowedManagers = ManagerOptions(await _repository.GetManagedUsersAsync(manager.User.LabUserId, manager.AllLabs, manager.Labs, ct)).Select(m => m.LabUserId).ToHashSet();
        return ArWorkbenchUserRules.ValidateProfile(roleScope, labIds, scopes, choices, managerUserId, allowedManagers, targetLabUserId, teamName);
    }

    [HttpPost("users")]
    public async Task<ActionResult> CreateUser([FromQuery] int labId, [FromBody] ArWorkbenchCreateUserRequest? request, CancellationToken ct)
    {
        var (manager, denied) = await ResolveUserManagerAsync(labId, ct);
        if (denied is not null) return denied;
        if (request is null) return BadRequest(new { message = "Send the user to create." });

        var (userName, nameError) = ArWorkbenchUserRules.ValidateUserName(request.UserName);
        if (userName is null) return BadRequest(new { message = nameError });
        var passwordError = ArWorkbenchUserRules.ValidatePassword(request.Password);
        if (passwordError is not null) return BadRequest(new { message = passwordError });
        var (email, emailError) = ArWorkbenchUserRules.ValidateEmail(request.Email);
        if (email is null) return BadRequest(new { message = emailError });
        var roleError = await ValidateAssignableRoleAsync(request.RoleId, ct);
        if (roleError is not null) return BadRequest(new { message = roleError });
        var (labIds, labError) = ArWorkbenchUserRules.ValidateLabs(request.LabIds, manager!.LabIds);
        if (labIds is null) return BadRequest(new { message = labError });
        var (profile, profileError) = await ValidateUserProfileAsync(manager, request.RoleId!.Value, labIds, request.Scopes, request.ManagerUserId, request.TeamName, null, ct);
        if (profile is null) return BadRequest(new { message = profileError });

        var (result, id) = await _repository.CreateWorkbenchUserAsync(userName, ArWorkbenchUserRules.HashPassword(request.Password!), email,
            request.RoleId!.Value, labIds, profile, manager.LabIds, manager.User.UserName, ct);
        if (result.Status == ArWorkbenchSaveStatus.Ok)
            _logger.LogInformation("AR Workbench user {NewUser} (LabUserID {Id}) created by {Admin} for labs {Labs}", userName, id, manager.User.UserName, string.Join(",", labIds));
        return result.Status == ArWorkbenchSaveStatus.Ok ? Ok(new { message = result.Message, labUserId = id }) : ToResult(result);
    }

    [HttpPut("users/{labUserId:int}")]
    public async Task<ActionResult> UpdateUser([FromRoute] int labUserId, [FromQuery] int labId, [FromBody] ArWorkbenchUpdateUserRequest? request, CancellationToken ct)
    {
        var (manager, denied) = await ResolveUserManagerAsync(labId, ct);
        if (denied is not null) return denied;
        if (request is null) return BadRequest(new { message = "Send the changes." });

        var (email, emailError) = ArWorkbenchUserRules.ValidateEmail(request.Email);
        if (email is null) return BadRequest(new { message = emailError });
        var roleError = await ValidateAssignableRoleAsync(request.RoleId, ct);
        if (roleError is not null) return BadRequest(new { message = roleError });
        var (labIds, labError) = ArWorkbenchUserRules.ValidateLabs(request.LabIds, manager!.LabIds);
        if (labIds is null) return BadRequest(new { message = labError });
        string? hash = null;
        if (!string.IsNullOrEmpty(request.Password))
        {
            var passwordError = ArWorkbenchUserRules.ValidatePassword(request.Password);
            if (passwordError is not null) return BadRequest(new { message = passwordError });
            hash = ArWorkbenchUserRules.HashPassword(request.Password);
        }

        var (profile, profileError) = await ValidateUserProfileAsync(manager, request.RoleId!.Value, labIds, request.Scopes, request.ManagerUserId, request.TeamName, labUserId, ct);
        if (profile is null) return BadRequest(new { message = profileError });

        var result = await _repository.UpdateWorkbenchUserAsync(labUserId, email, request.RoleId!.Value, labIds, request.IsActive ?? true, hash, profile,
            manager.User.LabUserId, manager.AllLabs, manager.LabIds, manager.User.UserName, ct);
        if (result.Status == ArWorkbenchSaveStatus.Ok)
            _logger.LogInformation("AR Workbench user LabUserID {Id} updated by {Admin}{Reset}", labUserId, manager.User.UserName, hash is null ? "" : " (password reset)");
        return ToResult(result);
    }

    private sealed record UserManager(ArWorkbenchUserContext User, bool AllLabs, IReadOnlyList<ArWorkbenchLabOption> Labs, IReadOnlySet<int> LabIds);

    private async Task<(UserManager? Manager, ActionResult? Denied)> ResolveUserManagerAsync(int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return (null, denied);
        if (!user!.Permissions.ManageUsers)
            return (null, Forbidden("Only a Super Admin or an AR Workbench System Administrator can manage users."));

        // Super Admin (Admin / LRN Admin): every lab. Everyone else: the labs in their own dbo.UserLabs.
        var site = SiteAdminRole();
        var allLabs = site is not null && AllLabAdminRoles.Contains(site.Replace(" ", string.Empty).ToUpperInvariant());
        var every = await _repository.GetAllLabsAsync(ct);
        IReadOnlyList<ArWorkbenchLabOption> labs = every;
        if (!allLabs)
        {
            var mine = user.LabUserId is int id ? await _repository.GetUserLabIdsAsync(id, ct) : new HashSet<int>();
            labs = every.Where(l => mine.Contains(l.LabId)).ToList();
        }
        return (new UserManager(user, allLabs, labs, labs.Select(l => l.LabId).ToHashSet()), null);
    }

    private async Task<string?> ValidateAssignableRoleAsync(int? roleId, CancellationToken ct)
    {
        if (roleId is not > 0) return "Choose a role.";
        var roles = await _repository.GetAssignableRolesAsync(ct);
        return roles.Any(r => r.RoleId == roleId) ? null : "Choose one of the AR Workbench roles.";
    }

    // Saved Views: every AR Workbench user keeps their own named filter sets per screen.

    [HttpGet("saved-views")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchSavedView>>> SavedViews([FromQuery] int labId, [FromQuery] string? viewKey, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        var key = ArWorkbenchSavedViewRules.NormalizeViewKey(viewKey);
        if (key is null) return BadRequest(new { message = "Unknown screen for a saved view." });
        return Ok(await _repository.GetSavedViewsAsync(labId, user!.UserName, key, ct));
    }

    [HttpPost("saved-views")]
    public async Task<ActionResult> SaveView([FromQuery] int labId, [FromBody] ArWorkbenchSavedViewRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        var (view, error) = ArWorkbenchSavedViewRules.Validate(request);
        if (view is null) return BadRequest(new { message = error });
        var (result, id) = await _repository.SaveViewAsync(labId, user!.UserName, view, ct);
        return result.Status == ArWorkbenchSaveStatus.Ok ? Ok(new { message = result.Message, savedViewId = id }) : ToResult(result);
    }

    [HttpPut("saved-views/{savedViewId:int}")]
    public async Task<ActionResult> UpdateSavedView([FromRoute] int savedViewId, [FromQuery] int labId, [FromBody] ArWorkbenchSavedViewUpdate? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        string? name = null;
        if (request?.ViewName is not null)
        {
            name = ArWorkbenchSavedViewRules.NormalizeName(request.ViewName);
            if (name is null) return BadRequest(new { message = $"Give the view a name of 1 to {ArWorkbenchSavedViewRules.MaxNameLength} characters." });
        }
        if (name is null && request?.IsDefault is null) return BadRequest(new { message = "Nothing to change." });
        return ToResult(await _repository.UpdateSavedViewAsync(labId, user!.UserName, savedViewId, name, request!.IsDefault, ct));
    }

    [HttpDelete("saved-views/{savedViewId:int}")]
    public async Task<ActionResult> DeleteSavedView([FromRoute] int savedViewId, [FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return ToResult(await _repository.DeleteSavedViewAsync(labId, user!.UserName, savedViewId, ct));
    }

    [HttpPost("claims/{claimKey:long}/follow-ups")]
    public async Task<ActionResult<ArWorkbenchFollowUpResult>> LogFollowUp([FromRoute] long claimKey, [FromQuery] int labId, [FromBody] ArWorkbenchFollowUpRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!user!.Permissions.EditClaim) return Forbidden("Your role cannot log follow-up notes.");

        var (status, message, result) = await _repository.LogFollowUpAsync(labId, claimKey, request ?? new(), user, ct);
        return status switch
        {
            ArWorkbenchSaveStatus.Ok => Ok(result),
            ArWorkbenchSaveStatus.NotFound => NotFound(new { message }),
            ArWorkbenchSaveStatus.Invalid => BadRequest(new { message }),
            _ => Conflict(new { message })
        };
    }

    /// <summary>
    /// Every claim matching the Work Queue filters (or every claim in the caller's scope when no
    /// filter is set), as Excel - not only the page on screen. Capped at ArWorkbenchClaimExcel.MaxRows.
    /// </summary>
    [HttpGet("claims/export")]
    public async Task<ActionResult> ExportClaims([FromQuery] ArWorkbenchClaimFilter filter, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });

        var rows = new List<ArWorkbenchClaimRow>();
        filter.PageSize = 500;
        var total = 0;
        for (filter.Page = 1; rows.Count < ArWorkbenchClaimExcel.MaxRows; filter.Page++)
        {
            var page = await _repository.GetClaimsAsync(filter, user!, ct);
            total = page.TotalCount;
            rows.AddRange(page.Items);
            if (page.Items.Count < filter.PageSize) break;
        }
        if (rows.Count > ArWorkbenchClaimExcel.MaxRows) rows.RemoveRange(ArWorkbenchClaimExcel.MaxRows, rows.Count - ArWorkbenchClaimExcel.MaxRows);

        var labName = (await _workflowService.GetLabsForUserAsync(CurrentUserName(), ct)).FirstOrDefault(l => l.LabId == filter.LabId)?.LabName ?? $"Lab {filter.LabId}";
        var bytes = ArWorkbenchClaimExcel.Build(rows, $"AR Workbench claims — {labName} — {DateTime.Now:MM/dd/yyyy HH:mm}", total > rows.Count);
        _logger.LogInformation("AR Workbench claim export for lab {LabId} by {User}: {Rows} of {Total} rows", filter.LabId, user!.UserName, rows.Count, total);
        return File(bytes, XlsxContentType, $"ARWorkbench_Claims_{DateTime.Now:yyyyMMdd_HHmm}.xlsx");
    }

    /// <summary>Denial Analysis Report on the Data Processing screen: current + previous sync week.</summary>
    [HttpGet("data-processing/insights")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchInsightRow>>> Insights([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (!IsAdminOrManager(user!)) return Forbidden("Only an Administrator or RCM Manager can view data processing.");
        return Ok(await _repository.GetInsightsAsync(labId, ct));
    }

    // ---- Timely-filing limits (Master Values) - ARWorkbench.ManageSettings ----------------------

    [HttpGet("settings/tfl")]
    public async Task<ActionResult<ArWorkbenchTflSettings>> TflSettings([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetTflSettingsAsync(labId, ct));
    }

    [HttpPost("settings/tfl")]
    public Task<ActionResult> AddTflThreshold([FromQuery] int labId, [FromBody] ArWorkbenchTflThresholdRequest? request, CancellationToken ct)
        => SaveTflThreshold(labId, request, isAdd: true, ct);

    [HttpPut("settings/tfl")]
    public Task<ActionResult> UpdateTflThreshold([FromQuery] int labId, [FromBody] ArWorkbenchTflThresholdRequest? request, CancellationToken ct)
        => SaveTflThreshold(labId, request, isAdd: false, ct);

    private async Task<ActionResult> SaveTflThreshold(int labId, ArWorkbenchTflThresholdRequest? request, bool isAdd, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var name = request?.FinancialClass?.Trim() ?? string.Empty;
        if (name.Length == 0 || name.Length > 200) return BadRequest(new { message = "Financial class is required (200 characters or fewer)." });
        if (request!.ThresholdDays is not (>= 1 and <= 3650)) return BadRequest(new { message = "Days must be a whole number from 1 to 3,650." });
        if (!isAdd && string.IsNullOrWhiteSpace(request.OriginalFinancialClass)) return BadRequest(new { message = "The financial class being edited was not supplied." });
        return ToResult(await _repository.SaveTflThresholdAsync(labId, isAdd ? null : request.OriginalFinancialClass, name, request.ThresholdDays!.Value, user!.UserName, ct));
    }

    [HttpDelete("settings/tfl")]
    public async Task<ActionResult> DeleteTflThreshold([FromQuery] int labId, [FromQuery] string? financialClass, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (string.IsNullOrWhiteSpace(financialClass)) return BadRequest(new { message = "No financial class was specified." });
        return ToResult(await _repository.DeleteTflThresholdAsync(labId, financialClass, ct));
    }

    [HttpPut("settings/tfl/defaults")]
    public async Task<ActionResult> SaveTflDefaults([FromQuery] int labId, [FromBody] ArWorkbenchTflDefaultsRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (request?.DefaultDays is not (>= 1 and <= 3650)) return BadRequest(new { message = "Default limit must be a whole number from 1 to 3,650 days." });
        if (request.RiskWindowDays is not (>= 0 and <= 365)) return BadRequest(new { message = "Risk window must be a whole number from 0 to 365 days." });
        return ToResult(await _repository.SaveTflDefaultsAsync(labId, request.DefaultDays.Value, request.RiskWindowDays.Value, user!.UserName, ct));
    }

    // ==========================================================================================
    // Assignment Management - ARWorkbench.Assign (System Administrator, RCM Manager, Team Lead).
    // The claim tables on the screen use GET claims (assignedOnly / minDaysUntouched filters).
    // ==========================================================================================

    [HttpGet("assignment")]
    public async Task<ActionResult<ArWorkbenchAssignmentOverview>> AssignmentOverview([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetAssignmentOverviewAsync(labId, user!, ct));
    }

    /// <summary>The users claims can be assigned to: AR Agents and Team Leads with access to the lab.</summary>
    [HttpGet("assignment/agents")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchAgent>>> AssignableAgents([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetAgentsAsync(labId, ct));
    }

    [HttpPost("assignment/preview")]
    public async Task<ActionResult<ArWorkbenchBatchPreview>> PreviewBatch([FromQuery] int labId, [FromBody] ArWorkbenchBatchPreviewRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.PreviewBatchAsync(labId, (request?.Criteria ?? new()).Clean(), user!, ct));
    }

    [HttpPost("assignment/batches")]
    public async Task<ActionResult<ArWorkbenchAssignResult>> CreateBatch([FromQuery] int labId, [FromBody] ArWorkbenchBatchCreateRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        if (request is null) return BadRequest(new { message = "The batch was not supplied." });

        request.Criteria = (request.Criteria ?? new()).Clean();
        // As the mockup: a batch is built from criteria, never from the whole pool by accident.
        if (request.Criteria.IsEmpty) return BadRequest(new { message = "Choose at least one criterion for the batch." });
        if ((request.BatchName?.Trim().Length ?? 0) > 200) return BadRequest(new { message = "Batch name must be 200 characters or fewer." });
        if (request.MaxClaims is < 1 or > SqlArWorkbenchRepository.MaxClaimsPerAssignment)
            return BadRequest(new { message = $"Claims per batch must be between 1 and {SqlArWorkbenchRepository.MaxClaimsPerAssignment:N0}." });
        var problem = ValidateAssignment(request.Note, request.DueDate);
        if (problem is not null) return BadRequest(new { message = problem });

        var (agent, agentDenied) = await ResolveAgentAsync(labId, request.AgentUser, ct);
        if (agentDenied is not null) return agentDenied;

        var result = await _repository.CreateBatchAsync(labId, request, agent!, user!, ct);
        if (result.AssignmentBatchId is null) return Conflict(new { message = result.Message });
        _logger.LogInformation("AR Workbench batch {Batch} for lab {LabId}: {Count} claims to {Agent} by {User}", result.BatchNumber, labId, result.AssignedCount, agent!.UserName, user!.UserName);
        return Ok(result);
    }

    [HttpGet("assignment/batches")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchBatch>>> Batches([FromQuery] int labId, [FromQuery] string? status, [FromQuery] int top = 100, CancellationToken ct = default)
    {
        var (_, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetBatchesAsync(labId, status, top, ct));
    }

    [HttpGet("assignment/batches/{batchId:int}")]
    public async Task<ActionResult<ArWorkbenchBatchDetail>> BatchDetail([FromRoute] int batchId, [FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        var detail = await _repository.GetBatchDetailAsync(labId, batchId, user!, ct);
        return detail is null ? NotFound(new { message = "Batch not found." }) : Ok(detail);
    }

    [HttpPost("assignment/batches/{batchId:int}/cancel")]
    public async Task<ActionResult> CancelBatch([FromRoute] int batchId, [FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        return ToResult(await _repository.CancelBatchAsync(labId, batchId, user!.UserName, ct));
    }

    /// <summary>Assign or reassign selected claims (Unassigned Claims, Bulk Reassign and the Work Queue).</summary>
    [HttpPost("assignment/assign")]
    public async Task<ActionResult<ArWorkbenchAssignResult>> AssignClaims([FromQuery] int labId, [FromBody] ArWorkbenchAssignRequest? request, CancellationToken ct)
    {
        var (user, denied) = await ResolveAssignerAsync(labId, ct);
        if (denied is not null) return denied;
        var keys = request?.ClaimKeys?.Where(k => k > 0).Distinct().ToList() ?? [];
        if (keys.Count == 0) return BadRequest(new { message = "Select at least one claim." });
        if (keys.Count > SqlArWorkbenchRepository.MaxClaimsPerAssignment)
            return BadRequest(new { message = $"Assign at most {SqlArWorkbenchRepository.MaxClaimsPerAssignment:N0} claims at a time." });
        var problem = ValidateAssignment(request!.Note, request.DueDate);
        if (problem is not null) return BadRequest(new { message = problem });

        var (agent, agentDenied) = await ResolveAgentAsync(labId, request.AgentUser, ct);
        if (agentDenied is not null) return agentDenied;

        request.ClaimKeys = keys;
        var result = await _repository.AssignClaimsAsync(labId, request, agent!, user!, ct);
        _logger.LogInformation("AR Workbench assign for lab {LabId}: {Assigned} assigned, {Reassigned} reassigned to {Agent} by {User}",
            labId, result.AssignedCount, result.ReassignedCount, agent!.UserName, user!.UserName);
        return Ok(result);
    }

    private async Task<(ArWorkbenchUserContext? User, ActionResult? Denied)> ResolveAssignerAsync(int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return (null, denied);
        if (!user!.Permissions.Assign)
            return (null, Forbidden("Only a System Administrator, RCM Manager or Team Lead can assign claims."));
        return (user, null);
    }

    /// <summary>The target must be an AR Agent or Team Lead with access to this lab.</summary>
    private async Task<(ArWorkbenchAgent? Agent, ActionResult? Denied)> ResolveAgentAsync(int labId, string? agentUser, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(agentUser)) return (null, BadRequest(new { message = "Choose the agent to assign to." }));
        var agents = await _repository.GetAgentsAsync(labId, ct);
        var agent = agents.FirstOrDefault(a => string.Equals(a.UserName, agentUser.Trim(), StringComparison.OrdinalIgnoreCase));
        return agent is null
            ? (null, BadRequest(new { message = $"\"{agentUser}\" is not an AR Agent or Team Lead for this lab." }))
            : (agent, null);
    }

    private static string? ValidateAssignment(string? note, DateTime? dueDate)
    {
        if ((note?.Trim().Length ?? 0) > 1000) return "Note must be 1000 characters or fewer.";
        if (dueDate is { } d && d.Date < DateTime.UtcNow.Date.AddDays(-1)) return "Due date cannot be in the past.";
        return null;
    }

    // ==========================================================================================
    // Master File Maintenance - ARWorkbench.ManageSettings only, reads included (the read carries
    // usage counts and inactive values; everyone else gets the active lists from /master-data).
    // Rules mirror the Denial Workflow's Workflow Master Values and Denial Code Master screens.
    // ==========================================================================================

    [HttpGet("masters")]
    public async Task<ActionResult<ArWorkbenchMasterValuesResponse>> MasterValues([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetMasterValuesAsync(labId, ct));
    }

    [HttpPost("masters/{type}")]
    public async Task<ActionResult> AddMasterValue([FromRoute] string type, [FromQuery] int labId, [FromBody] ArWorkbenchMasterValueSaveRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var master = ArWorkbenchMasterRules.Find(type);
        if (master is null) return UnknownList(type);

        var validation = ArWorkbenchMasterRules.Validate(master, request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });
        return ToResult(await _repository.AddMasterValueAsync(labId, master, validation.Result!, user!.UserName, ct));
    }

    [HttpPut("masters/{type}")]
    public async Task<ActionResult> UpdateMasterValue([FromRoute] string type, [FromQuery] int labId, [FromBody] ArWorkbenchMasterValueSaveRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var master = ArWorkbenchMasterRules.Find(type);
        if (master is null) return UnknownList(type);
        // The original value travels in the body, not the route: values such as "Medical Records / Notes" contain slashes.
        if (string.IsNullOrWhiteSpace(request?.OriginalValue))
            return BadRequest(new { message = "The value being edited was not supplied. Reload the page and try again." });

        var validation = ArWorkbenchMasterRules.Validate(master, request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });
        return ToResult(await _repository.UpdateMasterValueAsync(labId, master, request.OriginalValue, validation.Result!, user!.UserName, ct));
    }

    [HttpDelete("masters/{type}")]
    public async Task<ActionResult> DeleteMasterValue([FromRoute] string type, [FromQuery] int labId, [FromQuery] string? value, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var master = ArWorkbenchMasterRules.Find(type);
        if (master is null) return UnknownList(type);
        if (string.IsNullOrWhiteSpace(value)) return BadRequest(new { message = "No value was specified to delete." });
        return ToResult(await _repository.DeleteMasterValueAsync(labId, master, value, ct));
    }

    [HttpGet("denial-codes")]
    public async Task<ActionResult<ArWorkbenchPagedResult<ArWorkbenchDenialCodeRow>>> DenialCodes([FromQuery] ArWorkbenchDenialCodeQuery query, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(query.LabId, ct);
        if (denied is not null) return denied;
        if ((query.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        return Ok(await _repository.GetDenialCodesAsync(query, ct));
    }

    /// <summary>Primary denial codes on synced claims with no active mapping (they fall into 'Other').</summary>
    [HttpGet("denial-codes/unmapped")]
    public async Task<ActionResult<IReadOnlyList<ArWorkbenchUnmappedDenialCode>>> UnmappedDenialCodes([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetUnmappedDenialCodesAsync(labId, ct));
    }

    [HttpGet("denial-codes/impact")]
    public async Task<ActionResult<ArWorkbenchDenialCodeImpact>> DenialCodeImpact([FromQuery] int labId, [FromQuery] string? code, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (string.IsNullOrWhiteSpace(code) || code.Length > 200) return BadRequest(new { message = "Denial Code is required." });
        return Ok(await _repository.GetDenialCodeImpactAsync(labId, code, ct));
    }

    [HttpPost("denial-codes")]
    public async Task<ActionResult> AddDenialCode([FromQuery] int labId, [FromBody] ArWorkbenchDenialCodeSaveRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var validation = ArWorkbenchMasterRules.ValidateDenialCode(request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });
        return ToResult(await _repository.SaveDenialCodeAsync(labId, null, validation.Result!, user!.UserName, ct));
    }

    [HttpPut("denial-codes")]
    public async Task<ActionResult> UpdateDenialCode([FromQuery] int labId, [FromBody] ArWorkbenchDenialCodeSaveRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (string.IsNullOrWhiteSpace(request?.OriginalDenialCode))
            return BadRequest(new { message = "The denial code being edited was not supplied. Reload the page and try again." });
        var validation = ArWorkbenchMasterRules.ValidateDenialCode(request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });
        return ToResult(await _repository.SaveDenialCodeAsync(labId, request.OriginalDenialCode, validation.Result!, user!.UserName, ct));
    }

    [HttpDelete("denial-codes")]
    public async Task<ActionResult> DeleteDenialCode([FromQuery] int labId, [FromQuery] string? code, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        if (string.IsNullOrWhiteSpace(code) || code.Length > 200) return BadRequest(new { message = "No denial code was specified to delete." });
        return ToResult(await _repository.DeleteDenialCodeAsync(labId, code, ct));
    }

    [HttpPost("denial-codes/import")]
    [RequestSizeLimit(30_000_000)]
    public async Task<ActionResult<ArWorkbenchDenialCodeImportResult>> ImportDenialCodes([FromQuery] int labId, [FromForm] DenialCodeMasterImportRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });

        await using var stream = request.File!.OpenReadStream();
        var (rows, skipped, fileError) = ArWorkbenchDenialCodeExcel.Parse(stream);
        if (fileError is not null) return BadRequest(new { message = fileError });

        _logger.LogInformation("AR Workbench denial code import for lab {LabId} by {User}: {Rows} rows from {File}", labId, user!.UserName, rows.Count, request.File.FileName);
        return Ok(await _repository.ImportDenialCodesAsync(labId, rows, skipped, user.UserName, ct));
    }

    [HttpGet("denial-codes/template")]
    public async Task<ActionResult> DenialCodeTemplate([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var bytes = ArWorkbenchDenialCodeExcel.BuildTemplate(await ActiveDenialCategoriesAsync(labId, ct));
        return File(bytes, XlsxContentType, "ARWorkbench_DenialCodeMaster_Template.xlsx");
    }

    [HttpGet("denial-codes/export")]
    public async Task<ActionResult> ExportDenialCodes([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        var rows = await _repository.GetAllDenialCodesAsync(labId, ct);
        var bytes = ArWorkbenchDenialCodeExcel.BuildExport(rows, await ActiveDenialCategoriesAsync(labId, ct));
        return File(bytes, XlsxContentType, $"ARWorkbench_DenialCodeMaster_{DateTime.UtcNow:yyyyMMdd}.xlsx");
    }

    /// <summary>
    /// "Apply to claims": dbo.ARWB_usp_LoadClaimsFromSource with @ReprocessAll = 1, which re-derives
    /// every claim's denial category, workflow template and queue from the current master data. It is
    /// also a full data sync (the same run Data Processing starts), so it is logged in the run history.
    /// </summary>
    [HttpPost("denial-codes/apply")]
    public async Task<ActionResult<ArWorkbenchRefreshRun>> ApplyDenialCodes([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return denied;
        _logger.LogInformation("AR Workbench master-data reprocess requested for lab {LabId} by {User}", labId, user!.UserName);
        return Ok(await _repository.RunRefreshAsync(labId, user.UserName, "Master data applied to claims (Denial Code Master)", ct, reprocessAll: true));
    }

    // ==========================================================================================
    // Denial Mapper Super Master and its dropdown lists - the Denial Workflow's own central data in
    // LRNMaster (dbo.DenialMapperSuperMaster, dbo.DenialMapperLookupMaster,
    // dbo.DenialMapperActionCategoryMaster). Every call goes through the Denial Workflow's
    // repositories, so validation, the soft delete, the import and dbo.DenialMapperAuditLog are
    // exactly the Denial Mapper's. Lab masters still change only through the Denial Mapper's
    // Push to Labs.
    //
    // These lists serve every lab, so on top of ARWorkbench.ManageSettings the caller needs the
    // Denial Mapper's own edit right: a role containing "Admin" (DenialMapperController.IsAdmin).
    // ==========================================================================================

    [HttpGet("super-master")]
    public async Task<ActionResult<PagedResult<DenialMapperRecord>>> SuperMaster([FromQuery] int labId, [FromQuery] string? search, [FromQuery] string? classification,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        if ((search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        // The Denial Mapper's search is a LIKE pattern; an empty search is "no filter".
        var pattern = string.IsNullOrWhiteSpace(search) ? null : search.Trim();
        return Ok(await _mapper.SuperMasterAsync(pattern, string.IsNullOrWhiteSpace(classification) ? null : classification, page, pageSize, ct));
    }

    [HttpGet("super-master/options")]
    public async Task<ActionResult> SuperMasterOptions([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var masterData = await _mapper.MasterDataAsync(ct);
        var classifications = await _mapper.ClassificationsAsync(null, ct);
        return Ok(new { masterData, classifications });
    }

    [HttpPost("super-master")]
    public async Task<ActionResult> AddSuperMaster([FromQuery] int labId, [FromBody] DenialMapperSaveRequest request, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var error = ValidateSuperMaster(request);
        if (error is not null) return BadRequest(new { message = error });
        var id = await _mapper.SaveSuperMasterAsync(null, request, MapperUser(), MapperRole(), ct);
        return Ok(new { id, message = $"Denial code {request.DenialCode.Trim()} added to the Super Master. It reaches lab masters on the next Push to Labs." });
    }

    [HttpPut("super-master/{id:long}")]
    public async Task<ActionResult> UpdateSuperMaster([FromRoute] long id, [FromQuery] int labId, [FromBody] DenialMapperSaveRequest request, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var error = ValidateSuperMaster(request);
        if (error is not null) return BadRequest(new { message = error });
        try
        {
            await _mapper.SaveSuperMasterAsync(id, request, MapperUser(), MapperRole(), ct);
        }
        catch (KeyNotFoundException)
        {
            return NotFound(new { message = "This Super Master mapping no longer exists — someone may have deleted it. Reload the page." });
        }
        return Ok(new { message = $"Denial code {request.DenialCode.Trim()} updated in the Super Master. It reaches lab masters on the next Push to Labs." });
    }

    [HttpDelete("super-master/{id:long}")]
    public async Task<ActionResult> DeleteSuperMaster([FromRoute] long id, [FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        try
        {
            await _mapper.DeleteSuperMasterAsync(id, MapperUser(), MapperRole(), ct);
        }
        catch (KeyNotFoundException)
        {
            return NotFound(new { message = "This Super Master mapping no longer exists. Reload the page." });
        }
        return Ok(new { message = "Super Master mapping deleted. The deletion reaches lab masters on the next Push to Labs." });
    }

    [HttpPost("super-master/import")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<DenialCodeMasterImportResult>> ImportSuperMaster([FromQuery] int labId, [FromForm] DenialCodeMasterImportRequest request, CancellationToken ct)
    {
        var (user, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });

        _logger.LogInformation("AR Workbench Super Master import by {User}: {File}", user!.UserName, request.File!.FileName);
        await using var stream = request.File.OpenReadStream();
        return Ok(await _mapper.ImportSuperMasterAsync(stream, request.File.FileName, MapperUser(), MapperRole(), ct));
    }

    [HttpGet("super-master/export")]
    public async Task<ActionResult> ExportSuperMaster([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        return File(await _mapperExcel.ExportAsync(ct), XlsxContentType, "DenialActionSuperMaster.xlsx");
    }

    [HttpGet("super-master/template")]
    public async Task<ActionResult> SuperMasterTemplate([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        return File(_mapperExcel.BuildImportTemplate(), XlsxContentType, "DenialActionSuperMaster_Template.xlsx");
    }

    /// <summary>The seven Denial Mapper dropdown lists, as the Denial Workflow's Workflow Master Values screen shows them.</summary>
    [HttpGet("mapper-masters")]
    public async Task<ActionResult<WorkflowMasterValuesResponse>> MapperMasters([FromQuery] int labId, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _mapperMasters.GetAllAsync(ct));
    }

    [HttpPost("mapper-masters/{type}")]
    public async Task<ActionResult> AddMapperMaster([FromRoute] string type, [FromQuery] int labId, [FromBody] WorkflowMasterValueSaveRequest request, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var master = WorkflowMasterValueRules.Find(type);
        if (master is null) return UnknownList(type);
        var validation = WorkflowMasterValueRules.Validate(master, request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });
        return ToResult(await _mapperMasters.AddAsync(master, validation.Result!, MapperUser(), MapperRole(), ct));
    }

    [HttpPut("mapper-masters/{type}")]
    public async Task<ActionResult> UpdateMapperMaster([FromRoute] string type, [FromQuery] int labId, [FromBody] WorkflowMasterValueSaveRequest request, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var master = WorkflowMasterValueRules.Find(type);
        if (master is null) return UnknownList(type);
        if (string.IsNullOrWhiteSpace(request?.OriginalValue))
            return BadRequest(new { message = "The value being edited was not supplied. Reload the page and try again." });
        var validation = WorkflowMasterValueRules.Validate(master, request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });
        return ToResult(await _mapperMasters.UpdateAsync(master, request.OriginalValue, validation.Result!, MapperUser(), MapperRole(), ct));
    }

    [HttpDelete("mapper-masters/{type}")]
    public async Task<ActionResult> DeleteMapperMaster([FromRoute] string type, [FromQuery] int labId, [FromQuery] string? value, CancellationToken ct)
    {
        var (_, denied) = await ResolveMapperAdminAsync(labId, ct);
        if (denied is not null) return denied;
        var master = WorkflowMasterValueRules.Find(type);
        if (master is null) return UnknownList(type);
        if (string.IsNullOrWhiteSpace(value)) return BadRequest(new { message = "No value was specified to delete." });
        return ToResult(await _mapperMasters.DeleteAsync(master, value, MapperUser(), MapperRole(), ct));
    }

    private async Task<(ArWorkbenchUserContext? User, ActionResult? Denied)> ResolveMapperAdminAsync(int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveSettingsUserAsync(labId, ct);
        if (denied is not null) return (null, denied);
        var roles = PayerMasterRoles.RoleNames(User);
        if (!roles.Any(r => r.Replace(" ", string.Empty).Contains("ADMIN", StringComparison.OrdinalIgnoreCase)))
            return (null, Forbidden("The Denial Mapper Super Master and its lists serve every lab; only an administrator can maintain them."));
        return (user, null);
    }

    // Same required fields as DenialMapperController.Validate.
    private static string? ValidateSuperMaster(DenialMapperSaveRequest? q) =>
        q is null || new[] { q.DenialCode, q.ActionCode, q.ActionCategory, q.Task, q.RecommendedAction, q.SLA, q.Priority }.Any(string.IsNullOrWhiteSpace)
            ? "Complete all required fields: Denial Code, Action Category (and its Action Code), Task, Recommended Action, SLA and Priority."
            : null;

    private string MapperUser() => CurrentUserName() is { Length: > 0 } name ? name : "ARWorkbench";
    private string MapperRole() => string.Join(", ", PayerMasterRoles.RoleNames(User));

    private ActionResult ToResult(WorkflowMasterSaveResult result) => result.Status switch
    {
        WorkflowMasterSaveStatus.Ok => Ok(new { message = result.Message }),
        WorkflowMasterSaveStatus.NotFound => NotFound(new { message = result.Message }),
        _ => Conflict(new { message = result.Message })
    };

    private const string XlsxContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    private async Task<IReadOnlyList<string>> ActiveDenialCategoriesAsync(int labId, CancellationToken ct)
    {
        var data = await _repository.GetMasterDataAsync(labId, ct);
        return data.Lists.TryGetValue(ArWorkbenchMasterRules.DenialCategoryType, out var list) ? list : [];
    }

    private async Task<(ArWorkbenchUserContext? User, ActionResult? Denied)> ResolveSettingsUserAsync(int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return (null, denied);
        if (!user!.Permissions.ManageSettings)
            return (null, Forbidden("Only an AR Workbench administrator can maintain master values and denial codes."));
        return (user, null);
    }

    private ActionResult ToResult(ArWorkbenchSaveResult result) => result.Status switch
    {
        ArWorkbenchSaveStatus.Ok => Ok(new { message = result.Message }),
        ArWorkbenchSaveStatus.NotFound => NotFound(new { message = result.Message }),
        ArWorkbenchSaveStatus.Invalid => BadRequest(new { message = result.Message }),
        _ => Conflict(new { message = result.Message })
    };

    private ActionResult UnknownList(string type) => NotFound(new { message = $"\"{type}\" is not an AR Workbench master list." });

    // ==========================================================================================
    // Identity, lab access, workbench role
    // ==========================================================================================

    private async Task<(ArWorkbenchUserContext? User, ActionResult? Denied)> ResolveUserAsync(int labId, CancellationToken ct)
    {
        if (labId <= 0) return (null, BadRequest(new { message = "LabId is required." }));
        if (!await CanAccessLabAsync(labId, ct))
            return (null, Forbidden("Access denied. You can open the AR Workbench only for your authorized labs."));

        var user = await _repository.GetUserContextAsync(labId, CurrentUserName(), SiteAdminRole(), ct);
        if (user is null)
            return (null, Forbidden("You do not have an AR Workbench role. Ask an administrator to give you one of the 'AR Workbench - ...' roles."));

        // T068: a deactivated client stays open only to the administrators who can reactivate it.
        if ((await _repository.GetInactiveClientLabIdsAsync(ct)).Contains(labId))
        {
            if (!user.SiteAdmin && !user.Permissions.ManageSettings)
                return (null, Forbidden("This client is deactivated in the AR Workbench. Contact your administrator."));
            user.ClientActive = false;
        }
        return (user, null);
    }

    private static bool IsAdminOrManager(ArWorkbenchUserContext user)
        => user.RoleCode is "admin" or "manager";

    private ObjectResult Forbidden(string message)
        => StatusCode(StatusCodes.Status403Forbidden, new { message });

    // Compared with case and spaces removed, as elsewhere: "Super Admin", "SuperAdmin", "superadmin".
    private static readonly string[] AllLabAdminRoles = ["SUPERADMIN", "ADMIN", "LRNADMIN"];
    private const string LabAdminRole = "LABADMIN";

    /// <summary>
    /// The caller's LRN Metrics admin role, or null. Super Admin (and the equivalent Admin / LRN
    /// Admin) and Lab Admin open every AR Workbench page. Which labs they can open is NOT decided
    /// here: that stays with <see cref="CanAccessLabAsync"/>, and the token lists every lab for a
    /// Super Admin but only the assigned labs for a Lab Admin.
    /// </summary>
    private string? SiteAdminRole()
    {
        var roles = User.Claims
            .Where(c => c.Type == ClaimTypes.Role || string.Equals(c.Type, "role", StringComparison.OrdinalIgnoreCase))
            .Select(c => c.Value)
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .ToList();
        static string Norm(string r) => r.Replace(" ", string.Empty).ToUpperInvariant();
        return roles.FirstOrDefault(r => AllLabAdminRoles.Contains(Norm(r)))
            ?? roles.FirstOrDefault(r => Norm(r) == LabAdminRole);
    }

    private async Task<bool> CanAccessLabAsync(int labId, CancellationToken ct)
    {
        // No lab bypass for admins: the token already lists every lab for a Super Admin and only
        // the assigned labs for a Lab Admin.
        var tokenLabs = LabsFromToken();
        if (tokenLabs.Count > 0) return tokenLabs.Any(l => l.LabId == labId);
        var labs = await _workflowService.GetLabsForUserAsync(CurrentUserName(), ct);
        return labs.Any(lab => lab.LabId == labId);
    }

    private List<DenialWorkflowLabOption> LabsFromToken()
    {
        var ids = User.Claims.Where(c => string.Equals(c.Type, "lab_id", StringComparison.OrdinalIgnoreCase)).Select(c => c.Value).ToList();
        var names = User.Claims.Where(c => string.Equals(c.Type, "lab_name", StringComparison.OrdinalIgnoreCase)).Select(c => c.Value).ToList();
        var labs = new List<DenialWorkflowLabOption>();
        for (var i = 0; i < ids.Count; i++)
        {
            if (!int.TryParse(ids[i], out var id) || id <= 0 || labs.Any(l => l.LabId == id)) continue;
            labs.Add(new DenialWorkflowLabOption { LabId = id, LabName = i < names.Count ? names[i] : $"Lab {id}" });
        }
        return labs;
    }

    private string CurrentUserName()
        => FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? FirstClaim(ClaimTypes.Email, "email") ?? string.Empty;

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
