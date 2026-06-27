using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

[Authorize(Roles = "Admin")]
public sealed class MasterValuesController : Controller
{
    private readonly IMasterValuesApiClient _api;

    public MasterValuesController(IMasterValuesApiClient api)
    {
        _api = api;
    }

    [HttpGet]
    public IActionResult InsurancePayerMaster()
    {
        ViewData["PageLabel"] = "Insurance Payer Master";
        return View(new MasterValuesPageViewModel { Title = "Insurance Payer Master", ApiBasePath = Url.Action(nameof(InsurancePayersData)) ?? string.Empty });
    }

    [HttpGet]
    public IActionResult PayerPolicyInsuranceMaster()
    {
        ViewData["PageLabel"] = "Payer Policy Insurance Master";
        return View(new MasterValuesPageViewModel { Title = "Payer Policy Insurance Master", IsPolicy = true, ApiBasePath = Url.Action(nameof(PolicyPayersData)) ?? string.Empty });
    }

    [HttpGet]
    public async Task<IActionResult> InsurancePayersData(CancellationToken ct) => Json(await _api.GetInsurancePayersAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> PolicyPayersData(CancellationToken ct) => Json(await _api.GetPolicyPayersAsync(Request.Query, ct));

    [HttpGet]
    public async Task<IActionResult> Labs(CancellationToken ct) => Json(await _api.GetLabsAsync(ct));

    [HttpGet]
    public async Task<IActionResult> InsurancePayer(int id, CancellationToken ct)
    {
        var row = await _api.GetInsurancePayerAsync(id, ct);
        return row is null ? NotFound() : Json(row);
    }

    [HttpGet]
    public async Task<IActionResult> PolicyPayer(int id, CancellationToken ct)
    {
        var row = await _api.GetPolicyPayerAsync(id, ct);
        return row is null ? NotFound() : Json(row);
    }

    [HttpPost]
    public async Task<IActionResult> SaveInsurancePayer([FromBody] InsurancePayerMasterDto dto, int? id, CancellationToken ct)
    {
        try
        {
            await _api.SaveInsurancePayerAsync(id, dto, ct);
            return Json(new { success = true });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> SavePolicyPayer([FromBody] PayerPolicyInsuranceMasterDto dto, int? id, CancellationToken ct)
    {
        try
        {
            await _api.SavePolicyPayerAsync(id, dto, ct);
            return Json(new { success = true });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> InsuranceStatus(int id, string? isActive, CancellationToken ct)
    {
        await _api.UpdateInsuranceStatusAsync(id, isActive, ct);
        return Json(new { success = true });
    }

    [HttpPost]
    public async Task<IActionResult> PolicyStatus(int id, string? isActive, CancellationToken ct)
    {
        await _api.UpdatePolicyStatusAsync(id, isActive, ct);
        return Json(new { success = true });
    }

    [HttpPost]
    public async Task<IActionResult> ImportInsurance(IFormFile file, CancellationToken ct)
    {
        var uploadError = await FileUploadGuard.ValidateExcelAsync(file, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        return Json(await _api.ImportInsuranceAsync(file, ct));
    }

    [HttpPost]
    public async Task<IActionResult> ImportPolicy(IFormFile file, CancellationToken ct)
    {
        var uploadError = await FileUploadGuard.ValidateExcelAsync(file, 25 * 1024 * 1024, ct);
        if (uploadError != null) return BadRequest(new { message = uploadError });
        return Json(await _api.ImportPolicyAsync(file, ct));
    }

    [HttpGet]
    public async Task<IActionResult> ExportInsurance(CancellationToken ct)
    {
        var result = await _api.ExportInsuranceAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }

    [HttpGet]
    public async Task<IActionResult> ExportPolicy(CancellationToken ct)
    {
        var result = await _api.ExportPolicyAsync(Request.Query, ct);
        return File(result.Content, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", result.FileName);
    }
}
