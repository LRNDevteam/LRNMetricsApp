using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

[ApiController]
[Route("api/master-values/payer-policy-insurance")]
public sealed class PayerPolicyInsuranceMasterController : ControllerBase
{
    private readonly IMasterValuesRepository _repository;
    private readonly IPayerMasterWorkflowService _workflow;

    public PayerPolicyInsuranceMasterController(IMasterValuesRepository repository, IPayerMasterWorkflowService workflow)
    {
        _repository = repository;
        _workflow = workflow;
    }

    private bool CanView => PayerMasterRoles.CanViewPolicy(User) || PayerMasterRoles.CanViewLab(User); // Lab-side roles may look up policy payers for mapping (Spec §5.2)
    private bool CanWrite => PayerMasterRoles.CanWritePolicy(User);
    private bool RequiresApproval => PayerMasterRoles.PolicyRequiresApproval(User);
    private string UserName() => PayerMasterRoles.UserName(User);

    [HttpGet]
    public async Task<ActionResult<PagedResult<PayerPolicyInsuranceMasterDto>>> List([FromQuery] PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
        => CanView ? Ok(await _repository.GetPolicyPayersAsync(query, ct)) : Denied();

    /// <summary>The Global Payer ID a brand-new record would take (MAX + 1); used to pre-fill the add form.</summary>
    [HttpGet("next-global-id")]
    public async Task<ActionResult> NextGlobalId(CancellationToken ct)
        => CanWrite ? Ok(new { nextGlobalPayerId = await _repository.GetNextPolicyGlobalPayerIdAsync(ct) }) : Denied();

    [HttpGet("{id:int}")]
    public async Task<ActionResult<PayerPolicyInsuranceMasterDto>> Get(int id, CancellationToken ct)
    {
        if (!CanView) return Denied();
        var row = await _repository.GetPolicyPayerAsync(id, ct);
        return row is null ? NotFound(new { message = "Payer policy insurance record was not found." }) : Ok(row);
    }

    [HttpPost]
    public async Task<ActionResult> Create(PayerPolicyInsuranceMasterDto dto, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        try
        {
            var result = await _workflow.CreatePolicyPayerAsync(dto, UserName(), RequiresApproval, ct);
            return Ok(new { id = result.Id, success = result.Success, pendingApproval = result.PendingApproval, approvalRequestId = result.ApprovalRequestId });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPut("{id:int}")]
    public async Task<ActionResult> Update(int id, PayerPolicyInsuranceMasterDto dto, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        try
        {
            var result = await _workflow.UpdatePolicyPayerAsync(id, dto, UserName(), RequiresApproval, ct);
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
            var result = await _workflow.DeactivatePolicyPayerAsync(id, UserName(), RequiresApproval, ct);
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
        if (!CanWrite || RequiresApproval) return Denied(); // bulk upload direct path is admin-only (Spec §7.1)
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        await using var stream = request.File.OpenReadStream();
        return Ok(await _repository.ImportPolicyPayersAsync(stream, UserName(), ct));
    }

    [HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
    {
        if (!CanView) return Denied();
        var bytes = await _repository.ExportPolicyPayersAsync(query, ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"PayerPolicyInsuranceMaster_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Your role does not permit this action on the Payer Policy Insurance Master." });
}
