namespace LabMetricsDashboard.Models;

/// <summary>
/// View model for the Sales Rep Summary page.
/// Contains the lab selector, filter state, and per-sales-rep aggregated rows.
/// </summary>
public sealed class SalesRepSummaryViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    // Filters (multi-select)
    public List<string> FilterSalesRepNames { get; init; } = [];
    public List<string> FilterClinicNames { get; init; } = [];
    public List<string> FilterPayerNames { get; init; } = [];
    public List<string> FilterPanelNames { get; init; } = [];

    // Date range filters
    public string? FilterDosFrom { get; init; }
    public string? FilterDosTo { get; init; }
    public string? FilterFirstBillFrom { get; init; }
    public string? FilterFirstBillTo { get; init; }

    // Filter option lists
    public List<string> SalesRepNames { get; init; } = [];
    public List<string> ClinicNames { get; init; } = [];
    public List<string> PayerNames { get; init; } = [];
    public List<string> PanelNames { get; init; } = [];

    public List<SalesRepSummaryRow> Rows { get; init; } = [];

    /// <summary>Grand-total row for the footer.</summary>
    public SalesRepSummaryRow? Totals { get; init; }

    /// <summary>Error message to display if the DB query fails or is unavailable.</summary>
    public string? ErrorMessage { get; init; }

    /// <summary>True when any filter is active.</summary>
    public bool HasFilters => FilterSalesRepNames.Count > 0
        || FilterClinicNames.Count > 0
        || FilterPayerNames.Count > 0
        || FilterPanelNames.Count > 0
        || !string.IsNullOrWhiteSpace(FilterDosFrom)
        || !string.IsNullOrWhiteSpace(FilterDosTo)
        || !string.IsNullOrWhiteSpace(FilterFirstBillFrom)
        || !string.IsNullOrWhiteSpace(FilterFirstBillTo);

    // Top collected breakdowns (Top 10 by InsurancePaidAmount)
    public List<TopCollectedItem> TopCollectedSalesReps { get; init; } = [];
    public List<TopCollectedItem> TopCollectedClinics { get; init; } = [];
    public List<TopCollectedItem> TopCollectedPayers { get; init; } = [];
    public List<TopCollectedItem> TopCollectedPanels { get; init; } = [];

    // Top denied breakdowns (Top 10 by DeniedCharges)
    public List<TopDeniedItem> TopDeniedSalesReps { get; init; } = [];
    public List<TopDeniedItem> TopDeniedClinics { get; init; } = [];
    public List<TopDeniedItem> TopDeniedPayers { get; init; } = [];
    public List<TopDeniedItem> TopDeniedPanels { get; init; } = [];

    // Drilldown: per-sales-rep breakdowns for Highly Collected / Highly Denied
    public List<DrilldownCollectedGroup> DrilldownCollectedSalesReps { get; init; } = [];
    public List<DrilldownDeniedGroup> DrilldownDeniedSalesReps { get; init; } = [];
}

/// <summary>
/// One row of the Sales Rep Summary table — aggregated from Claim Level records for a single sales rep.
/// </summary>
public sealed record SalesRepSummaryRow
{
    public string SalesRepName { get; init; } = string.Empty;

    // Counts
    public int BilledClaimCount { get; init; }
    public int PaidClaimCount { get; init; }
    public int DeniedClaimCount { get; init; }
    public int OutstandingClaimCount { get; init; }

    // Dollar totals
    public decimal TotalBilledCharges { get; init; }
    public decimal TotalAllowedAmount { get; init; }
    public decimal TotalInsurancePaidAmount { get; init; }
    public decimal TotalPatientResponsibility { get; init; }
    public decimal TotalDeniedCharges { get; init; }
    public decimal TotalOutstandingCharges { get; init; }

    // Averages
    public decimal AverageAllowedAmount { get; init; }
    public decimal AverageInsurancePaidAmount { get; init; }

    // Percentages (0–100, rounded to nearest int)
    public decimal AllowedOnBilledPct => TotalBilledCharges == 0 ? 0
        : Math.Round(TotalAllowedAmount / TotalBilledCharges * 100, 0);

    public decimal PaidOnAllowedPct => TotalAllowedAmount == 0 ? 0
        : Math.Round(TotalInsurancePaidAmount / TotalAllowedAmount * 100, 0);

    public decimal AveragePaymentPct => TotalBilledCharges == 0 ? 0
        : Math.Round((TotalInsurancePaidAmount + TotalPatientResponsibility) / TotalBilledCharges * 100, 0);

    public decimal PaidClaimPct => BilledClaimCount == 0 ? 0
        : Math.Round((decimal)PaidClaimCount / BilledClaimCount * 100, 0);

    public decimal DeniedClaimPct => BilledClaimCount == 0 ? 0
        : Math.Round((decimal)DeniedClaimCount / BilledClaimCount * 100, 0);

    public decimal OutstandingClaimPct => BilledClaimCount == 0 ? 0
        : Math.Round((decimal)OutstandingClaimCount / BilledClaimCount * 100, 0);

    public decimal DeniedChargesPct => TotalBilledCharges == 0 ? 0
        : Math.Round(TotalDeniedCharges / TotalBilledCharges * 100, 0);

    public decimal OutstandingChargesPct => TotalBilledCharges == 0 ? 0
        : Math.Round(TotalOutstandingCharges / TotalBilledCharges * 100, 0);
}

/// <summary>
/// A ranked item for the "Highly Collected" breakdown cards.
/// </summary>
public sealed record TopCollectedItem
{
    public string Name { get; init; } = string.Empty;
    public int ClaimCount { get; init; }
    public decimal TotalBilledCharges { get; init; }
    public decimal TotalInsurancePaid { get; init; }
    public decimal CollectionPct { get; init; }
}

/// <summary>
/// A ranked item for the "Highly Denied" breakdown cards.
/// </summary>
public sealed record TopDeniedItem
{
    public string Name { get; init; } = string.Empty;
    public int DeniedClaimCount { get; init; }
    public decimal TotalBilledCharges { get; init; }
    public decimal TotalDeniedCharges { get; init; }
    public decimal DenialPct { get; init; }
}

/// <summary>
/// A top collected sales rep with drilldown sub-items by Clinic, Payer, and Panel.
/// </summary>
public sealed record DrilldownCollectedGroup
{
    public TopCollectedItem Parent { get; init; } = new();
    public List<TopCollectedItem> Clinics { get; init; } = [];
    public List<TopCollectedItem> Payers { get; init; } = [];
    public List<TopCollectedItem> Panels { get; init; } = [];
}

/// <summary>
/// A top denied sales rep with drilldown sub-items by Clinic, Payer, and Panel.
/// </summary>
public sealed record DrilldownDeniedGroup
{
    public TopDeniedItem Parent { get; init; } = new();
    public List<TopDeniedItem> Clinics { get; init; } = [];
    public List<TopDeniedItem> Payers { get; init; } = [];
    public List<TopDeniedItem> Panels { get; init; } = [];
}
