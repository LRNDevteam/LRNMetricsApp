using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public sealed class LisSummaryPageViewModel
{
    public LisSummaryFilters Filters { get; set; } = new();
    public List<LabOption> LabOptions { get; set; } = new();
    public string CurrentLabName { get; set; } = string.Empty;

    /// <summary>
    /// The LabSettings key (appsettings/per-lab JSON) behind <see cref="CurrentLabName"/>,
    /// which is the DB's lab name and can differ. The report queue resolves connection
    /// strings by config key, so the async export button must post THIS value.
    /// </summary>
    public string ConfiguredLabKey { get; set; } = string.Empty;
    public LisSummaryResult? Result { get; set; }
    public LisLineDataResult? LineData { get; set; }
    public LisSummaryFilterOptions FilterOptions { get; set; } = new([], [], [], [], []);
    public string? ErrorMessage { get; set; }
}
