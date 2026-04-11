using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public sealed class AppUsagePageViewModel
{
    public int ActiveUsersCount { get; set; }
    public int DistinctUsers24h { get; set; }
    public int TotalPageViews24h { get; set; }
    public List<CurrentUserActivityRecord> ActiveUsers { get; set; } = new();
    public List<AppUsageActivityRecord> RecentActivity { get; set; } = new();
}
