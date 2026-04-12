using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public sealed class UsageController : Controller
{
    private readonly IAppUsageAuditService _auditService;

    public UsageController(IAppUsageAuditService auditService)
    {
        _auditService = auditService;
    }

    [HttpGet]
    public async Task<IActionResult> Index(CancellationToken cancellationToken)
    {
        ViewData["PageLabel"] = "Usage Monitor";
        var model = await _auditService.GetUsagePageAsync(cancellationToken);
        return View(model);
    }

    [HttpPost]
    public async Task<IActionResult> Heartbeat([FromBody] UsageHeartbeatRequest request, CancellationToken cancellationToken)
    {
        await _auditService.TrackHeartbeatAsync(HttpContext, request, cancellationToken);
        return Ok(new { success = true });
    }
}
