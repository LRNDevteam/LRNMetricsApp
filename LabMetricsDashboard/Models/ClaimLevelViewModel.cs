namespace LabMetricsDashboard.Models;


public sealed class ClaimLevelViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    // Filter inputs
    public string? FilterPayerName { get; init; }
    public List<string> FilterPayerTypes { get; init; } = [];
    public List<string> FilterClaimStatuses { get; init; } = [];
    public List<string> FilterClinicNames { get; init; } = [];
    public string? FilterDenialCode { get; init; }
    public bool FilterDenialCodeExcludeBlank { get; init; }
    public List<string> FilterPayerNames { get; init; } = [];
    public bool FilterPayerExcludeBlank { get; init; }
    public List<string> FilterPanelNames { get; init; } = [];
    public bool FilterPanelExcludeBlank { get; init; }
    public List<string> FilterAgingBuckets { get; init; } = [];
    public string? FilterFirstBillFrom { get; init; }
    public string? FilterFirstBillTo { get; init; }
    public bool FilterFirstBillNull { get; init; }
    public bool FilterFirstBillExcludeBlank { get; init; }
    public string? FilterChargeEnteredFrom { get; init; }
    public string? FilterChargeEnteredTo { get; init; }
    public bool FilterChargeEnteredNull { get; init; }
    public bool FilterChargeEnteredExcludeBlank { get; init; }
    public string? FilterDosFrom { get; init; }
    public string? FilterDosTo { get; init; }
    public bool FilterDosNull { get; init; }

    // Filter options (populated from data)
    public List<string> PayerTypes { get; init; } = [];
    public List<string> ClaimStatuses { get; init; } = [];
    public List<string> ClinicNames { get; init; } = [];
    public List<string> PayerNames { get; init; } = [];
    public List<string> PanelNames { get; init; } = [];
    public List<string> AgingBuckets { get; init; } = [];

    /// <summary>True when any filter is active.</summary>
    public bool HasFilters => !string.IsNullOrWhiteSpace(FilterPayerName)
        || FilterPayerTypes.Count > 0
        || FilterClaimStatuses.Count > 0
        || FilterClinicNames.Count > 0
        || !string.IsNullOrWhiteSpace(FilterDenialCode)
        || FilterDenialCodeExcludeBlank
        || FilterPayerNames.Count > 0
        || FilterPayerExcludeBlank
        || FilterPanelNames.Count > 0
        || FilterPanelExcludeBlank
        || FilterAgingBuckets.Count > 0
        || !string.IsNullOrWhiteSpace(FilterFirstBillFrom)
        || !string.IsNullOrWhiteSpace(FilterFirstBillTo)
        || FilterFirstBillNull
        || FilterFirstBillExcludeBlank
        || !string.IsNullOrWhiteSpace(FilterChargeEnteredFrom)
        || !string.IsNullOrWhiteSpace(FilterChargeEnteredTo)
        || FilterChargeEnteredNull
        || FilterChargeEnteredExcludeBlank
        || !string.IsNullOrWhiteSpace(FilterDosFrom)
        || !string.IsNullOrWhiteSpace(FilterDosTo)
        || FilterDosNull;

    // Current page of records (already sliced)
    public List<ClaimRecord> Records { get; init; } = [];

    public PageInfo Paging { get; init; } = new(1, 50, 0, 0);

    /// <summary>Full path of the source CSV file that was loaded.</summary>
    public string? ResolvedFilePath { get; init; }

    /// <summary>Describes the data source (e.g. "SQL Database" or CSV file path).</summary>
    public string? DataSource { get; init; }
}
