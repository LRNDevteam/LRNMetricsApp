using System.Security.Claims;
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

    public InsurancePayerMasterController(IMasterValuesRepository repository)
    {
        _repository = repository;
    }

    [HttpGet]
    public async Task<ActionResult<PagedResult<InsurancePayerMasterDto>>> List([FromQuery] InsurancePayerMasterQuery query, CancellationToken ct)
        => IsAdmin() ? Ok(await _repository.GetInsurancePayersAsync(query, ct)) : Denied();

    [HttpGet("labs")]
    public async Task<ActionResult<IReadOnlyList<MasterValueLabOption>>> Labs(CancellationToken ct)
        => IsAdmin() ? Ok(await _repository.GetLabsAsync(ct)) : Denied();

    [HttpGet("{id:int}")]
    public async Task<ActionResult<InsurancePayerMasterDto>> Get(int id, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        var row = await _repository.GetInsurancePayerAsync(id, ct);
        return row is null ? NotFound(new { message = "Insurance payer was not found." }) : Ok(row);
    }

    [HttpPost]
    public async Task<ActionResult> Create(InsurancePayerMasterDto dto, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        try { return Ok(new { id = await _repository.CreateInsurancePayerAsync(dto, UserName(), ct), success = true }); }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPut("{id:int}")]
    public async Task<ActionResult> Update(int id, InsurancePayerMasterDto dto, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        var existing = await _repository.GetInsurancePayerAsync(id, ct);
        if (existing is null) return NotFound(new { message = "Insurance payer was not found." });
        dto.PayerCode = existing.PayerCode;
        dto.PayerNameRaw = existing.PayerNameRaw;
        try { return await _repository.UpdateInsurancePayerAsync(id, dto, UserName(), ct) ? Ok(new { success = true }) : NotFound(); }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPatch("{id:int}/status")]
    public async Task<ActionResult> Status(int id, MasterValueStatusRequest request, CancellationToken ct)
        => IsAdmin() ? await _repository.UpdateInsurancePayerStatusAsync(id, request.IsActive, UserName(), ct) ? Ok(new { success = true }) : NotFound() : Denied();

    [HttpPost("import")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<ImportResultDto>> Import([FromForm] MasterValueImportRequest request, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        await using var stream = request.File.OpenReadStream();
        return Ok(await _repository.ImportInsurancePayersAsync(stream, UserName(), ct));
    }

    [HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] InsurancePayerMasterQuery query, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        var bytes = await _repository.ExportInsurancePayersAsync(query, ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"InsurancePayerMaster_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Master Values is available only for Admin users." });
    private bool IsAdmin() => User.Claims.Where(c => c.Type == ClaimTypes.Role || c.Type is "role" or "roles").Any(c => string.Equals(c.Value, "Admin", StringComparison.OrdinalIgnoreCase));
    private string UserName() => User.Identity?.Name ?? User.Claims.FirstOrDefault(c => c.Type is "name" or "preferred_username" or "unique_name" or "upn")?.Value ?? "system";
}
