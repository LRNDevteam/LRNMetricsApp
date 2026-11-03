using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

/// <summary>
/// A report snapshot of the Denial Summary page's Denial Insight tab (ReportCode DENIALINSIGHT), both of
/// its views. The client uploads and edits the tab, so LRN.SnapshotGenerator captures it on request rather
/// than from a tracker Success; the snapshot viewer shows it as the page's DenialInsightPanelViewModel.
/// </summary>
public sealed class DenialInsightSnapshotModel
{
    public string CurrentLab { get; set; } = "";
    public DateTime CurrentWeekStart { get; set; }
    public Dictionary<string, int> BucketCounts { get; set; } = new(StringComparer.Ordinal);
    public IReadOnlyList<DenialInsightRow> CurrentWeek { get; set; } = [];
    public IReadOnlyList<DenialInsightRow> PreviousWeek { get; set; } = [];
}
