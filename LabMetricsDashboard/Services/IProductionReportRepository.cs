using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Monthly Claim Volume data from <c>dbo.ClaimLevelData</c>
/// for the Production Report page.
/// </summary>
public interface IProductionReportRepository
{
    /// <summary>
    /// Returns the pivot data for the Monthly Claim Volume table:
    /// grouped by PanelName × Year(FirstBilledDate) / Month(FirstBilledDate).
    /// Each panel includes top-3 payer drill-down rows.
    /// When <paramref name="rule"/> is <c>"Rule1"</c> the column date source
    /// switches to <c>ChargeEnteredDate</c> while the row filter retains
    /// <c>FirstBilledDate IS NOT NULL</c> and <c>PayerName &lt;&gt; ''</c>.
    /// When <paramref name="rule"/> is <c>"Rule2"</c> the column date source is
    /// also <c>ChargeEnteredDate</c>, but the row filter excludes any row whose
    /// <c>PayerName_Raw</c> contains <c>None</c>, <c>Accu Labs</c>, <c>Client Bill</c>,
    /// <c>Client</c>, <c>Patient</c>, or <c>Patient Pay</c> (Certus Laboratories spec).
    /// When <paramref name="rule"/> is <c>"Rule3"</c> the column date source is
    /// also <c>ChargeEnteredDate</c> and the row filter requires
    /// <c>PayerName &lt;&gt; ''</c>, <c>ChargeEnteredDate IS NOT NULL</c> and
    /// <c>FirstBilledDate IS NOT NULL</c> (Augustus Laboratories spec).
    /// Row source is <c>PanelName</c> until the <c>PanelNameNew</c> column is added.
    /// When <paramref name="rule"/> is <c>"Rule4"</c> the behavior is currently identical
    /// to <c>"Rule3"</c> (same filters, ChargeEnteredDate columns, <c>PanelName</c> fallback);
    /// it exists as a distinct rule so its assigned lab can be tagged today and Rule4 can
    /// diverge later without touching other labs.
    /// When <paramref name="rule"/> is <c>"Rule5"</c> the behavior is identical to the
    /// legacy default: column date source = <c>FirstBilledDate</c>, filter requires
    /// <c>PayerName &lt;&gt; ''</c> and <c>FirstBilledDate IS NOT NULL</c>, with Top 3
    /// <c>PayerName</c> drill-down per panel by <c>COUNT(DISTINCT ClaimID)</c>.
    /// </summary>
    Task<ProductionReportResult> GetMonthlyClaimVolumeAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        CancellationToken ct = default,
        bool panelNewStrict = false);   // true ? PanelNew only (ProductionSummaryReport); false ? PanelNew with PanelName fallback (ProductionReport)
    /// <summary>
    /// Returns the pivot data for the Weekly Claim Volume table:
    /// grouped by PanelName × Week for the last 4 weeks. Each panel includes
    /// top-3 payer drill-down rows.
    /// The <paramref name="rule"/> selects the column date source and filter:
    /// <c>"Rule2"</c> and the default use <c>FirstBilledDate</c> with <c>PayerName</c> not blank;
    /// <c>"Rule3"</c>/<c>"Rule4"</c> use <c>ChargeEnteredDate</c> with both date columns required;
    /// <c>"Rule5"</c> uses <c>ChargeEnteredDate</c> with the <c>PayerName_Raw</c> exclusion list.
    /// The <paramref name="weekRange"/> string (e.g. <c>"Mon to Sun"</c>, <c>"Thu to Wed"</c>)
    /// controls week boundaries; unset/unrecognized falls back to Monday-to-Sunday.
    /// </summary>
    Task<WeeklyClaimVolumeResult> GetWeeklyClaimVolumeAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        string? weekRange = null,
        CancellationToken ct = default,
        bool panelNewStrict = false);   // true ? PanelNew only (ProductionSummaryReport); false ? PanelNew with PanelName fallback

    /// <summary>
    /// Returns the Coding table data: rows where FirstBilledDate is blank,
    /// grouped by PanelName with CPT Code drill-down.
    /// Claim Count is <c>COUNT(DISTINCT AccessionNumber)</c> (unique visit number),
    /// Total Charge is <c>SUM(ChargeAmount)</c>. Sorted by Grand Total descending.
    /// </summary>
    Task<CodingResult> GetCodingAsync(
        string connectionString,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Payer Breakdown table data:
    /// grouped by PayerName × Year/Month(ChargeEnteredDate).
    /// </summary>
    Task<PayerBreakdownResult> GetPayerBreakdownAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
<<<<<<< HEAD
        CancellationToken ct = default,
        bool panelNewStrict = false);   // true ? PanelNew only (ProductionSummaryReport); false ? PanelNew with PanelName fallback
=======
        CancellationToken ct = default);
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5

    /// <summary>
    /// Returns the Payer X Panel cross-tab data:
    /// grouped by PayerName × PanelName where ChargeEnteredDate is a valid date.
    /// </summary>
    Task<PayerPanelResult> GetPayerPanelAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
<<<<<<< HEAD
        CancellationToken ct = default,
        bool panelNewStrict = false);   // true ? PanelNew only (ProductionSummaryReport); false ? PanelNew with PanelName fallback
=======
        CancellationToken ct = default);
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5

    /// <summary>
    /// Returns the Unbilled X Aging table data:
    /// rows where FirstBilledDate is blank, grouped by PanelName × AgingBucket(DaystoDOS).
    /// </summary>
    Task<UnbilledAgingResult> GetUnbilledAgingAsync(
        string connectionString,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the CPT Breakdown table data from LineLevelData:
    /// grouped by CPTCode × Year/Month(FirstBilledDate).
    /// </summary>
    Task<CptBreakdownResult> GetCptBreakdownAsync(
        string connectionString,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
<<<<<<< HEAD
        CancellationToken ct = default,
        string? rule = null);   // Rule3 (Augustus) ? COUNT DISTINCT CPTCode instead of SUM Units
=======
        CancellationToken ct = default);
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5

    /// <summary>Returns all ClaimLevelData rows for Excel export, respecting Production Report filters.</summary>
    Task<List<Dictionary<string, object?>>> GetClaimLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default);

    /// <summary>Returns all LineLevelData rows for Excel export, respecting Production Report filters.</summary>
    Task<List<Dictionary<string, object?>>> GetLineLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default);
}

/// <summary>Result container for the Monthly Claim Volume table.</summary>
public sealed record ProductionReportResult(
    List<string> PayerNames,
    List<string> PanelNames,
    List<string> Months,
    List<int> Years,
    List<ProductionPanelRow> PanelRows,
    Dictionary<string, ProductionMonthCell> GrandTotalByMonth,
    int GrandTotalClaims,
    decimal GrandTotalCharges);

/// <summary>Result container for the Weekly Claim Volume table.</summary>
public sealed record WeeklyClaimVolumeResult(
    List<WeekColumn> WeekColumns,
    List<WeeklyPanelRow> PanelRows,
    Dictionary<string, ProductionMonthCell> GrandTotalByWeek,
    int GrandTotalClaims,
    decimal GrandTotalCharges);

/// <summary>Result container for the Coding table.</summary>
public sealed record CodingResult(
    List<CodingPanelRow> PanelRows,
    int GrandTotalClaims,
    decimal GrandTotalCharges);

/// <summary>Result container for the Payer Breakdown table.</summary>
public sealed record PayerBreakdownResult(
    List<string> Months,
    List<int> Years,
    List<PayerBreakdownRow> PayerRows,
    Dictionary<string, int> GrandTotalByMonth,
    int GrandTotal);

/// <summary>Result container for the Payer X Panel cross-tab table.</summary>
public sealed record PayerPanelResult(
    List<string> PanelColumns,
    List<PayerPanelRow> PayerRows,
    Dictionary<string, ProductionMonthCell> GrandTotalByPanel,
    int GrandTotalClaims,
    decimal GrandTotalCharges);

/// <summary>Result container for the Unbilled X Aging table.</summary>
public sealed record UnbilledAgingResult(
    List<UnbilledAgingRow> PanelRows,
    Dictionary<string, ProductionMonthCell> GrandTotalByBucket,
    int GrandTotalClaims,
    decimal GrandTotalCharges);

/// <summary>Result container for the CPT Breakdown table.</summary>
public sealed record CptBreakdownResult(
    List<string> Months,
    List<int> Years,
    List<CptBreakdownRow> CptRows,
    Dictionary<string, CptBreakdownCell> GrandTotalByMonth,
    decimal GrandTotalUnits,
    decimal GrandTotalCharges);
