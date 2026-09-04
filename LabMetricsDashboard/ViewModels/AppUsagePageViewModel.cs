using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public sealed class AppUsagePageViewModel
{
    public int ActiveUsersCount { get; set; }
    public List<CurrentUserActivityRecord> ActiveUsers { get; set; } = new();
}
