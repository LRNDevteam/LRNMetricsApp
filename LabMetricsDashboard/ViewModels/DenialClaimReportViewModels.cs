using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

/// <summary>
/// The Denial Claim Report page: Monthly Summary, Weekly Summary and Denial Insight, all on one
/// screen as three tabs.
/// <para>There is no lab picker of its own - the page follows the application's lab selector in the
/// header, so switching lab anywhere switches it here too.</para>
/// </summary>
public sealed class DenialClaimReportViewModel
{
    public string CurrentLab { get; set; } = string.Empty;
    public string? Error { get; set; }

    /// <summary>"monthly", "weekly" or "insight" - which tab opens.</summary>
    public string ActiveTab { get; set; } = "monthly";

    public BreakdownPivotViewModel Monthly { get; set; } = new();
    public BreakdownPivotViewModel Weekly { get; set; } = new();

    public DenialInsightPanelViewModel Insight { get; set; } = new();

    // Headline figures, across everything the summaries are built from.
    public int TotalClaims { get; set; }
    public decimal TotalInsuranceBalance { get; set; }
    public int DenialCodeCount { get; set; }
    public int PayerCount { get; set; }

    /// <summary>Aggregated groups with no denial date, which cannot sit in any period.</summary>
    public int UndatedGroups { get; set; }

    /// <summary>True when the lab has not yet run the claim-level import that writes the derived columns.</summary>
    public bool MissingNormalizedColumn { get; set; }
}

/// <summary>The Denial Insight tab: Current Week and Previous Week, with import, export and edit.</summary>
public sealed class DenialInsightPanelViewModel
{
    public string CurrentLab { get; set; } = string.Empty;
    public bool CanEdit { get; set; }

    /// <summary>Current or Previous - which sub-tab is open.</summary>
    public string Bucket { get; set; } = DenialInsightBuckets.Current;

    public IReadOnlyList<DenialInsightRow> Rows { get; set; } = Array.Empty<DenialInsightRow>();

    /// <summary>Row counts per sub-tab, so each shows what it holds before being opened.</summary>
    public Dictionary<string, int> BucketCounts { get; set; } = new(StringComparer.Ordinal);

    /// <summary>
    /// Only Current Week is editable. Previous Week is the record of what was discussed last time,
    /// so it is shown read-only rather than left open to being rewritten after the fact.
    /// </summary>
    public bool IsEditableTab => CanEdit && Bucket == DenialInsightBuckets.Current;

    public DateTime CurrentWeekStart { get; set; }

    // Column totals for the footer row.
    public int TotalDenials => Rows.Sum(r => r.NoOfDenials);
    public decimal TotalBalance => Rows.Sum(r => r.TotalBalance);
    public decimal TotalInsuranceBalance => Rows.Sum(r => r.InsuranceBalance);
}
