using System.Security.Claims;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using LRN.ReportsApi.Services.ArWorkbench;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// AR Workbench (new denial application, React app LRN.ARWorkbench). Reads the [arwb] schema in
/// each lab database, populated from dbo.ClaimLevelData / dbo.LineLevelData by
/// arwb.usp_LoadClaimsFromSource. Separate from the Denial Workflow (/api/denialworkflow) and its
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
    private readonly ILogger<ArWorkbenchController> _logger;

    public ArWorkbenchController(IArWorkbenchRepository repository, IDenialWorkflowService workflowService, ILogger<ArWorkbenchController> logger)
    {
        _repository = repository;
        _workflowService = workflowService;
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

    /// <summary>Runs arwb.usp_LoadClaimsFromSource: claim-level rows with a denial code -> arwb.Claim, lines -> arwb.ClaimLine.</summary>
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
