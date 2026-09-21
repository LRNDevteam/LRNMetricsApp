using System.Text;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.LabSchema;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Lab Master Configuration: onboard a new lab by mapping its file's headers onto the master
/// Claim Level / Line Level schemas, then generate that lab's schema JSON and its landing-table DDL.
///
/// <para>Super Admin only. What this page emits decides how a lab's data is read for every week
/// after, and the DDL runs against a lab database.</para>
/// </summary>
[Authorize(Policy = AppRoles.SuperAdminPolicy)]
public class LabSchemaController : Controller
{
    private const long MaxUploadBytes = 25 * 1024 * 1024;

    private readonly ILabSchemaMappingService _mapping;
    private readonly IUserManagementRepository _repo;
    private readonly ILogger<LabSchemaController> _logger;

    public LabSchemaController(ILabSchemaMappingService mapping, IUserManagementRepository repo,
        ILogger<LabSchemaController> logger)
    {
        _mapping = mapping;
        _repo = repo;
        _logger = logger;
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewData["PageLabel"] = "Lab Master Configuration";

        var vm = new LabSchemaPageViewModel
        {
            Labs = (await _repo.GetAllLabsAsync())
                .Where(l => l.IsActive)
                .OrderBy(l => l.LabName, StringComparer.OrdinalIgnoreCase)
                .ToList(),
            ClaimLevel = _mapping.GetMasterSchema(SchemaLevel.ClaimLevel),
            LineLevel = _mapping.GetMasterSchema(SchemaLevel.LineLevel)
        };

        return View(vm);
    }

    /// <summary>The master columns for one level, for the screen to render its grid from.</summary>
    [HttpGet]
    public IActionResult Master(SchemaLevel level)
        => Json(_mapping.AutoMap(level, []));

    /// <summary>
    /// Reads the header row out of an uploaded workbook or CSV and auto-maps it. Only headers are
    /// read - the data rows are never parsed, so a file full of PHI is not loaded into the app.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(MaxUploadBytes)]
    public async Task<IActionResult> Upload(IFormFile? file, SchemaLevel level, int headerRow = 1,
        string? sheet = null, CancellationToken ct = default)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { success = false, error = "Choose a file first." });

        if (file.Length > MaxUploadBytes)
            return BadRequest(new { success = false, error = "That file is larger than 25 MB." });

        var extension = Path.GetExtension(file.FileName).ToLowerInvariant();

        try
        {
            var (headers, sheets, sheetUsed) = extension switch
            {
                ".csv" or ".txt" => await ReadCsvHeadersAsync(file, headerRow, ct),
                ".xlsx" or ".xlsm" => ReadExcelHeaders(file, headerRow, sheet),
                _ => throw new InvalidOperationException("Upload an .xlsx, .xlsm or .csv file.")
            };

            if (headers.Count == 0)
            {
                return BadRequest(new
                {
                    success = false,
                    error = $"No column headers found on row {headerRow}"
                            + (string.IsNullOrWhiteSpace(sheetUsed) ? "." : $" of sheet '{sheetUsed}'.")
                });
            }

            var result = _mapping.AutoMap(level, headers);

            return Json(new
            {
                success = true,
                sheets,
                sheetUsed,
                headers,
                result
            });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { success = false, error = ex.Message });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Lab schema upload failed for {File}.", file.FileName);
            return BadRequest(new { success = false, error = "That file could not be read." });
        }
    }

    /// <summary>Re-runs the matcher over headers the page already holds, after a level switch.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Remap([FromBody] RemapRequest request)
        => Json(new { success = true, result = _mapping.AutoMap(request.Level, request.Headers ?? []) });

    /// <summary>The two artefacts: the lab's schema JSON and its landing-table DDL.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Generate([FromBody] GenerateRequest request)
    {
        if (request is null || string.IsNullOrWhiteSpace(request.LabName))
            return BadRequest(new { success = false, error = "Pick a lab first." });

        var json = _mapping.BuildLabSchemaJson(request);
        var sql = _mapping.BuildCreateTableSql(request);
        var suffix = request.Level == SchemaLevel.ClaimLevel ? "ClaimLevel" : "LineLevel";
        var safeLab = new string(request.LabName.Trim().Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray());

        return Json(new
        {
            success = true,
            json,
            sql,
            jsonFileName = $"{safeLab}_{suffix}.schema.json",
            sqlFileName = $"{safeLab}_{suffix}_CreateTable.sql"
        });
    }

    /// <summary>Downloads one generated artefact, so it can be dropped straight into the repo.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Download([FromForm] string fileName, [FromForm] string content)
    {
        if (string.IsNullOrWhiteSpace(fileName)) return BadRequest();

        var safeName = Path.GetFileName(fileName);
        return File(Encoding.UTF8.GetBytes(content ?? string.Empty), "application/octet-stream", safeName);
    }

    // ── Header readers ────────────────────────────────────────────────────────

    private static (List<string> Headers, List<string> Sheets, string SheetUsed) ReadExcelHeaders(
        IFormFile file, int headerRow, string? sheet)
    {
        using var stream = file.OpenReadStream();
        using var workbook = new XLWorkbook(stream);

        var sheets = workbook.Worksheets.Select(w => w.Name).ToList();

        var worksheet = !string.IsNullOrWhiteSpace(sheet)
            ? workbook.Worksheets.FirstOrDefault(w => w.Name.Equals(sheet, StringComparison.OrdinalIgnoreCase))
            : null;

        // No sheet named: take the first one with something on the header row, so a workbook that
        // opens on an empty "Instructions" tab still onboards.
        worksheet ??= workbook.Worksheets.FirstOrDefault(w => w.Row(headerRow).CellsUsed().Any())
                      ?? workbook.Worksheets.FirstOrDefault();

        if (worksheet is null) return ([], sheets, string.Empty);

        var headers = worksheet.Row(headerRow <= 0 ? 1 : headerRow)
            .CellsUsed()
            .Select(c => c.GetString().Trim())
            .Where(h => !string.IsNullOrWhiteSpace(h))
            .ToList();

        return (headers, sheets, worksheet.Name);
    }

    private static async Task<(List<string> Headers, List<string> Sheets, string SheetUsed)> ReadCsvHeadersAsync(
        IFormFile file, int headerRow, CancellationToken ct)
    {
        using var reader = new StreamReader(file.OpenReadStream());

        string? line = null;
        for (var i = 0; i < Math.Max(1, headerRow); i++)
        {
            line = await reader.ReadLineAsync(ct);
            if (line is null) break;
        }

        if (string.IsNullOrWhiteSpace(line)) return ([], [], string.Empty);

        var headers = SplitCsvLine(line)
            .Select(h => h.Trim().Trim('"').Trim())
            .Where(h => !string.IsNullOrWhiteSpace(h))
            .ToList();

        return (headers, [], string.Empty);
    }

    /// <summary>Comma split that respects quoted headers - "Payer, Primary" is one column.</summary>
    private static IEnumerable<string> SplitCsvLine(string line)
    {
        var value = new StringBuilder();
        var quoted = false;

        foreach (var ch in line)
        {
            if (ch == '"') { quoted = !quoted; continue; }
            if (ch == ',' && !quoted) { yield return value.ToString(); value.Clear(); continue; }
            value.Append(ch);
        }

        yield return value.ToString();
    }

    public sealed class RemapRequest
    {
        public SchemaLevel Level { get; set; }
        public List<string>? Headers { get; set; }
    }
}

public sealed class LabSchemaPageViewModel
{
    public IReadOnlyList<Lab> Labs { get; set; } = [];
    public MasterSchema ClaimLevel { get; set; } = new();
    public MasterSchema LineLevel { get; set; } = new();
}
