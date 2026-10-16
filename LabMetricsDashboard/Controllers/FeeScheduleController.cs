using ClosedXML.Excel;
using LabMetricsDashboard.Filters;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Master Values > Fees Schedule Import: the Medicare Clinical Laboratory Fee Schedule (or any file
/// with HCPCS + RATE columns) in LRNMaster.dbo.FeeSchedule. The AR Workbench prices each claim's
/// denied CPT lines with it (HCPCS = CPT) to get the claim's Revenue Expectation, and from that its
/// Recovery Status; the copy into each lab happens on the next claim sync (Master File Processor, or
/// AR Workbench Data Processing > Run). Viewing follows Role Menu Mapping; importing replaces the
/// schedule, so it is Admin / Super Admin / LRN Admin only.
/// </summary>
[Authorize]
public sealed class FeeScheduleController : Controller
{
    private const long MaxUploadBytes = 20 * 1024 * 1024;
    private const string SetupMissing = "The Fee Schedule table is not installed. Run Database/LabMetricsDashboard/FeeSchedule_Setup.sql on LRNMaster.";

    private readonly IFeeScheduleRepository _repo;
    private readonly ILogger<FeeScheduleController> _logger;

    public FeeScheduleController(IFeeScheduleRepository repo, ILogger<FeeScheduleController> logger)
    {
        _repo = repo;
        _logger = logger;
    }

    private bool CanImport => MenuAccessFilter.IsFullAdmin(User);

    [HttpGet]
    public async Task<IActionResult> Index(CancellationToken ct)
    {
        ViewData["Title"] = "Fees Schedule Import";
        ViewData["PageLabel"] = "Fees Schedule Import";
        try
        {
            return View(new FeeScheduleViewModel { Rows = await _repo.GetAllAsync(ct), CanImport = CanImport });
        }
        catch (SqlException ex) when (ex.Number == 208) // Invalid object name: table not installed
        {
            _logger.LogWarning(ex, "dbo.FeeSchedule is missing.");
            return View(new FeeScheduleViewModel { CanImport = CanImport, SetupError = SetupMissing });
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    [RequestSizeLimit(MaxUploadBytes)]
    public async Task<IActionResult> Import(IFormFile? file, CancellationToken ct)
    {
        if (!CanImport) return Forbid();

        var uploadError = await FileUploadGuard.ValidateSpreadsheetAsync(file, MaxUploadBytes, ct);
        if (uploadError != null)
        {
            TempData["Error"] = file is null || file.Length == 0 ? "Choose the fee schedule file (.xls, .xlsx or .csv) to import." : uploadError;
            return RedirectToAction(nameof(Index));
        }

        FeeScheduleFileImport parsed;
        try
        {
            await using var stream = file!.OpenReadStream();
            parsed = FeeScheduleWorkbook.Read(stream, file.FileName);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Fee schedule file {File} could not be read.", file!.FileName);
            TempData["Error"] = "The file could not be read as a spreadsheet (.xls, .xlsx or .csv).";
            return RedirectToAction(nameof(Index));
        }

        if (parsed.Error is not null)
        {
            TempData["Error"] = parsed.Error;
            return RedirectToAction(nameof(Index));
        }

        try
        {
            await _repo.ReplaceAsync(parsed.Rows, Path.GetFileName(file.FileName), User.Identity?.Name, ct);
        }
        catch (SqlException ex)
        {
            _logger.LogError(ex, "Fee schedule import failed.");
            TempData["Error"] = ex.Number == 208 ? SetupMissing : "The import could not be saved. Nothing was changed.";
            return RedirectToAction(nameof(Index));
        }

        _logger.LogInformation("Fee schedule imported by {User} from {File}: {Rows} HCPCS, {Duplicates} duplicate row(s), {Invalid} invalid rate(s).",
            User.Identity?.Name, file.FileName, parsed.Rows.Count, parsed.DuplicateRows, parsed.InvalidRates.Count);

        TempData["Success"] = Summary(parsed);
        if (parsed.InvalidRates.Count > 0)
            TempData["Warning"] = $"{parsed.InvalidRates.Count} row(s) skipped for a missing or invalid rate: {string.Join("; ", parsed.InvalidRates.Take(8))}"
                                  + (parsed.InvalidRates.Count > 8 ? " ..." : ".");
        return RedirectToAction(nameof(Index));
    }

    /// <summary>The schedule in the import layout, so it can be checked and re-imported.</summary>
    [HttpGet]
    public async Task<IActionResult> Export(CancellationToken ct)
    {
        var rows = await _repo.GetAllAsync(ct);

        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("Fee Schedule");
        string[] headers = ["YEAR", "HCPCS", "MOD", "EFF_DATE", "INDICATOR", "RATE", "SHORTDESC"];
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
            if (row.FeeYear is int year) ws.Cell(r, 1).SetValue(year);
            ws.Cell(r, 2).SetValue(row.Hcpcs);
            ws.Cell(r, 3).SetValue(row.Modifier ?? string.Empty);
            ws.Cell(r, 4).SetValue(row.EffectiveDate?.ToString("yyyyMMdd") ?? string.Empty);
            ws.Cell(r, 5).SetValue(row.Indicator ?? string.Empty);
            ws.Cell(r, 6).SetValue(row.Rate);
            ws.Cell(r, 7).SetValue(row.ShortDescription ?? string.Empty);
            r++;
        }

        ws.Column(6).Style.NumberFormat.Format = "#,##0.00";
        ws.SheetView.FreezeRows(1);
        ws.Range(1, 1, 1, headers.Length).SetAutoFilter();
        ws.Columns().AdjustToContents(1, Math.Min(r, 200), 8, 60);

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return File(ms.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"Fee_Schedule_{DateTime.Now:yyyyMMdd}.xlsx");
    }

    private static string Summary(FeeScheduleFileImport parsed)
    {
        var text = $"Imported {parsed.Rows.Count:N0} HCPCS rate(s){(parsed.SheetName is null ? "" : $" from sheet '{parsed.SheetName}'")}.";
        if (parsed.DuplicateRows > 0)
            text += $" {parsed.DuplicateRows:N0} repeated row(s) (e.g. modifier QW) merged into their code.";
        if (parsed.ConflictingRates.Count > 0)
            text += $" {parsed.ConflictingRates.Count} code(s) were listed with different rates; the row without a modifier was kept ({string.Join(", ", parsed.ConflictingRates.Take(6))}).";
        if (parsed.BlankHcpcsRows > 0)
            text += $" {parsed.BlankHcpcsRows} row(s) without an HCPCS skipped.";
        return text + " The AR Workbench applies the new rates on the next claim sync.";
    }
}
