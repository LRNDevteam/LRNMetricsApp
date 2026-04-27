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
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>
    /// Active per-lab Collection Summary rule applied to the Monthly Claim Volume tab
    /// (e.g. <c>"Northwestlabs Rule"</c>). Null/empty when the lab uses the legacy default behavior.
    /// </summary>
    public string? CollectionSummaryRule { get; init; }

    // Filters (same dimensions as Production Report)
    public List<string> FilterPayerNames { get; init; } = [];
    public List<string> FilterPanelNames { get; init; } = [];
    public string? FilterFirstBillFrom { get; init; }
    public string? FilterFirstBillTo { get; init; }
    public string? FilterDosFrom { get; init; }
    public string? FilterDosTo { get; init; }
    public string? FilterCheckDateFrom { get; init; }
    public string? FilterCheckDateTo { get; init; }

    // Filter option lists
    public List<string> PayerNames { get; init; } = [];
    public List<string> PanelNames { get; init; } = [];

    public bool HasFilters => FilterPayerNames.Count > 0
        || FilterPanelNames.Count > 0
        || !string.IsNullOrWhiteSpace(FilterFirstBillFrom)
        || !string.IsNullOrWhiteSpace(FilterFirstBillTo)
        || !string.IsNullOrWhiteSpace(FilterDosFrom)
        || !string.IsNullOrWhiteSpace(FilterDosTo)
        || !string.IsNullOrWhiteSpace(FilterCheckDateFrom)
        || !string.IsNullOrWhiteSpace(FilterCheckDateTo);

    // ?? Monthly Claim Volume ?????????????????????????????????????
    public CollectionMonthlyVolumePivot MonthlyClaimVolume { get; init; } = CollectionMonthlyVolumePivot.Empty;

    /// <summary>Whether encounter counts are sourced from LineLevelData for this lab.</summary>
    public bool UsesLineEncounters { get; init; }

    // ?? Weekly Claim Volume ??????????????????????????????????????
    public CollectionWeeklyVolumePivot WeeklyClaimVolume { get; init; } = CollectionWeeklyVolumePivot.Empty;

    // ?? Top 5 Insurance Reimbursement % ?????????????????????????
    public List<InsuranceReimbursementRow> Top5Reimbursement { get; init; } = [];

    // ?? Top 5 Insurance Total Payments ??????????????????????????
    public List<InsuranceTotalPaymentRow> Top5TotalPayments { get; init; } = [];

    /// <summary>Whether the Top 5 Total Payments tab is available for the selected lab.</summary>
    public bool ShowTop5TotalPayments { get; init; } = true;

    // ?? Insurance vs Aging ??????????????????????????????????????
    public List<InsuranceAgingRow> InsuranceAging { get; init; } = [];

    // ?? Panel vs Payment ????????????????????????????????????????
    public List<PanelPaymentRow> PanelPayments { get; init; } = [];

    // ?? Rep vs Payments ??????????????????????????????????????????
    public RepPaymentPivot RepPayments { get; init; } = RepPaymentPivot.Empty;

    // ?? Insurance vs Payment % ??????????????????????????????????
    public List<InsurancePaymentPctRow> InsurancePaymentPct { get; init; } = [];

    // ?? CPT vs Payment % ???????????????????????????????????????
    public List<CptPaymentPctRow> CptPaymentPct { get; init; } = [];

    // ?? Panel Averages ????????????????????????????????????????????
    public List<PanelAveragesRow> PanelAverages { get; init; } = [];

    /// <summary>Error message when the DB query fails or is unavailable.</summary>
    public string? ErrorMessage { get; init; }
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
    public required string PayerName { get; init; }
    public Dictionary<string, CollectionMonthlyCell> ByMonth { get; init; } = [];
    public Dictionary<int, CollectionYearTotal> ByYear { get; init; } = [];
    public int TotalEncounters { get; init; }
    public decimal TotalInsurancePaid { get; init; }
}

/// <summary>
/// One panel row in the Collection Monthly Claim Volume pivot table.
/// </summary>
public sealed class CollectionPanelRow
{
    public required string PanelName { get; init; }
    public Dictionary<string, CollectionMonthlyCell> ByMonth { get; init; } = [];
    public Dictionary<int, CollectionYearTotal> ByYear { get; init; } = [];
    public int TotalEncounters { get; init; }
    public decimal TotalInsurancePaid { get; init; }
    public List<CollectionPayerDrillDown> TopPayers { get; init; } = [];
}

/// <summary>
/// Fully assembled pivot for the "Monthly Claim Volume" tab on the Collection Summary page.
/// </summary>
public sealed class CollectionMonthlyVolumePivot
{
    public static readonly CollectionMonthlyVolumePivot Empty = new();
    public List<CollectionMonthlyPeriod> Periods { get; init; } = [];
    public List<int> Years { get; init; } = [];
    public List<CollectionPanelRow> PanelRows { get; init; } = [];
    public Dictionary<string, CollectionMonthlyCell> GrandTotalByMonth { get; init; } = [];
    public Dictionary<int, CollectionYearTotal> GrandTotalByYear { get; init; } = [];
    public int GrandTotalEncounters { get; init; }
    public decimal GrandTotalInsurancePaid { get; init; }
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
    public List<CollectionWeekBucket> Weeks { get; init; } = [];
    public List<CollectionWeeklyPanelRow> PanelRows { get; init; } = [];
    public Dictionary<string, CollectionMonthlyCell> GrandTotalByWeek { get; init; } = [];
    public int GrandTotalEncounters { get; init; }
    public decimal GrandTotalInsurancePaid { get; init; }
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
    public required string SalesRepName { get; init; }
    public Dictionary<RepPaymentPeriod, RepPaymentCell> Cells { get; init; } = [];
    public int GrandClaims { get; init; }
    public decimal GrandPayments { get; init; }
}

/// <summary>
/// Fully assembled pivot for the "Rep vs Payments" tab.
/// Periods are sorted chronologically; rows are sorted by grand-total payments descending.
/// </summary>
public sealed class RepPaymentPivot
{
    public static readonly RepPaymentPivot Empty = new();
    public List<RepPaymentPeriod> Periods { get; init; } = [];
    public List<RepPaymentPivotRow> Rows { get; init; } = [];
    public bool HasData => Rows.Count > 0;
}
