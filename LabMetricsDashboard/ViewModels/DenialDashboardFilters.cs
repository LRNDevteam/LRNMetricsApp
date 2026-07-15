namespace LabMetricsDashboard.ViewModels;

public class DenialDashboardFilters
{
    public int? LabId { get; set; }

    /// <summary>Denial code to filter the Denial Insight tab by (empty = all codes).</summary>
    public string DenialCode { get; set; } = string.Empty;

    public string Status { get; set; } = "(All)";
    public string Priority { get; set; } = "(All)";
    public string ActionCategory { get; set; } = "(All)";
    public string Deadline { get; set; } = "(All)";
    public string Classification { get; set; } = "(All)";

    public string SalesRepname { get; set; } = string.Empty;
    public string ClinicName { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PayerType { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;

    public DateTime? FirstBilledDateFrom { get; set; }
    public DateTime? FirstBilledDateTo { get; set; }
    public DateTime? DateOfServiceFrom { get; set; }
    public DateTime? DateOfServiceTo { get; set; }
    public DateTime? DenialDateFrom { get; set; }
    public DateTime? DenialDateTo { get; set; }

    public string ActiveTab { get; set; } = "dashboard";
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 100;
    public int InsightPage { get; set; } = 1;
    public int InsightPageSize { get; set; } = 25;
    public int LineItemPage { get; set; } = 1;
    public int LineItemPageSize { get; set; } = 100;

    /// <summary>
    /// Excel-style per-column "contains" filters keyed by the grid column key
    /// (DB column name for line items; a stable field key for insights). Applied
    /// server-side across the whole dataset, on top of the global filters above.
    /// </summary>
    public Dictionary<string, string> ColumnFilters { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}
