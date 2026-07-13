using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

[Authorize]
public sealed class MasterValuesController : Controller
{
    private readonly IMasterValuesApiClient _api;

    public MasterValuesController(IMasterValuesApiClient api)
    {
        _api = api;
    }

    // ── Payer Master roles (Requirements Spec §2) ─────────────────────────────
    private bool HasAnyRole(params string[] roles) => roles.Any(r => User.IsInRole(r));
    private bool IsLrnAdmin => HasAnyRole("Admin", "LRN Admin", "LRNAdmin");
    private bool IsPayerPolicyAdmin => HasAnyRole("Payer Policy Admin", "PayerPolicyAdmin");
    private bool IsReportsAnalyst => HasAnyRole("Reports Analyst", "ReportsAnalyst");
    private bool IsReportsManager => HasAnyRole("Reports Manager", "ReportsManager");
    private bool IsEtl => HasAnyRole("ETL", "Etl");

    // Payer Policy Insurance Master: LRN Admin / Payer Policy Admin full; Reports Analyst subject to approval; ETL view-only; Reports Manager no access.
    private bool CanViewPolicy => IsLrnAdmin || IsPayerPolicyAdmin || IsReportsAnalyst || IsEtl;
    private bool CanWritePolicy => IsLrnAdmin || IsPayerPolicyAdmin || IsReportsAnalyst;
    private bool PolicyRequiresApproval => IsReportsAnalyst && !IsLrnAdmin && !IsPayerPolicyAdmin;

    // Lab Insurance Master: LRN Admin / Reports Manager full; Reports Analyst subject to approval; ETL view-only; Payer Policy Admin no access.
    private bool CanViewLab => IsLrnAdmin || IsReportsManager || IsReportsAnalyst || IsEtl;
    private bool CanWriteLab => IsLrnAdmin || IsReportsManager || IsReportsAnalyst;
    private bool LabRequiresApproval => IsReportsAnalyst && !IsLrnAdmin && !IsReportsManager;

    private string RoleLabel =>
        IsLrnAdmin ? "LRN Admin"
        : IsPayerPolicyAdmin && IsReportsManager ? "Payer Policy Admin / Reports Manager"
        : IsPayerPolicyAdmin ? "Payer Policy Admin"
        : IsReportsManager ? "Reports Manager"
        : IsReportsAnalyst ? "Reports Analyst"
        : IsEtl ? "ETL (view only)"
        : "User";

    [HttpGet]
    public IActionResult InsurancePayerMaster()
    {
        if (!CanViewLab) return Forbid();
        ViewData["PageLabel"] = "Lab Insurance Master";
        return View(new MasterValuesPageViewModel
        {
            Title = "Lab Insurance Master",
            ApiBasePath = Url.Action(nameof(InsurancePayersData)) ?? string.Empty,
            RoleLabel = RoleLabel,
            CanWrite = CanWriteLab,
            RequiresApproval = LabRequiresApproval
        });
    }

    [HttpGet]
    public IActionResult PayerPolicyInsuranceMaster()
    {
        if (!CanViewPolicy) return Forbid();
        ViewData["PageLabel"] = "Payer Policy Insurance Master";
        return View(new MasterValuesPageViewModel
        {
            Title = "Payer Policy Insurance Master",
            IsPolicy = true,
            ApiBasePath = Url.Action(nameof(PolicyPayersData)) ?? string.Empty,
            RoleLabel = RoleLabel,
            CanWrite = CanWritePolicy,
            RequiresApproval = PolicyRequiresApproval
        });
    }

    [HttpGet]
    public async Task<IActionResult> InsurancePayersData(CancellationToken ct)
    {
        if (!CanViewLab) return Forbid();
        return Json(await _api.GetInsurancePayersAsync(Request.Query, ct));
    }

    [HttpGet]
    public async Task<IActionResult> PolicyPayersData(CancellationToken ct)
    {
        if (!CanViewPolicy) return Forbid();
        return Json(await _api.GetPolicyPayersAsync(Request.Query, ct));
    }

    // ── Payer mapping intelligence (pipeline suggestions / typeahead / explicit actions) ──
    // Mapping confirmations write directly (Global Payer ID + PayerAlias + audit), so the three
    // actions follow the same authority as bulk import; approval-routed roles keep the legacy
    // Confirm Mapping flow which goes through the approval queue.
    private bool CanMapDirect => CanWriteLab && !LabRequiresApproval;

    /// <summary>Counts for the navbar notification bell (Mapped / Pending Review / No Match / Unmapped).</summary>
    [HttpGet]
    public async Task<IActionResult> MappingSummary(CancellationToken ct)
    {
        if (!CanViewLab) return Forbid();
        return Json(await _api.GetMappingSummaryAsync(ct));
    }

    [HttpGet]
    public async Task<IActionResult> MappingSuggestions(int id, CancellationToken ct)
    {
        if (!CanViewLab) return Forbid();
        var response = await _api.GetMappingSuggestionsAsync(id, ct);
        return response is null ? NotFound() : Json(response);
    }

    [HttpGet]
    public async Task<IActionResult> MappingSearch(string? q, CancellationToken ct)
    {
        if (!CanViewLab) return Forbid();
        if (string.IsNullOrWhiteSpace(q)) return Json(Array.Empty<PayerPolicySearchResultDto>());
        return Json(await _api.SearchPolicyPayersRankedAsync(q, ct));
    }

    [HttpPost]
    public async Task<IActionResult> ApproveMapping(int id, [FromBody] PayerMappingActionRequest request, CancellationToken ct)
    {
        if (!CanMapDirect) return Forbid();
        try { return Json(await _api.ApproveMappingAsync(id, request, ct)); }
        catch (InvalidOperationException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPost]
    public async Task<IActionResult> ManualMapping(int id, [FromBody] PayerMappingActionRequest request, CancellationToken ct)
    {
        if (!CanMapDirect) return Forbid();
        try { return Json(await _api.ManualMapAsync(id, request, ct)); }
        catch (InvalidOperationException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPost]
    public async Task<IActionResult> RejectMapping(int id, CancellationToken ct)
    {
        if (!CanMapDirect) return Forbid();
        try { return Json(await _api.RejectMappingAsync(id, ct)); }
        catch (InvalidOperationException ex) { return BadRequest(new { message = ex.Message }); }
    }

    // ── Payer Service Audit: worker run history + manual trigger ─────────────

    [HttpGet]
    public IActionResult PayerServiceAudit()
    {
        if (!CanViewLab) return Forbid();
        ViewData["PageLabel"] = "Payer Service Audit";
        return View(new MasterValuesPageViewModel
        {
            Title = "Payer Service Audit",
            RoleLabel = RoleLabel,
            CanWrite = CanWriteLab && !LabRequiresApproval // gates the Run Service button
        });
    }

    [HttpGet]
    public async Task<IActionResult> PayerServiceRuns(int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        if (!CanViewLab) return Forbid();
        return Json(await _api.GetPayerServiceRunsAsync(page, pageSize, ct));
    }

    [HttpGet]
    public async Task<IActionResult> PayerServiceRunDetails(Guid id, CancellationToken ct)
    {
        if (!CanViewLab) return Forbid();
        var response = await _api.GetPayerServiceRunAsync(id, ct);
        return response is null ? NotFound() : Json(response);
    }

    [HttpPost]
    public async Task<IActionResult> TriggerPayerService(string? scope, CancellationToken ct)
    {
        if (!CanMapDirect) return Forbid();
        var effectiveScope = string.Equals(scope, "All", StringComparison.OrdinalIgnoreCase) ? "All" : "UnmappedPending";
        try { return Json(await _api.TriggerPayerServiceRunAsync(effectiveScope, ct)); }
        catch (InvalidOperationException ex) { return BadRequest(new { message = ex.Message }); }
    }

    // Lightweight lookup used by the Lab Insurance Master "Review Match" flow.
    // Reports Manager has no access to the Payer Policy master screen, but per spec §5.2
    // may still confirm Global Payer ID mappings, so this is gated on either master.
    [HttpGet]
    public async Task<IActionResult> PolicyPayerLookup(CancellationToken ct)
    {
        if (!CanViewLab && !CanViewPolicy) return Forbid();
        var result = await _api.GetPolicyPayersAsync(Request.Query, ct);
        return Json(new
        {
            items = result.Items.Select(x => new
            {
                x.PPInsuranceMasterId,
                x.PayerNameRaw,
                x.PayerNameNormalized,
                x.GlobalPayerId,
                x.GlobalPayerCode,
                x.PayerGroupCode,
                x.BenefitAdminCode,
                x.BenefitAdministrator,
                x.PlanType,
                x.PayerState,
                x.PayerShortCode,
                x.IsActive
            })
        });
    }

    [HttpGet]
    public async Task<IActionResult> Labs(CancellationToken ct)
    {
        if (!CanViewLab && !CanViewPolicy) return Forbid();
        return Json(await _api.GetLabsAsync(ct));
    }

    [HttpGet]
    public async Task<IActionResult> InsurancePayer(int id, CancellationToken ct)
    {
        if (!CanViewLab) return Forbid();
        var row = await _api.GetInsurancePayerAsync(id, ct);
        return row is null ? NotFound() : Json(row);
    }

    [HttpGet]
    public async Task<IActionResult> PolicyPayer(int id, CancellationToken ct)
    {
        if (!CanViewPolicy) return Forbid();
        var row = await _api.GetPolicyPayerAsync(id, ct);
        return row is null ? NotFound() : Json(row);
    }

    [HttpPost]
    public async Task<IActionResult> SaveInsurancePayer([FromBody] InsurancePayerMasterDto dto, int? id, CancellationToken ct)
    {
        if (!CanWriteLab) return Forbid();
        try
        {
            await _api.SaveInsurancePayerAsync(id, dto, ct);
            return Json(new { success = true, pendingApproval = LabRequiresApproval });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> SavePolicyPayer([FromBody] PayerPolicyInsuranceMasterDto dto, int? id, CancellationToken ct)
    {
        if (!CanWritePolicy) return Forbid();
        try
        {
            await _api.SavePolicyPayerAsync(id, dto, ct);
            return Json(new { success = true, pendingApproval = PolicyRequiresApproval });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
    }

    // Spec §5.3: deactivation only — deactivated payers are never reactivated.
    // Re-adding a payer creates a new record with a new Global Payer ID.
    [HttpPost]
    public async Task<IActionResult> InsuranceStatus(int id, string? isActive, CancellationToken ct)
    {
        if (!CanWriteLab) return Forbid();
        if (!string.Equals(isActive, "Inactive", StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { message = "Deactivated payers cannot be reactivated. Re-add the payer as a new record instead." });
        await _api.UpdateInsuranceStatusAsync(id, "Inactive", ct);
        return Json(new { success = true, pendingApproval = LabRequiresApproval });
    }

    [HttpPost]
    public async Task<IActionResult> PolicyStatus(int id, string? isActive, CancellationToken ct)
    {
        if (!CanWritePolicy) return Forbid();
        if (!string.Equals(isActive, "Inactive", StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { message = "Deactivated payers cannot be reactivated. Re-add the payer as a new record instead." });
        await _api.UpdatePolicyStatusAsync(id, "Inactive", ct);
        return Json(new { success = true, pendingApproval = PolicyRequiresApproval });
    }

    [HttpPost]
    public async Task<IActionResult> ImportInsurance(IFormFile file, CancellationToken ct)
    {
        if (!CanWriteLab || LabRequiresApproval) return Forbid();
        var uploadError = await FileUploadGuard.ValidateExcelAsync(file, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        return Json(await _api.ImportInsuranceAsync(file, ct));
    }

    [HttpPost]
    public async Task<IActionResult> ResolveInsuranceConflicts([FromBody] GlobalPayerIdConflictResolutionRequest request, CancellationToken ct)
    {
        if (!CanWriteLab || LabRequiresApproval) return Forbid();
        return Json(await _api.ResolveInsuranceConflictsAsync(request, ct));
    }

    [HttpPost]
    public async Task<IActionResult> ImportPolicy(IFormFile file, CancellationToken ct)
    {
        if (!CanWritePolicy || PolicyRequiresApproval) return Forbid();
        var uploadError = await FileUploadGuard.ValidateExcelAsync(file, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        return Json(await _api.ImportPolicyAsync(file, ct));
    }

    // ── Payer Master workflow: approval queue, audit trail, notifications ───

    private bool CanApprovePolicy => IsLrnAdmin || IsPayerPolicyAdmin;
    private bool CanApproveLab => IsLrnAdmin || IsReportsManager;
    private bool IsApprover => CanApprovePolicy || CanApproveLab;
    private bool HasAnyMasterAccess => CanViewPolicy || CanViewLab;

    [HttpGet]
    public IActionResult ApprovalQueue()
    {
        if (!IsApprover && !IsReportsAnalyst) return Forbid();
        ViewData["PageLabel"] = "Approval Queue";
        return View(new MasterValuesPageViewModel
        {
            Title = "Approval Queue",
            RoleLabel = RoleLabel,
            CanWrite = IsApprover // approvers can act; analysts see their own submissions read-only
        });
    }

    [HttpGet]
    public IActionResult AuditTrail()
    {
        if (!HasAnyMasterAccess) return Forbid();
        ViewData["PageLabel"] = "Payer Master Audit Trail";
        return View(new MasterValuesPageViewModel { Title = "Audit Trail", RoleLabel = RoleLabel });
    }

    [HttpGet]
    public IActionResult PayerMasterNotifications()
    {
        if (!HasAnyMasterAccess) return Forbid();
        ViewData["PageLabel"] = "Payer Master Notifications";
        return View(new MasterValuesPageViewModel { Title = "Notifications", RoleLabel = RoleLabel });
    }

    [HttpGet]
    public async Task<IActionResult> ApprovalsData(CancellationToken ct)
    {
        if (!IsApprover && !IsReportsAnalyst) return Forbid();
        return Json(await _api.GetApprovalsAsync(Request.Query, ct));
    }

    [HttpPost]
    public async Task<IActionResult> ApproveRequests([FromBody] PayerMasterApprovalDecisionRequest request, CancellationToken ct)
    {
        if (!IsApprover) return Forbid();
        try { return Json(await _api.ApproveRequestsAsync(request, ct)); }
        catch (InvalidOperationException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPost]
    public async Task<IActionResult> RejectRequests([FromBody] PayerMasterApprovalDecisionRequest request, CancellationToken ct)
    {
        if (!IsApprover) return Forbid();
        if (string.IsNullOrWhiteSpace(request.Reason)) return BadRequest(new { message = "A rejection reason is required." });
        try { return Json(await _api.RejectRequestsAsync(request, ct)); }
        catch (InvalidOperationException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpGet]
    public async Task<IActionResult> AuditData(CancellationToken ct)
    {
        if (!HasAnyMasterAccess) return Forbid();
        return Json(await _api.GetAuditAsync(Request.Query, ct));
    }

    [HttpGet]
    public async Task<IActionResult> NotificationsData(int take, CancellationToken ct)
    {
        if (!HasAnyMasterAccess) return Forbid();
        return Json(await _api.GetNotificationsAsync(take <= 0 ? 50 : take, ct));
    }

    [HttpGet]
    public async Task<IActionResult> ExportInsurance(CancellationToken ct)
    {
        if (!CanViewLab) return Forbid();
        var result = await _api.ExportInsuranceAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }

    [HttpGet]
    public async Task<IActionResult> ExportPolicy(CancellationToken ct)
    {
        if (!CanViewPolicy) return Forbid();
        var result = await _api.ExportPolicyAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }
}
