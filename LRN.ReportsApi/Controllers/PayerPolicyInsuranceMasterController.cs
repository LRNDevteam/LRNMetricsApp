using System.Security.Claims;
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

    public PayerPolicyInsuranceMasterController(IMasterValuesRepository repository)
    {
        _repository = repository;
    }

    [HttpGet]
    public async Task<ActionResult<PagedResult<PayerPolicyInsuranceMasterDto>>> List([FromQuery] PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
        => IsAdmin() ? Ok(await _repository.GetPolicyPayersAsync(query, ct)) : Denied();

    [HttpGet("{id:int}")]
    public async Task<ActionResult<PayerPolicyInsuranceMasterDto>> Get(int id, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        var row = await _repository.GetPolicyPayerAsync(id, ct);
        return row is null ? NotFound(new { message = "Payer policy insurance record was not found." }) : Ok(row);
    }

    [HttpPost]
    public async Task<ActionResult> Create(PayerPolicyInsuranceMasterDto dto, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        try { return Ok(new { id = await _repository.CreatePolicyPayerAsync(dto, UserName(), ct), success = true }); }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPut("{id:int}")]
    public async Task<ActionResult> Update(int id, PayerPolicyInsuranceMasterDto dto, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        try { return await _repository.UpdatePolicyPayerAsync(id, dto, UserName(), ct) ? Ok(new { success = true }) : NotFound(); }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPatch("{id:int}/status")]
    public async Task<ActionResult> Status(int id, MasterValueStatusRequest request, CancellationToken ct)
        => IsAdmin() ? await _repository.UpdatePolicyPayerStatusAsync(id, request.IsActive, UserName(), ct) ? Ok(new { success = true }) : NotFound() : Denied();

    [HttpPost("import")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<ImportResultDto>> Import([FromForm] MasterValueImportRequest request, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        var uploadError = await FileUploadGuard.ValidateExcelAsync(request.File, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        await using var stream = request.File.OpenReadStream();
        return Ok(await _repository.ImportPolicyPayersAsync(stream, UserName(), ct));
    }

    [HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied();
        var bytes = await _repository.ExportPolicyPayersAsync(query, ct);
        return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"PayerPolicyInsuranceMaster_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx");
    }

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Master Values is available only for Admin users." });
    private bool IsAdmin() => User.Claims.Where(c => c.Type == ClaimTypes.Role || c.Type is "role" or "roles").Any(c => string.Equals(c.Value, "Admin", StringComparison.OrdinalIgnoreCase));
    private string UserName() => User.Identity?.Name ?? User.Claims.FirstOrDefault(c => c.Type is "name" or "preferred_username" or "unique_name" or "upn")?.Value ?? "system";
}
