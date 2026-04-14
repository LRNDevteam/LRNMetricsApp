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
    /// </summary>
    Task<ProductionReportResult> GetMonthlyClaimVolumeAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default);
    /// <summary>
    /// Returns the pivot data for the Weekly Claim Volume table:
    /// grouped by PanelName × Week(FirstBilledDate) for the last 4 weeks.
    /// Each panel includes top-3 payer drill-down rows.
    /// </summary>
    Task<WeeklyClaimVolumeResult> GetWeeklyClaimVolumeAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Coding table data: rows where FirstBilledDate is blank,
    /// grouped by PanelName with CPT Code drill-down.
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
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Payer X Panel cross-tab data:
    /// grouped by PayerName × PanelName where ChargeEnteredDate is a valid date.
    /// </summary>
    Task<PayerPanelResult> GetPayerPanelAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the Unbilled X Aging table data:
    /// rows where FirstBilledDate is blank, grouped by PanelName × AgingBucket(DaystoDOS).
    /// </summary>
    Task<UnbilledAgingResult> GetUnbilledAgingAsync(
        string connectionString,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns the CPT Breakdown table data from LineLevelData:
    /// grouped by CPTCode × Year/Month(FirstBilledDate).
    /// </summary>
    Task<CptBreakdownResult> GetCptBreakdownAsync(
        string connectionString,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
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
