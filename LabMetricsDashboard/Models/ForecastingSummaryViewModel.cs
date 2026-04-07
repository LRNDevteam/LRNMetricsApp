namespace LabMetricsDashboard.Models;

/// <summary>
/// View model for the dedicated Forecasting Summary page
/// showing last-4-weeks Median and Mode breakdowns by payer,
/// plus a paged filtered-data detail tab.
/// </summary>
public sealed class ForecastingSummaryViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>False when the selected lab has DBEnabled=false — shows a "not available" banner.</summary>
    public bool PredictionAvailable { get; init; } = true;

    /// <summary>Monday of the current week — the global filter cutoff date.</summary>
    public DateOnly CurrentWeekStartDate { get; init; }

    /// <summary>Total records that fell within the 4-week window.</summary>
    public int TotalRecordsInRange { get; init; }

    // ?? All-data summaries ???????????????????????????????????????????
    public WeeklyForecastSummary MedianSummary { get; init; } = new();
    public WeeklyForecastSummary ModeSummary { get; init; } = new();

    // ?? Filtered detail data (paged) ?????????????????????????????????
    public List<PredictionRecord> FilteredRecords { get; init; } = [];
    public PageInfo FilteredPaging { get; init; } = new(1, 50, 0, 0);
    public int FilteredTotalInRange { get; init; }
    public bool HasActiveFilters { get; init; }

    // ?? Active filters ???????????????????????????????????????????????
    public string? FilterPayerName { get; init; }
    public string? FilterPayerType { get; init; }
    public string? FilterPanelName { get; init; }
    public string? FilterCPTCode { get; init; }

    // ?? Filter option lists ??????????????????????????????????????????
    public List<string> PayerNames { get; init; } = [];
    public List<string> PayerTypes { get; init; } = [];
    public List<string> PanelNames { get; init; } = [];
    public List<string> CPTCodes { get; init; } = [];

    /// <summary>Which top-level tab is active: "median", "mode", or "filtered".</summary>
    public string ActiveTab { get; init; } = "median";

    /// <summary>
    /// True when the lab has data but none falls within the last 4 weeks.
    /// The view should hide the tables and show an informational message instead.
    /// </summary>
    public bool NoDataForRange { get; init; }

    /// <summary>
    /// The most recent ExpectedPaymentDate found in the lab’s data.
    /// Shown in the empty-range message so users know when data was last available.
    /// </summary>
    public DateOnly? LatestDataDate { get; init; }
}
