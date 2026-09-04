using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

public interface IAppUsageAuditService
{
    Task TrackHeartbeatAsync(HttpContext httpContext, UsageHeartbeatRequest request, CancellationToken cancellationToken = default);
    Task<AppUsagePageViewModel> GetUsagePageAsync(CancellationToken cancellationToken = default);
}
