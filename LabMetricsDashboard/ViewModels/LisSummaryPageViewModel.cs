using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public sealed class LisSummaryPageViewModel
{
    public LisSummaryFilters Filters { get; set; } = new();
    public List<LabOption> LabOptions { get; set; } = new();
    public string CurrentLabName { get; set; } = string.Empty;
    public LisSummaryResult? Result { get; set; }
    public string? ErrorMessage { get; set; }
}
