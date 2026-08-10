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

    /// <summary>Run id from the Report Control Board link, when the page was opened from it.
    /// Empty otherwise — it only names the downloaded file.</summary>
    public string RunId { get; set; } = string.Empty;

    /// <summary>The selected range as a week label ("07.23.2026 - 07.29.2026"), for the file name.</summary>
    public string WeekLabel { get; set; } = string.Empty;
    public LisSummaryResult? Result { get; set; }
    public LisLineDataResult? LineData { get; set; }
    public LisSummaryFilterOptions FilterOptions { get; set; } = new([], [], [], [], []);
    public string? ErrorMessage { get; set; }
}
