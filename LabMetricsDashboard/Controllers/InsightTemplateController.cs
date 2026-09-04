using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Per-report Insight Template Master. Production is first; LIS and Collection
/// reuse the same page with a different report name.
/// </summary>
public sealed class InsightTemplateController : Controller
{
    private readonly LabSettings _labSettings;

    public InsightTemplateController(LabSettings labSettings) => _labSettings = labSettings;

    [HttpGet]
    public IActionResult Index(string? lab, string? report)
        => Render(lab, report, "Insight Template Master");

    [HttpGet]
    public IActionResult Production(string? lab)
        => Render(lab, "Production Report", "Production Insight Templates");

    [HttpGet]
    public IActionResult Lis(string? lab)
        => Render(lab, "LIS Report", "LIS Insight Templates");

    [HttpGet]
    public IActionResult Collection(string? lab)
        => Render(lab, "Collection Report", "Collection Insight Templates");

    private IActionResult Render(string? lab, string? report, string title)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
        if (!NotesController.TryResolveReportName(report, out var reportName)
            && !string.IsNullOrWhiteSpace(report))
        {
            reportName = "Production Report";
        }
        if (string.IsNullOrWhiteSpace(report))
            reportName = "Production Report";

        ViewData["Title"] = title;
        ViewData["PageLabel"] = title;
        ViewData["SelectedLab"] = selectedLab;

        return View("Index", new InsightTemplatePageViewModel
        {
            AvailableLabs = availableLabs,
            SelectedLab = selectedLab,
            ReportName = reportName,
            Title = title
        });
    }
}

public sealed class InsightTemplatePageViewModel
{
    public List<string> AvailableLabs { get; set; } = [];
    public string SelectedLab { get; set; } = string.Empty;
    public string ReportName { get; set; } = "Production Report";
    public string Title { get; set; } = "Insight Template Master";
}
