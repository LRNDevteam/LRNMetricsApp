namespace LabMetricsDashboard.Models;

public sealed class DashboardViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    // ?? Active filter values ?????????????????????????????????????????????????
    public string? FilterPayerName      { get; init; }
    public string? FilterPayerType      { get; init; }
    public string? FilterPanelName      { get; init; }
    public string? FilterClinicName     { get; init; }
    public string? FilterReferringProvider { get; init; }
    public string? FilterDosFrom        { get; init; }
    public string? FilterDosTo          { get; init; }
    public string? FilterFirstBillFrom  { get; init; }
    public string? FilterFirstBillTo    { get; init; }

    // ?? Filter option lists (distinct values from raw data) ??????????????????
    public List<string> PayerNames         { get; init; } = [];
    public List<string> PayerTypes         { get; init; } = [];
    public List<string> PanelNames         { get; init; } = [];
    public List<string> ClinicNames        { get; init; } = [];
    public List<string> ReferringProviders { get; init; } = [];

    // ?? Claim Level KPIs ?????????????????????????????????????????????????????
    public int     TotalClaims   { get; init; }
    public decimal TotalCharges  { get; init; }
    public decimal TotalPayments { get; init; }
    public decimal TotalBalance  { get; init; }

    // ?? Rate numerators (pre-computed in the controller with correct status filters) ?
    /// <summary>SUM(AllowedAmount) where ClaimStatus IN (Fully Paid, Partially Paid, Patient Responsibility, Patient Payment)</summary>
    public decimal CollectionNumerator   { get; init; }
    /// <summary>SUM(ChargeAmount) where ClaimStatus IN (Fully Denied, Partially Denied)</summary>
    public decimal DenialNumerator       { get; init; }
    /// <summary>SUM(InsuranceAdjustments) where ClaimStatus IN (Complete W/O, Partially Adjusted)</summary>
    public decimal AdjustmentNumerator   { get; init; }
    /// <summary>SUM(ChargeAmount) where ClaimStatus = No Response</summary>
    public decimal OutstandingNumerator  { get; init; }

    // ?? Computed rates (percentage, rounded to 1 dp) ??????????????????????????
    public decimal CollectionRate   => TotalCharges == 0 ? 0 : Math.Round(CollectionNumerator  / TotalCharges * 100, 1);
    public decimal DenialRate       => TotalCharges == 0 ? 0 : Math.Round(DenialNumerator      / TotalCharges * 100, 1);
    public decimal AdjustmentRate   => TotalCharges == 0 ? 0 : Math.Round(AdjustmentNumerator  / TotalCharges * 100, 1);
    public decimal OutstandingRate  => TotalCharges == 0 ? 0 : Math.Round(OutstandingNumerator / TotalCharges * 100, 1);

    public IReadOnlyDictionary<string, int>     ClaimStatusBreakdown { get; init; } = new Dictionary<string, int>();
    // Enriched per-status rows with Charges, Payments, Balance
    public IReadOnlyList<ClaimStatusRow>        ClaimStatusRows      { get; init; } = [];
    public IReadOnlyDictionary<string, decimal> PayerTypePayments    { get; init; } = new Dictionary<string, decimal>();

    public string? ResolvedClaimFilePath { get; init; }

    /// <summary>True when data was loaded from the database (not a CSV file).</summary>
    public bool IsDbMode { get; init; }

    /// <summary>The most recently ingested RunId from ClaimLevelData; null when no data exists.</summary>
    public string? DbLatestRunId { get; init; }

    // ?? Line Level KPIs ??????????????????????????????????????????????????????
    public int     TotalLines        { get; init; }
    public decimal LineTotalCharges  { get; init; }
    public decimal LineTotalPayments { get; init; }
    public decimal LineTotalBalance  { get; init; }
    public decimal LineCollectionRate => LineTotalCharges == 0 ? 0 : Math.Round(LineTotalPayments / LineTotalCharges * 100, 1);

    public IReadOnlyDictionary<string, decimal> TopCPTCharges    { get; init; } = new Dictionary<string, decimal>();
    public IReadOnlyDictionary<string, int>     PayStatusBreakdown { get; init; } = new Dictionary<string, int>();

    public string? ResolvedLineFilePath { get; init; }

    // ?? Insight breakdowns ???????????????????????????????????????????????????
    // Payer Level  : PayerName ? (charges, payments, balance)
    public IReadOnlyList<InsightRow> PayerLevelInsights         { get; init; } = [];
    // Panel Level  : PanelName ? (charges, payments, balance)
    public IReadOnlyList<InsightRow> PanelLevelInsights         { get; init; } = [];
    // Clinic Level : ClinicName ? (charges, payments, balance)
    public IReadOnlyList<InsightRow> ClinicLevelInsights        { get; init; } = [];
    // Referring Physician : ReferringProvider ? (charges, payments, balance)
    public IReadOnlyList<InsightRow> ReferringPhysicianInsights { get; init; } = [];
    // DOS monthly  : Month (yyyy-MM) ? claim count
    public IReadOnlyList<(string Month, int Count)> DOSMonthly       { get; init; } = [];
    // FirstBillDate monthly : Month ? claim count
    public IReadOnlyList<(string Month, int Count)> FirstBillMonthly { get; init; } = [];

    // Average Allowed by Panel × Month pivot (source: Claim Level)
    // Columns = ordered distinct months (yyyy-MM); Rows = one per panel
    public IReadOnlyList<string>         AvgAllowedMonths       { get; init; } = [];
    public IReadOnlyList<PanelMonthRow>  AvgAllowedByPanelMonth { get; init; } = [];

    // Top CPT by Charges enriched (source: Line Level)
    public IReadOnlyList<CptDetailRow> TopCptDetail { get; init; } = [];

    /// <summary>
    /// True when the page is serving data from pre-aggregated snapshot tables
    /// (<c>UseDBDashboard = true</c> and no active filters).
    /// False when data comes from live <c>ClaimLevelData</c> / <c>LineLevelData</c> queries.
    /// </summary>
    public bool IsAggregateMode { get; init; }

    /// <summary>
    /// True when the selected lab has snapshot mode enabled
    /// (<c>UseDBDashboard = true</c>), regardless of current filters.
    /// </summary>
    public bool SupportsAggregateMode { get; init; }
}

/// <summary>One row in a charges / payments / balance insight table.</summary>
public sealed record InsightRow(
    string Label,
    int    Claims,
    decimal Charges,
    decimal Payments,
    decimal Balance)
{
    public decimal CollectionRate => Charges == 0 ? 0 : Math.Round(Payments / Charges * 100, 1);
}

/// <summary>One row in the Average Allowed by Panel x Month pivot table.</summary>
public sealed class PanelMonthRow
{
    public string PanelName { get; init; } = string.Empty;
    /// <summary>Key = "yyyy-MM", Value = average AllowedAmount (null when no data for that month).</summary>
    public IReadOnlyDictionary<string, decimal> AvgByMonth { get; init; } =
        new Dictionary<string, decimal>();
}

/// <summary>One row in the Top CPT By Charges table on the dashboard.</summary>
public sealed record CptDetailRow(
    string  CPTCode,
    decimal Charges,
    decimal AllowedAmount,
    decimal InsuranceBalance,
    decimal CollectionRate,
    decimal DenialRate,
    decimal NoResponseRate);

/// <summary>Per-status aggregation row for the Claim Status Breakdown table.</summary>
public sealed record ClaimStatusRow(
    string  Status,
    int     Claims,
    decimal Charges,
    decimal Payments,
    decimal Balance)
{
    public decimal CollectionRate => Charges == 0 ? 0 : Math.Round(Payments / Charges * 100, 1);
}
