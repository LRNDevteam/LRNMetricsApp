using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

[ApiController]
[Route("api/master-values/insurance-payers")]
public sealed class InsurancePayerMasterController : ControllerBase
{
    private readonly IMasterValuesRepository _repository;
    private readonly IPayerMasterWorkflowService _workflow;

    public InsurancePayerMasterController(IMasterValuesRepository repository, IPayerMasterWorkflowService workflow)
    {
        _repository = repository;
        _workflow = workflow;
    }

    private bool CanView => PayerMasterRoles.CanViewLab(User);
    private bool CanWrite => PayerMasterRoles.CanWriteLab(User);
    private bool RequiresApproval => PayerMasterRoles.LabRequiresApproval(User);
    private string UserName() => PayerMasterRoles.UserName(User);

    [HttpGet]
    public async Task<ActionResult<PagedResult<InsurancePayerMasterDto>>> List([FromQuery] InsurancePayerMasterQuery query, CancellationToken ct)
        => CanView ? Ok(await _repository.GetInsurancePayersAsync(query, ct)) : Denied();

    [HttpGet("labs")]
    public async Task<ActionResult<IReadOnlyList<MasterValueLabOption>>> Labs(CancellationToken ct)
        => CanView || PayerMasterRoles.CanViewPolicy(User) ? Ok(await _repository.GetLabsAsync(ct)) : Denied();

    [HttpGet("{id:int}")]
    public async Task<ActionResult<InsurancePayerMasterDto>> Get(int id, CancellationToken ct)
    {
        if (!CanView) return Denied();
        var row = await _repository.GetInsurancePayerAsync(id, ct);
        return row is null ? NotFound(new { message = "Insurance payer was not found." }) : Ok(row);
    }

    [HttpPost]
    public async Task<ActionResult> Create(InsurancePayerMasterDto dto, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        try
        {
            var result = await _workflow.CreateInsurancePayerAsync(dto, UserName(), RequiresApproval, ct);
            return Ok(new { id = result.Id, success = result.Success, pendingApproval = result.PendingApproval, approvalRequestId = result.ApprovalRequestId });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPut("{id:int}")]
    public async Task<ActionResult> Update(int id, InsurancePayerMasterDto dto, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        var existing = await _repository.GetInsurancePayerAsync(id, ct);
        if (existing is null) return NotFound(new { message = "Insurance payer was not found." });
        // Raw Name is source-populated and can never change on edit. An existing Payer Code is
        // locked too, but a blank one may be filled in.
        if (!string.IsNullOrWhiteSpace(existing.PayerCode)) dto.PayerCode = existing.PayerCode;
        dto.PayerNameRaw = existing.PayerNameRaw;
        try
        {
            var result = await _workflow.UpdateInsurancePayerAsync(id, dto, UserName(), RequiresApproval, ct);
            return result.Success
                ? Ok(new { success = true, pendingApproval = result.PendingApproval, approvalRequestId = result.ApprovalRequestId })
                : NotFound(new { message = result.Message });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPatch("{id:int}/status")]
    public async Task<ActionResult> Status(int id, MasterValueStatusRequest request, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        // Spec §5.3: deactivated payers are never reactivated; re-adding creates a new record.
        if (!string.Equals(request.IsActive, "Inactive", StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { message = "Deactivated payers cannot be reactivated. Re-add the payer as a new record instead." });
        try
        {
            var result = await _workflow.DeactivateInsurancePayerAsync(id, UserName(), RequiresApproval, ct);
            return result.Success
                ? Ok(new { success = true, pendingApproval = result.PendingApproval, approvalRequestId = result.ApprovalRequestId })
                : NotFound(new { message = result.Message });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPost("import")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<ImportResultDto>> Import([FromForm] MasterValueImportRequest request, CancellationToken ct)
    {
        if (!CanWrite || RequiresApproval) return Denied(); // bulk upload direct path is admin/manager-only (Spec §7.1)
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        await using var stream = request.File.OpenReadStream();
        return Ok(await _repository.ImportInsurancePayersAsync(stream, UserName(), ct));
    }

    [HttpPost("import/resolve-conflicts")]
    public async Task<ActionResult<GlobalPayerIdConflictResolutionResult>> ResolveImportConflicts(GlobalPayerIdConflictResolutionRequest request, CancellationToken ct)
    {
        if (!CanWrite || RequiresApproval) return Denied(); // same authority as the bulk import (Spec §7.1)
        return Ok(await _repository.ResolveInsuranceGlobalPayerConflictsAsync(request, UserName(), ct));
    }

    [HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] InsurancePayerMasterQuery query, CancellationToken ct)
    {
        if (!CanView) return Denied();
        var bytes = await _repository.ExportInsurancePayersAsync(query, ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"LabInsuranceMaster_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Your role does not permit this action on the Lab Insurance Master." });
}
