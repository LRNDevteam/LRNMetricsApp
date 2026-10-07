using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Old address of the Denial Summary. The page is DenialClaimReport (Monthly, Weekly, Denial List,
/// Denial List - Plan Type, Denial Insight, Claim Level), so links here land on it.
/// </summary>
[Authorize]
public sealed class DenialSummaryController : Controller
{
    [HttpGet]
    public IActionResult Index(string? lab, string? tab)
        => RedirectToAction("Index", "DenialClaimReport", new { lab, tab });

    [HttpGet]
    public IActionResult Export(string? lab)
        => RedirectToAction("ExportWorkbook", "DenialClaimReport", new { lab });
}
