using LabMetricsDashboard.Models.Notes;

namespace LabMetricsDashboard.ViewModels;

/// <summary>
/// A report snapshot of a report page's Key Insights &amp; Highlights panel (ReportCode LISINSIGHT /
/// PRODINSIGHT / COLLINSIGHT): the week's active insights and the templates that name their columns.
/// Users write the insights in the live report, so LRN.SnapshotGenerator captures them on request after
/// each save or delete (dbo.ReportSnapshotRequest), not from a tracker Success. The snapshot viewer shows
/// them read-only, with the report's snapshot or on their own.
/// </summary>
public sealed class ReportInsightsSnapshotModel
{
    public string CurrentLab { get; set; } = "";
    /// <summary>The Notes report name: LIS Report, Production Report or Collection Report.</summary>
    public string ReportName { get; set; } = "";
    public string? RunId { get; set; }
    public string? WeekText { get; set; }
    public DateTime? WeekStart { get; set; }
    public DateTime? WeekEnd { get; set; }
    public List<NotesTemplateBundle> Templates { get; set; } = [];
    public List<NoteInsight> Rows { get; set; } = [];

    /// <summary>The week's insights of <paramref name="all"/> (the report's active ones), as the panel shows them.</summary>
    public static List<NoteInsight> InWeek(IEnumerable<NoteInsight> all, DateTime? weekStart, string? weekText)
    {
        static string Key(string? s) => string.Join(' ', (s ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).ToLowerInvariant();
        return all.Where(n =>
            {
                if (weekStart is null && string.IsNullOrWhiteSpace(weekText)) return true;
                if (n.WeekRangeStart is null && string.IsNullOrWhiteSpace(n.WeekRangeText)) return true;
                return (weekStart is not null && n.WeekRangeStart?.Date == weekStart.Value.Date)
                       || (!string.IsNullOrWhiteSpace(weekText) && Key(n.WeekRangeText) == Key(weekText));
            })
            .OrderBy(n => n.EntryNo ?? n.NoteId).ThenBy(n => n.NoteId)
            .ToList();
    }
}
