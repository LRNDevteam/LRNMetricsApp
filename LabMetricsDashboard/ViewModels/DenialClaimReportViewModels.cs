using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;

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

    /// <summary>"monthly", "weekly", "insight" or "claims" - which tab opens.</summary>
    public string ActiveTab { get; set; } = "monthly";

    public BreakdownPivotViewModel Monthly { get; set; } = new();
    public BreakdownPivotViewModel Weekly { get; set; } = new();

    public DenialInsightPanelViewModel Insight { get; set; } = new();
    public DenialClaimLevelTabViewModel Claims { get; set; } = new();

    // Headline figures, across everything the summaries are built from.
    public int TotalClaims { get; set; }
    public decimal TotalInsuranceBalance { get; set; }
    public int DenialCodeCount { get; set; }
    public int PayerCount { get; set; }

    /// <summary>Aggregated groups with no denial date, which cannot sit in any period.</summary>
    public int UndatedGroups { get; set; }

    /// <summary>
    /// The newest ClaimLevelData week the figures are reported against, as stored
    /// ("09.09.2026 - 09.15.2026"). Shown in the header so the page states the range it covers
    /// rather than leaving the reader to infer it from the newest column.
    /// </summary>
    public string? WeekRange { get; set; }

    /// <summary>
    /// The claim-level run behind <see cref="WeekRange"/> ("R20260922COV2443"), shown beside it so
    /// a figure on this page can be traced back to the load that produced it - the same
    /// "ReportId (RunID)" the Production Report header carries.
    /// </summary>
    public string? RunId { get; set; }

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

    /// <summary>
    /// The rows split by the week they describe, newest first.
    /// <para>Previous Week holds several weeks at once, and an undivided list of them would read as
    /// one long week. Each group gets a separator row carrying its date range.</para>
    /// </summary>
    public IReadOnlyList<DenialInsightWeekGroup> WeekGroups => Rows
        .GroupBy(r => r.WeekStart.Date)
        .OrderByDescending(g => g.Key)
        .Select(g => new DenialInsightWeekGroup
        {
            WeekStart = g.Key,
            Rows = g.ToList()
        })
        .ToList();

    /// <summary>True when the open tab holds more than one week, so separators are worth drawing.</summary>
    public bool HasMultipleWeeks => WeekGroups.Count > 1;
}

/// <summary>One week's worth of insight rows on the Previous Week tab.</summary>
public sealed class DenialInsightWeekGroup
{
    public DateTime WeekStart { get; set; }
    public IReadOnlyList<DenialInsightRow> Rows { get; set; } = Array.Empty<DenialInsightRow>();

    public string RangeLabel => DenialInsightBuckets.WeekRangeLabel(WeekStart);
    public int TotalDenials => Rows.Sum(r => r.NoOfDenials);
    public decimal TotalInsuranceBalance => Rows.Sum(r => r.InsuranceBalance);
}

/// <summary>
/// The Claim Level tab: the same columns and rows the Dashboard's Claim Level page shows, filtered
/// to the denial (and optionally the insurance) that was clicked.
/// </summary>
public sealed class DenialClaimLevelTabViewModel
{
    public string CurrentLab { get; set; } = string.Empty;
    public string? Error { get; set; }

    /// <summary>The denial code the tab is filtered to, or null for every denied claim.</summary>
    public string? DenialCode { get; set; }

    /// <summary>The insurance the tab is filtered to, or null for every payer.</summary>
    public string? PayerName { get; set; }

    public IReadOnlyList<string> DisplayColumns { get; set; } = Array.Empty<string>();

    /// <summary>Claim rows keyed by column name - the column set is per-lab config, not a fixed shape.</summary>
    public IReadOnlyList<IReadOnlyDictionary<string, string>> Rows { get; set; } =
        Array.Empty<IReadOnlyDictionary<string, string>>();

    /// <summary>
    /// Rows-per-page choices. A larger page is also how the column sort covers the whole result
    /// set rather than one page of it, so the range runs well past a comfortable screenful.
    /// </summary>
    public static readonly int[] PageSizes = [100, 500, 1000, 2500];

    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 100;
    public int TotalFiltered { get; set; }
    public int TotalAll { get; set; }

    public int TotalPages => PageSize <= 0 ? 1 : Math.Max(1, (int)Math.Ceiling(TotalFiltered / (double)PageSize));
    public bool HasPrevious => Page > 1;
    public bool HasNext => Page < TotalPages;

    public bool HasFilter => !string.IsNullOrWhiteSpace(DenialCode) || !string.IsNullOrWhiteSpace(PayerName);

    /// <summary>Set only when a filtered result came back empty - says which filter emptied it.</summary>
    public DenialClaimDiagnosis? Diagnosis { get; set; }
}
