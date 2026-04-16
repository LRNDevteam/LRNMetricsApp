using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Collection Summary report data from <c>dbo.ClaimLevelData</c> and <c>dbo.LineLevelData</c>.
/// </summary>
public interface ICollectionSummaryRepository
{
    /// <summary>
    /// Returns the distinct PayerName and PanelName lists for filter dropdowns.
    /// Source: ClaimLevelData (unfiltered).
    /// </summary>
    Task<CollectionFilterOptions> GetFilterOptionsAsync(
        string connectionString,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Monthly Claim Volume pivot data for the Collection Report.
    /// Source: ClaimLevelData where InsurancePayment &gt; 0
    ///         and ClaimStatus IN ('Fully Paid','Partially Paid','Paid-Client').
    /// Rows: PanelName with top-3 payer drill-down by encounter count.
    /// Columns: Year/Month from FirstBilledDate.
    /// Cells: COUNT(line items), SUM(InsurancePayment).
    /// When <paramref name="useLineEncounters"/> is true, encounter counts
    /// are read from <c>dbo.LineLevelData</c> instead.
    /// </summary>
    Task<CollectionMonthlyVolumeResult> GetCollectionMonthlyVolumeAsync(
        string connectionString,
        bool useLineEncounters = false,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Weekly Claim Volume pivot data for the Collection Report.
    /// Source: ClaimLevelData where InsurancePayment &gt; 0
    ///         and ClaimStatus IN ('Fully Paid','Partially Paid','Paid-Client').
    /// Rows: PanelName with top-3 payer drill-down by encounter count.
    /// Columns: Last 4 ISO weeks derived from PostingDate.
    /// Cells: COUNT(line items or unique claims), SUM(InsurancePayment).
    /// When <paramref name="useLineEncounters"/> is true, encounter counts
    /// are read from <c>dbo.LineLevelData</c> instead.
    /// </summary>
    Task<CollectionWeeklyVolumeResult> GetCollectionWeeklyVolumeAsync(
        string connectionString,
        bool useLineEncounters = false,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Top 5 Insurance Reimbursement % rows.
    /// Source: ClaimLevelData where InsurancePayment &gt; 0
    ///         and ClaimStatus IN ('Fully Paid','Partially Paid','Patient Responsibility').
    /// Ranked by COUNT(DISTINCT AccessionNumber) descending, top 5.
    /// </summary>
    Task<Top5ReimbursementResult> GetTop5ReimbursementAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Top 5 Insurance Total Payments rows.
    /// Source: ClaimLevelData where InsurancePayment &gt; 0
    ///         and ClaimStatus IN ('Fully Paid','Partially Paid','Patient Responsibility').
    /// Ranked by COUNT(DISTINCT VisitNumber) descending, top 5.
    /// </summary>
    Task<Top5TotalPaymentsResult> GetTop5TotalPaymentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Insurance vs Aging pivot rows.
    /// Source: ClaimLevelData where ClaimStatus = 'No Response'.
    /// Aging buckets derived from DaysToDOS: Current (&lt;30), 30+, 60+, 90+, 120+.
    /// Each cell: COUNT(DISTINCT AccessionNumber), SUM(InsuranceBalance).
    /// Sorted by grand-total InsuranceBalance descending.
    /// </summary>
    Task<InsuranceAgingResult> GetInsuranceAgingAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Panel vs Payment rows.
    /// Source: ClaimLevelData where InsurancePayment &gt; 0.
    /// Grouped by PanelName. Columns: COUNT(DISTINCT ClaimID), SUM(InsurancePayment).
    /// Sorted by SUM(InsurancePayment) descending.
    /// </summary>
    Task<PanelPaymentResult> GetPanelPaymentAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Rep vs Payments flat rows (SalesRepName × Year × Month).
    /// Source: ClaimLevelData where InsurancePayment &gt; 0 and CheckDate is a valid date.
    /// Each row: SalesRepName, Year, Month, COUNT(DISTINCT ClaimID), SUM(InsurancePayment).
    /// </summary>
    Task<RepPaymentResult> GetRepPaymentAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Insurance vs Payment % rows.
    /// Source: ClaimLevelData where InsurancePayment &gt; 0.
    /// Per PayerName: COUNT(DISTINCT ClaimID), SUM(InsurancePayment),
    /// and Payment % = SUM(InsurancePayment)/SUM(ChargeAmount) for Fully Paid + Partially Paid only.
    /// Sorted by SUM(InsurancePayment) descending.
    /// </summary>
    Task<InsurancePaymentPctResult> GetInsurancePaymentPctAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the CPT vs Payment % rows.
    /// Source: LineLevelData (all rows).
    /// Per CPTCode: SUM(Units), and Payment % = SUM(InsurancePayment)/SUM(ChargeAmount)
    /// for ClaimStatus IN ('Fully Paid','Partially Paid') only.
    /// Sorted by SUM(Units) descending.
    /// </summary>
    Task<CptPaymentPctResult> GetCptPaymentPctAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Panel Averages tab data.
    /// Source: ClaimLevelData, last 6 months by DateOfService.
    /// Rows: PanelName with PayerName drill-down.
    /// Columns: claims count, charges, avg billed, carrier payment, avg carrier payment,
    ///          fully-paid metrics, adjudicated metrics, 30-day metrics, 60-day metrics.
    /// </summary>
    Task<PanelAveragesResult> GetPanelAveragesAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns all ClaimLevelData rows for Excel export, respecting the active filters.
    /// </summary>
    Task<List<Dictionary<string, object?>>> GetClaimLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns all LineLevelData rows for Excel export, respecting the active filters.
    /// </summary>
    Task<List<Dictionary<string, object?>>> GetLineLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);
}

/// <summary>Distinct PayerName and PanelName lists for the filter dropdowns.</summary>
public sealed record CollectionFilterOptions(
    List<string> PayerNames,
    List<string> PanelNames);

/// <summary>Result container for the Collection Monthly Claim Volume tab.</summary>
public sealed record CollectionMonthlyVolumeResult(
List<CollectionMonthlyPeriod> Periods,
    List<int> Years,
    List<CollectionPanelRow> PanelRows,
    Dictionary<string, CollectionMonthlyCell> GrandTotalByMonth,
    Dictionary<int, CollectionYearTotal> GrandTotalByYear,
    int GrandTotalEncounters,
    decimal GrandTotalInsurancePaid);

/// <summary>Represents a single week column in the weekly volume pivot.</summary>
public sealed record CollectionWeekBucket(
    int WeekNumber,
    DateTime WeekStart,
    DateTime WeekEnd)
{
    /// <summary>Display key for dictionary lookups.</summary>
    public string Key => $"W{WeekNumber}";
    /// <summary>Formatted header label: "Week N (MM/dd – MM/dd)".</summary>
    public string Label => $"Week {WeekNumber} ({WeekStart:MM/dd} - {WeekEnd:MM/dd})";
}

/// <summary>Result container for the Collection Weekly Claim Volume tab.</summary>
public sealed record CollectionWeeklyVolumeResult(
List<CollectionWeekBucket> Weeks,
    List<CollectionWeeklyPanelRow> PanelRows,
    Dictionary<string, CollectionMonthlyCell> GrandTotalByWeek,
    int GrandTotalEncounters,
    decimal GrandTotalInsurancePaid);

/// <summary>One panel row in the weekly volume pivot.</summary>
public sealed class CollectionWeeklyPanelRow
{
    public required string PanelName { get; init; }
    public Dictionary<string, CollectionMonthlyCell> ByWeek { get; init; } = [];
    public int TotalEncounters { get; init; }
    public decimal TotalInsurancePaid { get; init; }
    public List<CollectionWeeklyPayerDrillDown> TopPayers { get; init; } = [];
}

/// <summary>Payer drill-down sub-row in the weekly volume pivot.</summary>
public sealed class CollectionWeeklyPayerDrillDown
{
    public required string PayerName { get; init; }
    public Dictionary<string, CollectionMonthlyCell> ByWeek { get; init; } = [];
    public int TotalEncounters { get; init; }
    public decimal TotalInsurancePaid { get; init; }
}

/// <summary>Result container for the Top 5 Insurance Reimbursement % tab.</summary>
public sealed record Top5ReimbursementResult(
List<InsuranceReimbursementRow> Rows);

/// <summary>Result container for the Top 5 Insurance Total Payments tab.</summary>
public sealed record Top5TotalPaymentsResult(
    List<InsuranceTotalPaymentRow> Rows);

/// <summary>Result container for the Insurance vs Aging tab.</summary>
public sealed record InsuranceAgingResult(
    List<InsuranceAgingRow> Rows);

/// <summary>Result container for the Panel vs Payment tab.</summary>
public sealed record PanelPaymentResult(
    List<PanelPaymentRow> Rows);

/// <summary>
/// Flat row returned by the Rep vs Payments SQL query.
/// One row per SalesRepName + Year + Month combination.
/// </summary>
public sealed record RepPaymentFlatRow(
    string SalesRepName,
    int Year,
    int Month,
    int NoOfClaims,
    decimal InsurancePayments);

/// <summary>Result container for the Rep vs Payments tab.</summary>
public sealed record RepPaymentResult(
    List<RepPaymentFlatRow> Rows);

/// <summary>Result container for the Insurance vs Payment % tab.</summary>
public sealed record InsurancePaymentPctResult(
    List<InsurancePaymentPctRow> Rows);

/// <summary>Result container for the CPT vs Payment % tab.</summary>
public sealed record CptPaymentPctResult(
    List<CptPaymentPctRow> Rows);

/// <summary>Result container for the Panel Averages tab.</summary>
public sealed record PanelAveragesResult(
List<PanelAveragesRow> PanelRows);

/// <summary>Metrics cell shared by panel rows and payer drill-down rows in the Panel Averages tab.</summary>
public sealed record PanelAveragesMetrics(
    int ClaimCount,
    decimal TotalCharges,
    decimal CarrierPayment,
    int FullyPaidCount,
    decimal FullyPaidAmount,
    int AdjudicatedCount,
    decimal AdjudicatedAmount,
    int Days30Count,
    decimal Days30Amount,
    int Days60Count,
    decimal Days60Amount)
{
    /// <summary>Average billed amount per claim.</summary>
    public decimal AvgBilled => ClaimCount == 0 ? 0m : Math.Round(TotalCharges / ClaimCount, 2);
    /// <summary>Average carrier payment per claim.</summary>
    public decimal AvgCarrierPayment => ClaimCount == 0 ? 0m : Math.Round(CarrierPayment / ClaimCount, 2);
    /// <summary>Average fully-paid amount per fully-paid claim.</summary>
    public decimal AvgFullyPaid => FullyPaidCount == 0 ? 0m : Math.Round(FullyPaidAmount / FullyPaidCount, 2);
    /// <summary>Average adjudicated amount per adjudicated claim.</summary>
    public decimal AvgAdjudicated => AdjudicatedCount == 0 ? 0m : Math.Round(AdjudicatedAmount / AdjudicatedCount, 2);
    /// <summary>Average 30-day amount per 30-day claim.</summary>
    public decimal AvgDays30 => Days30Count == 0 ? 0m : Math.Round(Days30Amount / Days30Count, 2);
    /// <summary>Average 60-day amount per 60-day claim.</summary>
    public decimal AvgDays60 => Days60Count == 0 ? 0m : Math.Round(Days60Amount / Days60Count, 2);
}

/// <summary>One panel row in the Panel Averages tab with payer drill-down.</summary>
public sealed class PanelAveragesRow
{
    public required string PanelName { get; init; }
    public required PanelAveragesMetrics Metrics { get; init; }
    public List<PanelAveragesPayerRow> Payers { get; init; } = [];
}

/// <summary>Payer drill-down sub-row in the Panel Averages tab.</summary>
public sealed class PanelAveragesPayerRow
{
    public required string PayerName { get; init; }
    public required PanelAveragesMetrics Metrics { get; init; }
}
