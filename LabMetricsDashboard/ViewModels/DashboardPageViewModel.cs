using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public class DashboardPageViewModel
{
    public DenialDashboardFilters Filters { get; set; } = new();

    /// <summary>
    /// Distinct values for the Global filters bar's Status / Priority / Action Category /
    /// Classification / Deadline multi-selects. These still filter the Line Item query
    /// server-side (see SqlDenialDashboardRepository), so they survive even though the tabs
    /// that used to render task-board rows directly (Task Board, Filter Panel, SLA Tracker,
    /// Dashboard) do not.
    /// </summary>
    public List<string> StatusOptions { get; set; } = new();
    public List<string> PriorityOptions { get; set; } = new();
    public List<string> ActionCategoryOptions { get; set; } = new();
    public List<string> ClassificationOptions { get; set; } = new();
    public List<string> DeadlineOptions { get; set; } = new();

    public List<LabOption> LabOptions { get; set; } = new();
    public string CurrentLabName { get; set; } = string.Empty;

    /// <summary>
    /// The LabSettings/LabConfig key behind <see cref="CurrentLabName"/> (which is the
    /// dashboard's display name and can differ, e.g. "PCR Labs of America" vs
    /// "PCRLabsofAmerica"). The report queue resolves connection strings by config key, so
    /// the async export button must post THIS value. Falls back to the display name.
    /// </summary>
    public string ConfiguredLabKey { get; set; } = string.Empty;
    public string CurrentRunId { get; set; } = string.Empty;
    public string CurrentSourceFileName { get; set; } = string.Empty;
    public string CurrentWeekFolder { get; set; } = string.Empty;

    public List<DenialInsightRecord> PagedInsights { get; set; } = new();
    /// <summary>Distinct denial codes (with description) present in this lab's insight table, for the Denial Code filter.</summary>
    public List<DenialCodeOption> InsightDenialCodeOptions { get; set; } = new();
    public int InsightCount { get; set; }
    public int InsightPage { get; set; } = 1;
    public int InsightPageSize { get; set; } = 25;
    public int InsightTotalPages { get; set; }
    public int InsightTotalDenials { get; set; }
    public int InsightTotalClaims { get; set; }
    public decimal InsightTotalBalance { get; set; }
    public decimal InsightTotalInsuranceBalance { get; set; }

    public List<DenialLineItemRecord> PagedLineItems { get; set; } = new();
    public int LineItemCount { get; set; }
    public int LineItemPage { get; set; } = 1;
    public int LineItemPageSize { get; set; } = 100;
    public int LineItemTotalPages { get; set; }

    public List<TrendBreakdownItem> WeeklyBreakdowns { get; set; } = new();
    public List<TrendBreakdownItem> MonthlyBreakdowns { get; set; } = new();

    public BreakdownPivotViewModel WeeklyPivot { get; set; } = new();
    public BreakdownPivotViewModel MonthlyPivot { get; set; } = new();

    public bool IsArManager { get; set; }
    public List<ReviewerOption> ReviewerOptions { get; set; } = new();

    /// <summary>Line Item grid payload for the AJAX-swappable partial.</summary>
    public LineItemGridViewModel LineItemGrid { get; set; } = new();
    /// <summary>Denial Insight grid payload for the AJAX-swappable partial.</summary>
    public InsightGridViewModel InsightGrid { get; set; } = new();
}

/// <summary>A denial code plus its description, used to populate the Denial Insight code filter.</summary>
public sealed record DenialCodeOption(string Code, string Description);

