namespace LabMetricsDashboard.Models;

/// <summary>View model for lab-scoped Payer Policy Validation data from dbo.PayerValidationReport.</summary>
public sealed class PayerPolicyValidationViewModel
{
    public List<string> AvailableLabs { get; init; } = [];

    public string SelectedLab { get; init; } = string.Empty;

    public bool DataLoaded { get; init; }

    public bool DbEnabled { get; init; }

    public string? DataSourceLabel { get; init; }

    public List<PredictionRecord> Records { get; init; } = [];

    public PageInfo Paging { get; init; } = new(1, 50, 0, 0);

    public int PageSize { get; init; } = 50;

    public string? ErrorMessage { get; init; }

    // ── Active filters ─────────────────────────────────────────────────────────

    public string? FilterPayerName { get; init; }
    public string? FilterPanelName { get; init; }
    public string? FilterFinalCoverageStatus { get; init; }
    public string? FilterCPTCode { get; init; }
    public string? FilterForecastingPayabilitySubstatus { get; init; }
    public string? FilterPredictionStatus { get; init; }
    public string? FilterPayStatus { get; init; }

    public bool HasActiveFilters =>
           !string.IsNullOrWhiteSpace(FilterPayerName)
        || !string.IsNullOrWhiteSpace(FilterPanelName)
        || !string.IsNullOrWhiteSpace(FilterFinalCoverageStatus)
        || !string.IsNullOrWhiteSpace(FilterCPTCode)
        || !string.IsNullOrWhiteSpace(FilterForecastingPayabilitySubstatus)
        || !string.IsNullOrWhiteSpace(FilterPredictionStatus)
        || !string.IsNullOrWhiteSpace(FilterPayStatus);

    // ── Filter dropdown options (from loaded lab data) ────────────────────────

    public List<string> PayerNames { get; init; } = [];
    public List<string> PanelNames { get; init; } = [];
    public List<string> FinalCoverageStatuses { get; init; } = [];
    public List<string> CPTCodes { get; init; } = [];
    public List<string> ForecastingPayabilitySubstatuses { get; init; } = [];
    public List<string> PredictionStatuses { get; init; } = [];
    public List<string> PayStatuses { get; init; } = [];
}
