using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public sealed class DenialClaimReportViewModel
{
    public List<string> Labs { get; set; } = new();
    public string CurrentLab { get; set; } = string.Empty;
    public string? Error { get; set; }

    /// <summary>"monthly" or "weekly".</summary>
    public string Grain { get; set; } = "monthly";

    public List<DenialPeriodOption> Periods { get; set; } = new();
    public DenialPeriodOption? SelectedPeriod { get; set; }

    /// <summary>Rows = payer (PayerName_Raw), columns = period. Ordered by claim count.</summary>
    public DenialPivotTable TopInsurance { get; set; } = new();

    /// <summary>Rows = denial code, columns = period. Top 3 by claim count, per the requirements.</summary>
    public DenialPivotTable TopDenial { get; set; } = new();

    /// <summary>The selected period's per-denial detail, with the most impacted payer on each row.</summary>
    public List<DenialSummaryRow> Summary { get; set; } = new();

    /// <summary>False shows only the top 3 denial codes; true shows every code.</summary>
    public bool ShowAllDenials { get; set; }

    public int TotalDenials { get; set; }
    public int TotalClaims { get; set; }
    public decimal TotalInsuranceBalance { get; set; }

    /// <summary>Denied rows the summaries could not place: no denial date, or no positive balance.</summary>
    public int ExcludedDenials { get; set; }

    /// <summary>True when the lab's ClaimLevelData carries its own DeniedWeek column.</summary>
    public bool UsesDeniedWeekColumn { get; set; }
}

/// <summary>What the shared _DenialPivot partial needs to render one pivot and link its cells.</summary>
public sealed class DenialPivotRenderModel
{
    public DenialPivotTable Table { get; set; } = new();
    public string Lab { get; set; } = string.Empty;
    public string Grain { get; set; } = "monthly";

    /// <summary>"payer" or "denial" - which drill-through filter a row's cells carry.</summary>
    public string LinkKind { get; set; } = "denial";

    public string Caption { get; set; } = string.Empty;

    /// <summary>Carried on the toggle link so switching top-3/all does not reset the period picker.</summary>
    public string? SelectedPeriodKey { get; set; }

    /// <summary>True on the Top Denial pivot, which offers the top-3 / all toggle.</summary>
    public bool AllowShowAllToggle { get; set; }

    public bool ShowAllDenials { get; set; }
}

public sealed class DenialClaimDataViewModel
{
    public List<string> Labs { get; set; } = new();
    public string CurrentLab { get; set; } = string.Empty;
    public string? Error { get; set; }

    public ClaimDrillThroughFilter Filter { get; set; } = new();
    public string DenialDescription { get; set; } = string.Empty;
    public IReadOnlyList<DenialClaimRow> Claims { get; set; } = Array.Empty<DenialClaimRow>();

    public int TotalClaims { get; set; }
    public decimal TotalInsuranceBalance { get; set; }

    /// <summary>"summary" or "insights" - which page the user came from, so Back returns there.</summary>
    public string ReturnTo { get; set; } = "summary";
    public string Grain { get; set; } = "monthly";

    /// <summary>The insight tab to return to, when the user arrived from Denial Insights.</summary>
    public string Bucket { get; set; } = DenialInsightBuckets.Current;
}

public sealed class DenialInsightClaimLevelViewModel
{
    public List<string> Labs { get; set; } = new();
    public string CurrentLab { get; set; } = string.Empty;
    public string? Error { get; set; }
    public bool CanEdit { get; set; }

    /// <summary>Current, Previous or Archive - which tab is open.</summary>
    public string Bucket { get; set; } = DenialInsightBuckets.Current;

    public IReadOnlyList<DenialInsightClaimLevelRow> Rows { get; set; } = Array.Empty<DenialInsightClaimLevelRow>();

    /// <summary>Row counts per tab, so each tab can show what it holds before being opened.</summary>
    public Dictionary<string, int> BucketCounts { get; set; } = new(StringComparer.Ordinal);

    /// <summary>
    /// Only the Current tab is editable. Previous and Archive are the record of what was said at the
    /// time, so they are shown read-only rather than left open to being rewritten after the fact.
    /// </summary>
    public bool IsEditableTab => CanEdit && Bucket == DenialInsightBuckets.Current;

    /// <summary>The week the Current tab's rows belong to, shown so the user can see what they are editing.</summary>
    public DateTime CurrentWeekStart { get; set; }
}
