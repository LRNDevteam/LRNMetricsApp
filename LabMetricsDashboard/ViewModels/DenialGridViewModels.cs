using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

/// <summary>
/// Payload for the AJAX-swappable Line Item grid partial (_DenialLineItemGrid). Rendered both on the
/// initial page load and by the LineItemGrid endpoint when paging / column-filtering.
/// </summary>
public sealed class LineItemGridViewModel
{
    public IReadOnlyList<DenialLineItemRecord> PagedLineItems { get; set; } = new List<DenialLineItemRecord>();
    public int LineItemPage { get; set; } = 1;
    public int LineItemPageSize { get; set; } = 100;
    public int LineItemTotalPages { get; set; } = 1;
    public int LineItemCount { get; set; }
    public DenialDashboardFilters Filters { get; set; } = new();
    public string CurrentLabName { get; set; } = string.Empty;
    public string CurrentRunId { get; set; } = string.Empty;
}

/// <summary>
/// Payload for the AJAX-swappable Denial Insight grid partial (_DenialInsightGrid).
/// </summary>
public sealed class InsightGridViewModel
{
    public IReadOnlyList<DenialInsightRecord> PagedInsights { get; set; } = new List<DenialInsightRecord>();
    public int InsightPage { get; set; } = 1;
    public int InsightPageSize { get; set; } = 50;
    public int InsightTotalPages { get; set; } = 1;
    public int InsightCount { get; set; }
    public int InsightTotalDenials { get; set; }
    public int InsightTotalClaims { get; set; }
    public decimal InsightTotalBalance { get; set; }
    public decimal InsightTotalInsuranceBalance { get; set; }
    public DenialDashboardFilters Filters { get; set; } = new();
    public string CurrentLabName { get; set; } = string.Empty;
    public string CurrentRunId { get; set; } = string.Empty;
    public bool IsArManager { get; set; }
    public IReadOnlyList<ReviewerOption> ReviewerOptions { get; set; } = new List<ReviewerOption>();
}
