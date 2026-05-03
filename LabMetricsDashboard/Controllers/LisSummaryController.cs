using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class LisSummaryController : Controller
{
    private const string PreferredInitialLabName = "PCR Labs of America";

    private readonly ILisSummaryRepository _lisSummaryRepository;
    private readonly IDenialRecordRepository _labRepository;
    private readonly IConfiguration _configuration;

    public LisSummaryController(
        ILisSummaryRepository lisSummaryRepository,
        IDenialRecordRepository labRepository,
        IConfiguration configuration)
    {
        _lisSummaryRepository = lisSummaryRepository;
        _labRepository = labRepository;
        _configuration = configuration;
    }

    [HttpGet]
    public async Task<IActionResult> Index([FromQuery] LisSummaryFilters filters, CancellationToken cancellationToken)
    {
        filters ??= new LisSummaryFilters();

        var labs = (await _labRepository.GetLabsAsync(cancellationToken))
            .OrderBy(x => x.LabName)
            .ThenBy(x => x.LabId)
            .ToList();

        if (labs.Count == 0)
        {
            return View(new LisSummaryPageViewModel
            {
                Filters = filters,
                LabOptions = new List<LabOption>(),
                CurrentLabName = string.Empty,
                ErrorMessage = "No active labs were found."
            });
        }

        var selectedLab = ResolveSelectedLab(labs, filters.LabId);
        filters.LabId = selectedLab.LabId;

        try
        {
            var connectionString = ResolveConnectionString(selectedLab);
            var result = await _lisSummaryRepository.GetLisSummaryAsync(
                connectionString,
                selectedLab.LabName,
                selectedLab.LabId,
                filters.CollectedFrom,
                filters.CollectedTo,
                cancellationToken);

            return View(new LisSummaryPageViewModel
            {
                Filters = filters,
                LabOptions = labs,
                CurrentLabName = selectedLab.LabName,
                Result = result
            });
        }
        catch (Exception ex)
        {
            return View(new LisSummaryPageViewModel
            {
                Filters = filters,
                LabOptions = labs,
                CurrentLabName = selectedLab.LabName,
                ErrorMessage = $"Failed to load LIS Summary: {ex.Message}"
            });
        }
    }

    [HttpGet]
    public async Task<IActionResult> ExportToExcel([FromQuery] LisSummaryFilters filters, CancellationToken cancellationToken)
    {
        filters ??= new LisSummaryFilters();

        var labs = (await _labRepository.GetLabsAsync(cancellationToken))
            .OrderBy(x => x.LabName)
            .ThenBy(x => x.LabId)
            .ToList();

        if (labs.Count == 0)
        {
            TempData["LisSummaryError"] = "No active labs were found for LIS Summary export.";
            return RedirectToAction(nameof(Index));
        }

        var selectedLab = ResolveSelectedLab(labs, filters.LabId);
        filters.LabId = selectedLab.LabId;

        try
        {
            var connectionString = ResolveConnectionString(selectedLab);
            var result = await _lisSummaryRepository.GetLisSummaryAsync(
                connectionString,
                selectedLab.LabName,
                selectedLab.LabId,
                filters.CollectedFrom,
                filters.CollectedTo,
                cancellationToken);

            using var workbook = LisSummaryExcelExportBuilder.CreateWorkbook(
                result,
                selectedLab.LabName,
                filters.CollectedFrom,
                filters.CollectedTo);

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = MakeSafeFileName(selectedLab.LabName);
            var fileName = $"{safeLabName}_LIS_Summary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";
            return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
        }
        catch (Exception ex)
        {
            TempData["LisSummaryError"] = $"Failed to export LIS Summary: {ex.Message}";
            return RedirectToAction(nameof(Index), new
            {
                LabId = filters.LabId,
                CollectedFrom = filters.CollectedFrom?.ToString("yyyy-MM-dd"),
                CollectedTo = filters.CollectedTo?.ToString("yyyy-MM-dd")
            });
        }
    }

    private LabOption ResolveSelectedLab(IReadOnlyList<LabOption> labs, int? requestedLabId)
    {
        if (requestedLabId.HasValue)
        {
            var requestedLab = labs.FirstOrDefault(x => x.LabId == requestedLabId.Value);
            if (requestedLab is not null) return requestedLab;
        }

        return labs.FirstOrDefault(x => x.LabName.Equals(PreferredInitialLabName, StringComparison.OrdinalIgnoreCase))
            ?? labs.First();
    }

    private string ResolveConnectionString(LabOption lab)
    {
        if (string.IsNullOrWhiteSpace(lab.ConnectionKey))
        {
            throw new InvalidOperationException($"Lab '{lab.LabName}' does not have a ConnectionKey in dbo.LRNMetricsLab.");
        }

        var connectionString = _configuration.GetConnectionString(lab.ConnectionKey);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException($"Connection string '{lab.ConnectionKey}' was not found in appsettings.json.");
        }

        return connectionString;
    }

    private static string MakeSafeFileName(string value)
    {
        var invalidChars = Path.GetInvalidFileNameChars();
        var safe = new string(value.Select(ch => invalidChars.Contains(ch) ? '_' : ch).ToArray()).Trim('_');
        return string.IsNullOrWhiteSpace(safe) ? "Lab" : safe;
    }
}
