using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public class DashboardPageViewModel
{
    public DenialDashboardFilters Filters { get; set; } = new();
    public DashboardSummary Summary { get; set; } = new();

    public int AllRecordCount { get; set; }
    public int FilteredRecordCount { get; set; }

    public List<DenialRecord> PagedRecords { get; set; } = new();
    public int RecordsPage { get; set; } = 1;
    public int RecordsPageSize { get; set; } = 100;
    public int RecordsTotalPages { get; set; }

    public List<BreakdownItem> StatusBreakdown { get; set; } = new();
    public List<BreakdownItem> PriorityBreakdown { get; set; } = new();
    public List<BreakdownItem> ActionCategoryBreakdown { get; set; } = new();
    public List<BreakdownItem> ClassificationBreakdown { get; set; } = new();
    public List<BreakdownItem> DeadlineBreakdown { get; set; } = new();

    public List<LabOption> LabOptions { get; set; } = new();
    public string CurrentLabName { get; set; } = string.Empty;
    public string CurrentRunId { get; set; } = string.Empty;

    public List<string> StatusOptions { get; set; } = new();
    public List<string> PriorityOptions { get; set; } = new();
    public List<string> ActionCategoryOptions { get; set; } = new();
    public List<string> ClassificationOptions { get; set; } = new();
    public List<string> DeadlineOptions { get; set; } = new();

    public List<DenialInsightRecord> PagedInsights { get; set; } = new();
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
}
