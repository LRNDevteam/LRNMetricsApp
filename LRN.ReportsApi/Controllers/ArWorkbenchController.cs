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
        var fromToken = LabsFromToken();
        if (fromToken.Count > 0) return Ok(fromToken);
        return Ok(await _workflowService.GetLabsForUserAsync(CurrentUserName(), ct));
    }

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

    [HttpGet("claims")]
    public async Task<ActionResult<ArWorkbenchPagedResult<ArWorkbenchClaimRow>>> Claims([FromQuery] ArWorkbenchClaimFilter filter, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(filter.LabId, ct);
        if (denied is not null) return denied;
        if ((filter.Search?.Length ?? 0) > 200) return BadRequest(new { message = "Search must be 200 characters or fewer." });
        return Ok(await _repository.GetClaimsAsync(filter, user!, ct));
    }

    /// <summary>Option lists (with counts) for the Work Queue's multi-select filters, over the caller's scope.</summary>
    [HttpGet("claims/filter-options")]
    public async Task<ActionResult<ArWorkbenchFilterOptions>> ClaimFilterOptions([FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        return Ok(await _repository.GetFilterOptionsAsync(labId, user!, ct));
    }

    [HttpGet("claims/{claimKey:long}")]
    public async Task<ActionResult<ArWorkbenchClaimDetail>> ClaimDetail([FromRoute] long claimKey, [FromQuery] int labId, CancellationToken ct)
    {
        var (user, denied) = await ResolveUserAsync(labId, ct);
        if (denied is not null) return denied;
        var detail = await _repository.GetClaimDetailAsync(labId, claimKey, user!, ct);
        // Out-of-scope and missing look the same, so a scoped user cannot probe for claim keys.
        return detail is null ? NotFound(new { message = "Claim not found." }) : Ok(detail);
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
