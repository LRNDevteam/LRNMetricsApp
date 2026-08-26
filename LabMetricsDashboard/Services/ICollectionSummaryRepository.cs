using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

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
    /// <summary>
    /// Fetches distinct payer and panel names from <c>dbo.ClaimLevelData</c> for filter dropdowns.
    /// <paramref name="panelColumn"/> must be the exact column name to read panel values from �
    /// pass the result of <c>LabCollectionPrefix.GetPanelColumn(labName)</c>:
    /// <c>PanelType</c> for NorthWest, <c>PanelNew</c> for Augustus, <c>PanelName</c> for all others.
    /// </summary>
    Task<CollectionFilterOptions> GetFilterOptionsAsync(
        string connectionString,
        string panelColumn,
        CancellationToken ct = default);

    /// <summary>
    /// Returns filter dropdown values (payer names + panel names) from the pre-aggregated
    /// <c>{prefix}_CS_MonthlyClaimVolume</c> snapshot table. The snapshot is tiny compared to
    /// <c>ClaimLevelData</c>, so this is orders of magnitude faster than the live query and
    /// avoids the column-existence probe needed for cross-lab compatibility.
    /// Used when <c>EnableCollectionSummaryReport=true</c> and no active filter.
    /// </summary>
    Task<CollectionFilterOptions> GetFilterOptionsFromAggregatesAsync(
        string connectionString,
        string prefix,
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
    /// Returns the Monthly Claim Volume pivot data for the Collection Report.
    /// Source: ClaimLevelData where InsurancePayment &gt; 0 and CheckDate is valid.
    /// Rows: PanelName with top-3 PayerName_Raw drill-down by unique claim count.
    /// Columns: Year/Month from CheckDate (Posted Date).
    /// Cells: COUNT(DISTINCT ClaimID), SUM(InsurancePayment).
    Task<CollectionMonthlyVolumeResult> GetCollectionMonthlyVolumeAsync(
        string connectionString,
        string? rule = null,
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
        string? weeklyRule = null,
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
        string? labName = null,
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
        string? labName = null,
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
        string? labName = null,
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
        string? labName = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Rep vs Payments flat rows (SalesRepName � Year � Month).
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
        string? labName = null,
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
        string? labName = null,
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
        string? labName = null,
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
        string? labName = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns Average Payments per Panel data.
    /// Source: ClaimLevelData WHERE InsurancePayment &gt; 0, last 6 months by CheckDate (Posted Date).
    /// Rows: PanelName with PayerName_Raw drill-down.
    /// Columns: No. of Claims, Total Charges, Avg Billed, Fully Paid metrics,
    ///          Adjudicated metrics, 30-day metrics, 60-day metrics.
    /// Ranked by COUNT(DISTINCT ClaimID) descending.
    /// </summary>
    Task<PanelAveragesResult> GetAvgPaymentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        string? labName = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the row count of <c>dbo.ClaimLevelData</c> respecting the active filters.
    /// Used to decide whether to include raw-data sheets in the Excel export
    /// (skip when count exceeds 200,000 rows).
    /// </summary>
    Task<int> GetClaimLevelDataCountAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the row count of <c>dbo.LineLevelData</c> respecting the active filters.
    /// Used to decide whether to include raw-data sheets in the Excel export
    /// (skip when count exceeds 200,000 rows).
    /// </summary>
    Task<int> GetLineLevelDataCountAsync(
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
        string? labName = null,
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
        string? labName = null,
        CancellationToken ct = default);

    /// <summary>
    /// SQL + parameters for the ClaimLevelData export SELECT (same query
    /// GetClaimLevelDataExportAsync runs) — lets LRN.ReportWorker stream the rows
    /// through a SqlDataReader in chunks instead of materializing them all.
    /// </summary>
    (string Sql, List<SqlParameter> Parameters) BuildClaimLevelExportQuery(
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        string? labName = null);

    /// <summary>Streaming counterpart of GetLineLevelDataExportAsync (see BuildClaimLevelExportQuery).</summary>
    (string Sql, List<SqlParameter> Parameters) BuildLineLevelExportQuery(
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        string? labName = null);

    /// <summary>
    /// Returns Status Summary data: three groupings of ClaimLevelData (all records).
    /// Grouping 1: by ClaimStatus
    /// Grouping 2: by CPTCodeXUnitsXModifier
    /// Grouping 3: by PayerName_Raw
    /// Each grouping: COUNT(DISTINCT ClaimID) as NoClaims,
    ///                SUM(InsurancePayment), SUM(InsuranceBalance), SUM(PatientBalance).
    /// Also returns a Grand Total row.
    /// Sorted by NoClaims descending within each grouping.
    /// </summary>
    Task<StatusSummaryResult> GetStatusSummaryAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        string? labName = null,
        CancellationToken ct = default);

    /// <summary>
    /// Provider Summary tab.
    /// Source: ClaimLevelData [All rows � no InsurancePayment filter].
    /// Rows: ReferringProvider.
    /// Columns: COUNT(DISTINCT ClaimID), SUM(InsurancePayment), SUM(InsuranceBalance), SUM(PatientBalance).
    /// Sorted by COUNT(DISTINCT ClaimID) DESC (Grand Total rank).
    /// </summary>
    Task<ProviderSummaryResult> GetProviderSummaryAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        string? labName = null,
        CancellationToken ct = default);

    // ?? Aggregate-table fast path ??????????????????????????????????????????????
    // The methods below read from the pre-aggregated `{prefix}_CS_*` snapshot tables
    // (e.g. NW_CS_*, Aug_CS_*) populated by the `usp_Refresh{prefix}_CS_*` procedures.
    // Used by the controller on first page load when no filters are active and the lab
    // has `EnableCollectionSummaryReport=true`. Each method returns the same shape as
    // its live counterpart; the latest snapshot `RefreshedAt` is reported via the
    // out parameter for surfacing in the UI.

    Task<Top5ReimbursementResult>      GetTop5ReimbursementFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<Top5TotalPaymentsResult>      GetTop5TotalPaymentsFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<CollectionMonthlyVolumeResult>GetCollectionMonthlyVolumeFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<CollectionWeeklyVolumeResult> GetCollectionWeeklyVolumeFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<PanelAveragesResult>          GetPanelAveragesFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<PanelAveragesResult>          GetAvgPaymentsFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<InsuranceAgingResult>         GetInsuranceAgingFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<PanelPaymentResult>           GetPanelPaymentFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<RepPaymentResult>             GetRepPaymentFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<InsurancePaymentPctResult>    GetInsurancePaymentPctFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);

    /// <summary>
    /// Returns the "Insurance Vs Payment" snapshot rows (Payer � Year/Month pivot) from
    /// <c>dbo.{prefix}_CS_InsuranceVsPayment</c>. Returns an empty list when the table
    /// does not exist or contains no rows for the lab (so callers can render a
    /// "data not available" empty state instead of failing).
    /// </summary>
    Task<List<InsuranceVsPaymentRow>>  GetInsuranceVsPaymentFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);

    /// <summary>
    /// Live/filter path for Insurance vs Payment (Payer × Posted Date month).
    /// Augustus uses <c>usp_GetAug_CS_InsuranceVsPayment_v2</c>.
    /// </summary>
    Task<List<InsuranceVsPaymentRow>> GetInsuranceVsPaymentAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        string? labName = null,
        CancellationToken ct = default);

    Task<CptPaymentPctResult>          GetCptPaymentPctFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<StatusSummaryResult>          GetStatusSummaryFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<ProviderSummaryResult>        GetProviderSummaryFromAggregatesAsync(string connectionString, string prefix, CancellationToken ct = default);

    /// <summary>
    /// Returns the most recent <c>RefreshedAt</c> timestamp across all
    /// <c>{prefix}_CS_*</c> snapshot tables that exist for the lab, or <c>null</c>
    /// when no snapshot has ever been written.
    /// </summary>
    Task<DateTime?> GetAggregateLastRefreshedAtAsync(string connectionString, string prefix, CancellationToken ct = default);
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
    /// <summary>Formatted header label: "Week N (MM/dd � MM/dd)".</summary>
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
    public decimal TotalAveragePaidAmount => TotalEncounters == 0 ? 0m : TotalInsurancePaid / TotalEncounters;
    public List<CollectionWeeklyPayerDrillDown> TopPayers { get; init; } = [];
}

/// <summary>Payer drill-down sub-row in the weekly volume pivot.</summary>
public sealed class CollectionWeeklyPayerDrillDown
{
    public required string PayerName { get; init; }
    /// <summary>1-based rank of this payer within the panel (DB-computed or position-based for live queries).</summary>
    public byte PayerRank { get; init; }
    public Dictionary<string, CollectionMonthlyCell> ByWeek { get; init; } = [];
    public int TotalEncounters { get; init; }
    public decimal TotalInsurancePaid { get; init; }
    public decimal TotalAveragePaidAmount => TotalEncounters == 0 ? 0m : TotalInsurancePaid / TotalEncounters;
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

/// <summary>One row in the Provider Summary tab.</summary>
public sealed record ProviderSummaryRow(
    int     Rank,
    string  ReferringProvider,
    int     NoOfClaims,
    decimal InsurancePayments,
    decimal InsuranceBalance,
    decimal PatientBalance);

/// <summary>Result container for the Provider Summary tab.</summary>
public sealed class ProviderSummaryResult
{
    public static readonly ProviderSummaryResult Empty = new();
    public List<ProviderSummaryRow> Rows             { get; set; } = [];
    public int     GrandNoClaims          { get; set; }
    public decimal GrandInsurancePayments { get; set; }
    public decimal GrandInsuranceBalance  { get; set; }
    public decimal GrandPatientBalance    { get; set; }
    public bool    HasData                => Rows.Count > 0;
}
