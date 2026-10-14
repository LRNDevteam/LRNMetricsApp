using ClosedXML.Excel;
using LabMetricsDashboard.Filters;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Denial Category Master and Non-Collectible Denial Master (LRNMaster): view both, import them
/// from the denial codes workbook (docs/Denial_Codes_And_Categorization_Master.xlsx) and download
/// them back in the same layout. Viewing follows Role Menu Mapping; importing replaces the
/// masters, so it is Admin / Super Admin / LRN Admin only.
/// </summary>
[Authorize]
public sealed class DenialCategoryMasterController : Controller
{
    private const int MaxCodeLength = 50;

    private readonly IDenialCategoryMasterRepository _repo;
    private readonly ILogger<DenialCategoryMasterController> _logger;

    public DenialCategoryMasterController(IDenialCategoryMasterRepository repo, ILogger<DenialCategoryMasterController> logger)
    {
        _repo = repo;
        _logger = logger;
    }

    private bool CanImport => MenuAccessFilter.IsFullAdmin(User);

    [HttpGet]
    public async Task<IActionResult> Index(string? tab, CancellationToken ct)
    {
        ViewData["Title"] = "Denial Category Master";
        ViewData["PageLabel"] = "Denial Category Master";
        var activeTab = string.Equals(tab, "noncollectible", StringComparison.OrdinalIgnoreCase) ? "noncollectible" : "categories";

        try
        {
            return View(new DenialCategoryMasterViewModel
            {
                Categories = await _repo.GetCategoriesAsync(ct),
                NonCollectible = await _repo.GetNonCollectibleAsync(ct),
                CanImport = CanImport,
                ActiveTab = activeTab
            });
        }
        catch (SqlException ex) when (ex.Number == 208) // Invalid object name: tables not installed
        {
            _logger.LogWarning(ex, "Denial Category Master tables are missing.");
            return View(new DenialCategoryMasterViewModel
            {
                CanImport = CanImport,
                ActiveTab = activeTab,
                SetupError = "The Denial Category Master tables are not installed. Run LabMetricsDashboard/SqlScripts/DenialCategoryMaster_Setup.sql on LRNMaster."
            });
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    [RequestSizeLimit(10 * 1024 * 1024)]
    public async Task<IActionResult> Import(IFormFile? file, CancellationToken ct)
    {
        if (!CanImport) return Forbid();

        if (file is null || file.Length == 0)
        {
            TempData["Error"] = "Choose the denial codes workbook (.xlsx) to import.";
            return RedirectToAction(nameof(Index));
        }

        var uploadError = await FileUploadGuard.ValidateExcelAsync(file, 10 * 1024 * 1024, ct);
        if (uploadError != null)
        {
            TempData["Error"] = uploadError;
            return RedirectToAction(nameof(Index));
        }

        DenialCategoryWorkbookImport parsed;
        try
        {
            await using var stream = file.OpenReadStream();
            parsed = DenialCategoryMasterWorkbook.Read(stream);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Denial codes workbook {File} could not be read.", file.FileName);
            TempData["Error"] = "The file could not be read as an Excel workbook.";
            return RedirectToAction(nameof(Index));
        }

        if (parsed.Error is not null)
        {
            TempData["Error"] = parsed.Error;
            return RedirectToAction(nameof(Index));
        }

        var tooLong = (parsed.Categories.Rows ?? new()).Concat(parsed.NonCollectible.Rows ?? new())
            .Where(r => r.DenialCode.Length > MaxCodeLength).Select(r => r.DenialCode).Distinct().ToList();
        if (tooLong.Count > 0)
        {
            TempData["Error"] = $"Denial codes longer than {MaxCodeLength} characters: {string.Join(", ", tooLong.Take(5))}. Nothing was imported.";
            return RedirectToAction(nameof(Index));
        }

        try
        {
            await _repo.ReplaceAsync(parsed.Categories.Rows, parsed.NonCollectible.Rows, User.Identity?.Name, ct);
        }
        catch (SqlException ex)
        {
            _logger.LogError(ex, "Denial Category Master import failed.");
            TempData["Error"] = ex.Number == 208
                ? "The Denial Category Master tables are not installed. Run SqlScripts/DenialCategoryMaster_Setup.sql on LRNMaster."
                : "The import could not be saved. Nothing was changed.";
            return RedirectToAction(nameof(Index));
        }

        _logger.LogInformation("Denial Category Master imported by {User} from {File}: {Categories} categorized, {NonCollectible} non-collectible.",
            User.Identity?.Name, file.FileName, parsed.Categories.Rows?.Count, parsed.NonCollectible.Rows?.Count);

        TempData["Success"] = Summary(parsed);
        return RedirectToAction(nameof(Index));
    }

    /// <summary>Both masters as a workbook in the import layout, so it can be edited and re-imported.</summary>
    [HttpGet]
    public async Task<IActionResult> Export(CancellationToken ct)
    {
        var categories = await _repo.GetCategoriesAsync(ct);
        var nonCollectible = await _repo.GetNonCollectibleAsync(ct);

        using var wb = new XLWorkbook();
        var sheet1 = wb.Worksheets.Add("Denial Category Clasification");
        WriteSheet(sheet1, ["Denial Code", "Denial Code Description", "Denial Categorization"],
            categories.Select(c => new[] { c.DenialCode, c.Description, c.ActionCategory }));
        var sheet2 = wb.Worksheets.Add("Non-collectible Denials");
        WriteSheet(sheet2, ["Denial Code", "Denial Code Description"],
            nonCollectible.Select(c => new[] { c.DenialCode, c.Description }));

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return File(ms.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"Denial_Codes_And_Categorization_Master_{DateTime.Now:yyyyMMdd}.xlsx");
    }

    private static void WriteSheet(IXLWorksheet ws, string[] headers, IEnumerable<string?[]> rows)
    {
        for (var i = 0; i < headers.Length; i++)
        {
            var cell = ws.Cell(1, i + 1);
            cell.Value = headers[i];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#1B3A4B");
        }

        var r = 2;
        foreach (var row in rows)
        {
            for (var i = 0; i < row.Length; i++)
                ws.Cell(r, i + 1).SetValue(row[i] ?? string.Empty);
            r++;
        }

        ws.SheetView.FreezeRows(1);
        ws.Range(1, 1, 1, headers.Length).SetAutoFilter();
        ws.Columns().AdjustToContents(1, Math.Min(r, 200), 10, 80);
    }

    private static string Summary(DenialCategoryWorkbookImport parsed)
    {
        static string Part(string label, DenialSheetImport s)
        {
            if (s.Rows is null) return $"{label}: sheet not in the file, left unchanged";
            var text = $"{label}: {s.Rows.Count} code(s)";
            if (s.Duplicates.Count > 0)
                text += $", {s.Duplicates.Count} repeated row(s) skipped ({string.Join(", ", s.Duplicates.Distinct(StringComparer.OrdinalIgnoreCase).Take(6))})";
            if (s.BlankCodeRows > 0) text += $", {s.BlankCodeRows} row(s) without a code skipped";
            return text;
        }

        return $"Imported. {Part("Denial Category Master", parsed.Categories)}. {Part("Non-Collectible Denials", parsed.NonCollectible)}.";
    }
}
