namespace LabMetricsDashboard.Models;

using LabMetricsDashboard.Services;

/// <summary>
/// View model for the Collection Summary page.
/// Contains the lab selector, filter state, and tab-specific result data.
/// Tabs: Monthly Claim Volume, Weekly Claim Volume,
///       Top 5 Insurance Reimbursement %, Top 5 Insurance Total Payments,
///       Panel Averages, Insurance vs Aging, Panel vs Payment,
///       Rep vs Payments, Insurance vs Payment %, CPT vs Payment %.
/// Some tabs may be unavailable for certain labs (placeholder for future gating).
/// </summary>
public sealed class CollectionSummaryViewModel
{
    public List<string> AvailableLabs { get; set; } = [];
    public string SelectedLab { get; set; } = string.Empty;

    /// <summary>
    /// Active per-lab Collection Summary rule applied to the Monthly Claim Volume tab
    /// (e.g. <c>"Northwestlabs Rule"</c>). Null/empty when the lab uses the legacy default behavior.
    /// </summary>
    public string? CollectionSummaryRule { get; set; }

    // Filters (same dimensions as Production Report)
    public List<string> FilterPayerNames { get; set; } = [];
    public List<string> FilterPanelNames { get; set; } = [];
    public string? FilterFirstBillFrom { get; set; }
    public string? FilterFirstBillTo { get; set; }
    public string? FilterDosFrom { get; set; }
    public string? FilterDosTo { get; set; }
    public string? FilterCheckDateFrom { get; set; }
    public string? FilterCheckDateTo { get; set; }

    // Filter option lists
    public List<string> PayerNames { get; set; } = [];
    public List<string> PanelNames { get; set; } = [];

    public bool HasFilters => FilterPayerNames.Count > 0
        || FilterPanelNames.Count > 0
        || !string.IsNullOrWhiteSpace(FilterFirstBillFrom)
        || !string.IsNullOrWhiteSpace(FilterFirstBillTo)
        || !string.IsNullOrWhiteSpace(FilterDosFrom)
        || !string.IsNullOrWhiteSpace(FilterDosTo)
        || !string.IsNullOrWhiteSpace(FilterCheckDateFrom)
        || !string.IsNullOrWhiteSpace(FilterCheckDateTo);

    // ?? Monthly Claim Volume ?????????????????????????????????????
    public CollectionMonthlyVolumePivot MonthlyClaimVolume { get; set; } = CollectionMonthlyVolumePivot.Empty;

    /// <summary>Whether encounter counts are sourced from LineLevelData for this lab.</summary>
    public bool UsesLineEncounters { get; set; }

    // ?? Weekly Claim Volume ??????????????????????????????????????
    public CollectionWeeklyVolumePivot WeeklyClaimVolume { get; set; } = CollectionWeeklyVolumePivot.Empty;

    // ?? Top 5 Insurance Reimbursement % ?????????????????????????
    public List<InsuranceReimbursementRow> Top5Reimbursement { get; set; } = [];

    // ?? Top 5 Insurance Total Payments ??????????????????????????
    public List<InsuranceTotalPaymentRow> Top5TotalPayments { get; set; } = [];

    /// <summary>Whether the Top 5 Total Payments tab is available for the selected lab.</summary>
    public bool ShowTop5TotalPayments { get; set; } = true;

    // ?? Insurance vs Aging ??????????????????????????????????????
    public List<InsuranceAgingRow> InsuranceAging { get; set; } = [];

    // ?? Panel vs Payment ????????????????????????????????????????
    public List<PanelPaymentRow> PanelPayments { get; set; } = [];

    // ?? Rep vs Payments ??????????????????????????????????????????
    public RepPaymentPivot RepPayments { get; set; } = RepPaymentPivot.Empty;

    // ?? Insurance vs Payment % ??????????????????????????????????
    public List<InsurancePaymentPctRow> InsurancePaymentPct { get; set; } = [];

    // ?? CPT vs Payment % ???????????????????????????????????????
    public List<CptPaymentPctRow> CptPaymentPct { get; set; } = [];

    // ?? Panel Averages ????????????????????????????????????????????
    public List<PanelAveragesRow> PanelAverages { get; set; } = [];

    // ?? Average Payments (Per Panel | Last 6 Months | Posted Date) ???
    public PanelAveragesResult AvgPayments { get; set; } = new PanelAveragesResult([]);

    // ?? Status Summary ????????????????????????????????????????????
    public StatusSummaryResult StatusSummary { get; set; } = StatusSummaryResult.Empty;

    public ProviderSummaryResult ProviderSummary { get; set; } = ProviderSummaryResult.Empty;

    /// <summary>Error message when the DB query fails or is unavailable.</summary>
    public string? ErrorMessage { get; set; }
}

// ?? Status Summary types ??????????????????????????????????????????????????????

/// <summary>Level-3 leaf: one PayerName_Raw within a ClaimStatus?CPT branch.</summary>
public sealed record StatusSummaryPayerRow(
    string  PayerName,
    int     NoClaims,
    decimal InsurancePayments,
    decimal InsuranceBalance,
    decimal PatientBalance);

/// <summary>Level-3 leaf: one CPTCodeXUnitsXModifier within a ClaimStatus → Panel branch.</summary>
public sealed class StatusSummaryCptRow
{
    public required string CptCode           { get; set; }
    public int     NoClaims                  { get; set; }
    public decimal InsurancePayments         { get; set; }
    public decimal InsuranceBalance          { get; set; }
    public decimal PatientBalance            { get; set; }
    public List<StatusSummaryPayerRow> Payers { get; set; } = [];
}

/// <summary>Level-2: one PanelName within a ClaimStatus group, with CPT drill-down.</summary>
public sealed class StatusSummaryPanelRow
{
    public required string PanelName         { get; set; }
    public int     NoClaims                  { get; set; }
    public decimal InsurancePayments         { get; set; }
    public decimal InsuranceBalance          { get; set; }
    public decimal PatientBalance            { get; set; }
    public List<StatusSummaryCptRow> CptRows { get; set; } = [];
}

/// <summary>Level-1: one ClaimStatus group, aggregated with nested Panel → CPT drill-down.</summary>
public sealed class StatusSummaryClaimRow
{
    public required string ClaimStatus          { get; set; }
    public int     NoClaims                     { get; set; }
    public decimal InsurancePayments            { get; set; }
    public decimal InsuranceBalance             { get; set; }
    public decimal PatientBalance               { get; set; }
    public List<StatusSummaryPanelRow> PanelRows { get; set; } = [];
}

/// <summary>
/// Full Status Summary result: 3-level hierarchy (ClaimStatus?CPT?Payer) + Grand Total.
/// Sorted by NoClaims descending at every level.
/// </summary>
public sealed class StatusSummaryResult
{
    public static readonly StatusSummaryResult Empty = new();
    public List<StatusSummaryClaimRow> Rows  { get; set; } = [];
    public int     GrandNoClaims             { get; set; }
    public decimal GrandInsurancePayments    { get; set; }
    public decimal GrandInsuranceBalance     { get; set; }
    public decimal GrandPatientBalance       { get; set; }
    public bool    HasData                   => Rows.Count > 0;
}

/// <summary>
/// One row in the "Top 5 Insurance Reimbursement %" table.
/// Ranked by unique visit (AccessionNumber) count descending.
/// </summary>
public sealed record InsuranceReimbursementRow(
    int Rank,
    string PayerName,
    decimal SumInsurancePayment,
    decimal SumChargeAmount,
    int UniqueVisitCount)
{
    /// <summary>Reimbursement % = SUM(InsurancePayment) / SUM(ChargeAmount) × 100.</summary>
    public decimal ReimbursementPct => SumChargeAmount == 0
        ? 0m
        : Math.Round(SumInsurancePayment / SumChargeAmount * 100m, 2);
}

/// <summary>
/// One row in the "Top 5 Insurance Total Payments" table.
/// Ranked by unique visit (VisitNumber) count descending.
/// </summary>
public sealed record InsuranceTotalPaymentRow(
    int Rank,
    string PayerName,
    decimal TotalPayments,
    int UniqueVisitCount);

/// <summary>
/// One row in the "Insurance vs Aging" pivot table.
/// Aging buckets are derived from DaysToDOS:
///   Current (&lt;30), 30+, 60+, 90+, 120+.
/// Source: ClaimLevelData where ClaimStatus = 'No Response'.
/// </summary>
public sealed record InsuranceAgingRow(
    string PayerName,
    int ClaimsCurrent,
    decimal BalanceCurrent,
    int Claims30,
    decimal Balance30,
    int Claims60,
    decimal Balance60,
    int Claims90,
    decimal Balance90,
    int Claims120,
    decimal Balance120,
    int ClaimsTotal,
    decimal BalanceTotal);

/// <summary>
/// One row in the "Panel vs Payment" table.
/// Source: ClaimLevelData where InsurancePayment &gt; 0.
/// Grouped by PanelName, sorted by SUM(InsurancePayment) descending.
/// </summary>
public sealed record PanelPaymentRow(
    string PanelName,
    int NoOfClaims,
    decimal InsurancePayments);

/// <summary>
/// One row in the "Insurance vs Payment %" table.
/// Source: ClaimLevelData where InsurancePayment &gt; 0.
/// Payment % is SUM(InsurancePayment)/SUM(ChargeAmount) only for
/// ClaimStatus IN ('Fully Paid','Partially Paid').
/// Sorted by SUM(InsurancePayment) descending.
/// </summary>
public sealed record InsurancePaymentPctRow(
    string PayerName,
    int TotalClaims,
    decimal InsurancePayments,
    decimal PaidInsurancePayment,
    decimal PaidChargeAmount)
{
    /// <summary>Payment % = SUM(InsurancePayment) / SUM(ChargeAmount) × 100 (Fully Paid + Partially Paid only).</summary>
    public decimal PaymentPct => PaidChargeAmount == 0
        ? 0m
        : Math.Round(PaidInsurancePayment / PaidChargeAmount * 100m, 2);
}

/// <summary>
/// One row in the "CPT vs Payment %" table.
/// Source: LineLevelData (all rows).
/// Payment % is SUM(InsurancePayment)/SUM(ChargeAmount) only for
/// ClaimStatus IN ('Fully Paid','Partially Paid').
/// Sorted by SUM(Units) descending.
/// </summary>
public sealed record CptPaymentPctRow(
    string CptCode,
    decimal SumServiceUnits,
    decimal PaidInsurancePayment,
    decimal PaidChargeAmount)
{
    /// <summary>Payment % = SUM(InsurancePayment) / SUM(ChargeAmount) × 100 (Fully Paid + Partially Paid only).</summary>
    public decimal PaymentPct => PaidChargeAmount == 0
        ? 0m
        : Math.Round(PaidInsurancePayment / PaidChargeAmount * 100m, 2);
}

// ?? Monthly Claim Volume pivot types ???????????????????????????

/// <summary>
/// Represents a Year + Month column group in the Collection Monthly Volume pivot.
/// </summary>
public sealed record CollectionMonthlyPeriod(int Year, int Month)
{
    public string Key => $"{Year:D4}-{Month:D2}";
    public string MonthLabel => new DateTime(Year, Month, 1).ToString("MMM");
}

/// <summary>
/// A single cell: encounter count + insurance paid amount
/// for one Panel (or Payer drill-down) in one Year/Month.
/// </summary>
public sealed record CollectionMonthlyCell(int EncounterCount, decimal InsurancePaidAmount);

/// <summary>Year-level subtotal across all months in that year.</summary>
public sealed record CollectionYearTotal(int EncounterCount, decimal InsurancePaidAmount);

/// <summary>
/// Top-payer drill-down sub-row under a panel row.
/// </summary>
public sealed class CollectionPayerDrillDown
{
    public required string PayerName { get; set; }
    public Dictionary<string, CollectionMonthlyCell> ByMonth { get; set; } = [];
    public Dictionary<int, CollectionYearTotal> ByYear { get; set; } = [];
    public int TotalEncounters { get; set; }
    public decimal TotalInsurancePaid { get; set; }
}

/// <summary>
/// One panel row in the Collection Monthly Claim Volume pivot table.
/// </summary>
public sealed class CollectionPanelRow
{
    public required string PanelName { get; set; }
    public Dictionary<string, CollectionMonthlyCell> ByMonth { get; set; } = [];
    public Dictionary<int, CollectionYearTotal> ByYear { get; set; } = [];
    public int TotalEncounters { get; set; }
    public decimal TotalInsurancePaid { get; set; }
    public List<CollectionPayerDrillDown> TopPayers { get; set; } = [];
}

/// <summary>
/// Fully assembled pivot for the "Monthly Claim Volume" tab on the Collection Summary page.
/// </summary>
public sealed class CollectionMonthlyVolumePivot
{
    public static readonly CollectionMonthlyVolumePivot Empty = new();
    public List<CollectionMonthlyPeriod> Periods { get; set; } = [];
    public List<int> Years { get; set; } = [];
    public List<CollectionPanelRow> PanelRows { get; set; } = [];
    public Dictionary<string, CollectionMonthlyCell> GrandTotalByMonth { get; set; } = [];
    public Dictionary<int, CollectionYearTotal> GrandTotalByYear { get; set; } = [];
    public int GrandTotalEncounters { get; set; }
    public decimal GrandTotalInsurancePaid { get; set; }
    public bool HasData => PanelRows.Count > 0;
}

// ?? Weekly Claim Volume pivot types ??????????????????????????????

/// <summary>
/// Fully assembled pivot for the "Weekly Claim Volume" tab on the Collection Summary page.
/// Columns are the last 4 posting-date weeks + Grand Total.
/// </summary>
public sealed class CollectionWeeklyVolumePivot
{
    public static readonly CollectionWeeklyVolumePivot Empty = new();
    public List<CollectionWeekBucket> Weeks { get; set; } = [];
    public List<CollectionWeeklyPanelRow> PanelRows { get; set; } = [];
    public Dictionary<string, CollectionMonthlyCell> GrandTotalByWeek { get; set; } = [];
    public int GrandTotalEncounters { get; set; }
    public decimal GrandTotalInsurancePaid { get; set; }
    public bool HasData => PanelRows.Count > 0;
}

// ?? Rep vs Payments pivot types ?????????????????????????????????

/// <summary>
/// Represents a Year + Month column group in the Rep vs Payments pivot.
/// </summary>
public sealed record RepPaymentPeriod(int Year, int Month)
{
    public string Label => $"{Year}-{Month:D2}";
}

/// <summary>
/// A single cell in the Rep vs Payments pivot: claims count + payment sum
/// for one SalesRep in one Year/Month.
/// </summary>
public sealed record RepPaymentCell(int NoOfClaims, decimal InsurancePayments);

/// <summary>
/// One row (SalesRepName) in the Rep vs Payments pivot table.
/// <see cref="Cells"/> is keyed by <see cref="RepPaymentPeriod"/> matching
/// the column order in <see cref="RepPaymentPivot.Periods"/>.
/// </summary>
public sealed class RepPaymentPivotRow
{
    public required string SalesRepName { get; set; }
    public Dictionary<RepPaymentPeriod, RepPaymentCell> Cells { get; set; } = [];
    public int GrandClaims { get; set; }
    public decimal GrandPayments { get; set; }
}

/// <summary>
/// Fully assembled pivot for the "Rep vs Payments" tab.
/// Periods are sorted chronologically; rows are sorted by grand-total payments descending.
/// </summary>
public sealed class RepPaymentPivot
{
    public static readonly RepPaymentPivot Empty = new();
    public List<RepPaymentPeriod> Periods { get; set; } = [];
    public List<RepPaymentPivotRow> Rows { get; set; } = [];
    public bool HasData => Rows.Count > 0;
}
