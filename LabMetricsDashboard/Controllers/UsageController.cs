using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public sealed class UsageController : Controller
{
    private readonly IAppUsageAuditService _auditService;
    private readonly IIpGeolocationService _geolocation;

    public UsageController(IAppUsageAuditService auditService, IIpGeolocationService geolocation)
    {
        _auditService = auditService;
        _geolocation = geolocation;
    }

    [HttpGet]
    public async Task<IActionResult> Index(CancellationToken cancellationToken)
    {
        ViewData["PageLabel"] = "Usage Monitor";
        var model = await _auditService.GetUsagePageAsync(cancellationToken);
        await AttachLocationNamesAsync(model.ActiveUsers, cancellationToken);
        return View(model);
    }

    /// <summary>
    /// Resolves each distinct IP among the active sessions once (several rows commonly share the
    /// same office/VPN address) and writes the result back onto every matching row. The
    /// geolocation service caches internally too, so this mainly saves the redundant dictionary
    /// lookups when the same IP appears many times on one page.
    /// </summary>
    private async Task AttachLocationNamesAsync(List<CurrentUserActivityRecord> sessions, CancellationToken cancellationToken)
    {
        var distinctIps = sessions
            .Select(x => x.IpAddress)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct()
            .ToList();

        if (distinctIps.Count == 0) return;

        var lookups = await Task.WhenAll(distinctIps.Select(async ip => (Ip: ip, Name: await _geolocation.ResolveAsync(ip, cancellationToken))));
        var byIp = lookups.ToDictionary(x => x.Ip, x => x.Name);

        foreach (var session in sessions)
        {
            if (!string.IsNullOrWhiteSpace(session.IpAddress) && byIp.TryGetValue(session.IpAddress, out var name))
            {
                session.IpLocationName = name;
            }
        }
    }

    [HttpPost]
    public async Task<IActionResult> Heartbeat([FromBody] UsageHeartbeatRequest request, CancellationToken cancellationToken)
    {
        await _auditService.TrackHeartbeatAsync(HttpContext, request, cancellationToken);
        return Ok(new { success = true });
    }
}
