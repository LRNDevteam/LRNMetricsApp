using System.Security.Claims;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

[ApiController]
[Route("api/denialworkflow/denial-code-master")]
[Route("api/denial-workflow/denial-code-master")]
public sealed class DenialCodeMasterController : ControllerBase
{
    private readonly IDenialCodeMasterRepository _repo;
    private readonly IDenialCodeMasterExcelService _excelService;

    public DenialCodeMasterController(IDenialCodeMasterRepository repo, IDenialCodeMasterExcelService excelService)
    {
        _repo = repo;
        _excelService = excelService;
    }

    [HttpGet]
    public async Task<ActionResult<PagedResult<DenialCodeMasterRecord>>> List([FromQuery] int labId, [FromQuery] string? search, [FromQuery] int page = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        return Ok(await _repo.GetPagedAsync(labId, search, page, pageSize, ct));
    }

    [HttpGet("lookups")]
    public async Task<ActionResult<DenialCodeMasterLookups>> Lookups([FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        return Ok(await _repo.GetLookupsAsync(labId, ct));
    }

    [HttpGet("{denialCode}")]
    public async Task<ActionResult<DenialCodeMasterRecord>> Get([FromRoute] string denialCode, [FromQuery] int labId, [FromQuery] string? coverageStatus, [FromQuery] string? icdComplianceStatus, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        var keyError = ValidateKey(denialCode, coverageStatus, icdComplianceStatus);
        if (!string.IsNullOrWhiteSpace(keyError)) return BadRequest(new { message = keyError });
        var row = await _repo.GetByKeyAsync(labId, denialCode, coverageStatus!, icdComplianceStatus!, ct);
        return row is null ? NotFound(new { message = "Denial code combination was not found." }) : Ok(row);
    }

    [HttpPost]
    public async Task<ActionResult> Create([FromQuery] int labId, DenialCodeMasterRequest request, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        request = Normalize(request);
        var error = Validate(request, requireCode: true);
        if (!string.IsNullOrWhiteSpace(error)) return BadRequest(new { message = error });
        if (await _repo.ExistsAsync(labId, request.DenialCode, request.CoverageStatus!, request.ICDComplianceStatus!, ct))
            return Conflict(new { message = "Denial Code, Coverage Status, and ICD Compliance Status combination already exists." });

        await _repo.CreateAsync(labId, request, CurrentUserName(), ct);
        await _excelService.RegenerateExportAsync(labId, ct);
        return Ok(new { success = true, message = "Denial code created and classifier Excel regenerated." });
    }

    [HttpPut("{denialCode}")]
    public async Task<ActionResult> Update([FromRoute] string denialCode, [FromQuery] int labId, [FromQuery] string? coverageStatus, [FromQuery] string? icdComplianceStatus, DenialCodeMasterRequest request, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        var keyError = ValidateKey(denialCode, coverageStatus, icdComplianceStatus);
        if (!string.IsNullOrWhiteSpace(keyError)) return BadRequest(new { message = keyError });
        request = Normalize(request);
        var error = Validate(request, requireCode: true);
        if (!string.IsNullOrWhiteSpace(error)) return BadRequest(new { message = error });
        if (!await _repo.ExistsAsync(labId, denialCode, coverageStatus!, icdComplianceStatus!, ct))
            return NotFound(new { message = "Denial code combination was not found." });

        if (!SameKey(denialCode, coverageStatus!, icdComplianceStatus!, request)
            && await _repo.ExistsAsync(labId, request.DenialCode, request.CoverageStatus!, request.ICDComplianceStatus!, ct))
        {
            return Conflict(new { message = "Denial Code, Coverage Status, and ICD Compliance Status combination already exists." });
        }

        await _repo.UpdateAsync(labId, denialCode, coverageStatus!, icdComplianceStatus!, request, CurrentUserName(), ct);
        await _excelService.RegenerateExportAsync(labId, ct);
        return Ok(new { success = true, message = "Denial code updated and classifier Excel regenerated." });
    }

    [HttpPost("import")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<DenialCodeMasterImportResult>> Import([FromQuery] int labId, [FromForm] DenialCodeMasterImportRequest request, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        var file = request.File;
        if (file is null || file.Length == 0) return BadRequest(new { message = "Select an Excel file." });
        await using var stream = file.OpenReadStream();
        return Ok(await _excelService.ImportAsync(labId, stream, CurrentUserName(), ct));
    }

    [HttpDelete("{denialCode}")]
    public async Task<ActionResult> Delete([FromRoute] string denialCode, [FromQuery] int labId, [FromQuery] string? coverageStatus, [FromQuery] string? icdComplianceStatus, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        var keyError = ValidateKey(denialCode, coverageStatus, icdComplianceStatus);
        if (!string.IsNullOrWhiteSpace(keyError)) return BadRequest(new { message = keyError });
        if (!await _repo.ExistsAsync(labId, denialCode, coverageStatus!, icdComplianceStatus!, ct))
            return NotFound(new { message = "Denial code combination was not found." });

        await _repo.DeleteAsync(labId, denialCode, coverageStatus!, icdComplianceStatus!, ct);
        await _excelService.RegenerateExportAsync(labId, ct);
        return Ok(new { success = true, message = "Denial code deleted and classifier Excel regenerated." });
    }

    [HttpPost("regenerate-export")]
    public async Task<ActionResult> RegenerateExport([FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        var path = await _excelService.RegenerateExportAsync(labId, ct);
        return Ok(new { success = true, message = "Classifier Excel regenerated.", path });
    }

    [HttpGet("export")]
    public async Task<IActionResult> Export([FromQuery] int labId, CancellationToken ct)
    {
        if (!IsArManagerFromToken()) return AccessDenied();
        if (labId <= 0) return BadRequest(new { message = "LabId is required." });
        var path = await _excelService.RegenerateExportAsync(labId, ct);
        return PhysicalFile(path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", Path.GetFileName(path));
    }

    private ActionResult AccessDenied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Denial Code Master is available only for AR Manager." });

    private bool IsArManagerFromToken()
    {
        var role = FirstClaim(ClaimTypes.Role, "role", "roles");
        var token = new string((role ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        return token.Contains("ARMANAGER");
    }

    private string CurrentUserName() => FirstClaim(ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn") ?? "ReactWorkflow";

    private string? FirstClaim(params string[] names)
    {
        foreach (var name in names)
        {
            var value = User.Claims.FirstOrDefault(c => string.Equals(c.Type, name, StringComparison.OrdinalIgnoreCase))?.Value;
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }
        return null;
    }

    private static string Validate(DenialCodeMasterRequest request, bool requireCode)
    {
        if (requireCode && string.IsNullOrWhiteSpace(request.DenialCode)) return "Denial Code is required.";
        return string.Empty;
    }

    private static string ValidateKey(string denialCode, string? coverageStatus, string? icdComplianceStatus)
    {
        if (string.IsNullOrWhiteSpace(denialCode)) return "Denial Code is required.";
        if (string.IsNullOrWhiteSpace(coverageStatus)) return "Coverage Status is required.";
        if (string.IsNullOrWhiteSpace(icdComplianceStatus)) return "ICD Compliance Status is required.";
        return string.Empty;
    }

    private static bool SameKey(string denialCode, string coverageStatus, string icdComplianceStatus, DenialCodeMasterRequest request)
        => string.Equals(denialCode.Trim(), request.DenialCode.Trim(), StringComparison.OrdinalIgnoreCase)
           && string.Equals(coverageStatus.Trim(), request.CoverageStatus?.Trim(), StringComparison.OrdinalIgnoreCase)
           && string.Equals(icdComplianceStatus.Trim(), request.ICDComplianceStatus?.Trim(), StringComparison.OrdinalIgnoreCase);

    private static DenialCodeMasterRequest Normalize(DenialCodeMasterRequest request)
    {
        static string? Trim(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
        static string StatusOrDefault(string? value) => string.IsNullOrWhiteSpace(value) ? "N/A" : value.Trim();
        request.DenialCode = (request.DenialCode ?? string.Empty).Trim();
        request.DenialDescription = Trim(request.DenialDescription);
        request.DenialClassification = Trim(request.DenialClassification);
        request.CoverageStatus = StatusOrDefault(request.CoverageStatus);
        request.ICDComplianceStatus = StatusOrDefault(request.ICDComplianceStatus);
        request.DenialValidity = Trim(request.DenialValidity);
        request.ActionCode = Trim(request.ActionCode);
        request.RecommendedAction = Trim(request.RecommendedAction);
        request.ActionCategory = Trim(request.ActionCategory);
        request.Task = Trim(request.Task);
        request.ShortCategory = Trim(request.ShortCategory);
        request.Priority = Trim(request.Priority);
        request.SLADays = Trim(request.SLADays);
        request.NotesComments = Trim(request.NotesComments);
        return request;
    }
}
