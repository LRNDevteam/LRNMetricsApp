using LRN.ProductionReports.Models;
using SharedCodingResult = LRN.ProductionReports.Services.CodingResult;
using SharedCptBreakdownResult = LRN.ProductionReports.Services.CptBreakdownResult;
using SharedPayerBreakdownResult = LRN.ProductionReports.Services.PayerBreakdownResult;
using SharedPayerPanelResult = LRN.ProductionReports.Services.PayerPanelResult;
using SharedProductionReportResult = LRN.ProductionReports.Services.ProductionReportResult;
using SharedUnbilledAgingResult = LRN.ProductionReports.Services.UnbilledAgingResult;
using SharedWeeklyClaimVolumeResult = LRN.ProductionReports.Services.WeeklyClaimVolumeResult;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads production report data from the pre-aggregated SP output tables for a specific lab.
/// Used by <see cref="Controllers.DashboardController.ProductionSummaryReport"/> when no
/// filters are active (fast path).  When filters are applied the controller falls back to
/// <see cref="IProductionReportRepository"/> for live queries.
/// </summary>
/// <remarks>
/// One instance of <see cref="SqlLabProductionSummaryRepository"/> is registered per lab
/// in DI (keyed by lab name) using <see cref="LabSummaryTableConfig"/> to parameterise
/// the table prefix and schema differences between labs.
/// Covered labs: Certus, Cove, Elixir, PCRLabsofAmerica, Beech_Tree, Rising_Tides.
/// </remarks>
public interface ILabProductionSummaryRepository
{
    /// <summary>
    /// Returns distinct PayerName_Raw and Panelname values for the filter dropdowns.
    /// Uses <c>TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL</c> so the lists match
    /// what the aggregate SPs include.
    /// </summary>
    /// <summary>
    /// <c>true</c> when this repository is backed by the Certus lab tables (<c>Cert_</c> prefix).
    /// The CPT Breakdown units column for Certus represents <c>BilledUnits</c>, not a claim count.
    /// </summary>
    bool IsCertus { get; }

    bool SupportsFilteredMonthlyWeeklySp { get; }

    Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default);

    /// <summary>
    /// <c>true</c> when this lab's <c>usp_Get{Prefix}MonthlyBilledProductionSummary</c>
    /// <remarks>
    /// When <see cref="SupportsFilteredMonthlyWeeklySp"/> is <c>true</c>, the optional filter
    /// parameters are passed to the read SP which switches to a live aggregation against
    /// <c>dbo.ClaimLevelData</c>. When all filter parameters are <c>null</c> the SP returns
    /// rows from the pre-aggregated snapshot table (fast path).
    /// </remarks>
    Task<SharedProductionReportResult> GetMonthlyAsync(
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

    /// <summary>Reads <c>{prefix}WeeklyBilledProductionSummary</c> ? last-4-week panel + top-3 payer pivot.</summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    Task<SharedWeeklyClaimVolumeResult> GetWeeklyAsync(
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

    /// <summary>
    /// Reads <c>{prefix}CodingPanelSummary</c> + <c>{prefix}CodingCPTDetail</c>.
    /// Returns an empty result when the lab has no coding tables
    /// (<see cref="LabSummaryTableConfig.HasCodingTables"/> is <c>false</c>).
    /// </summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    Task<SharedCodingResult> GetCodingAsync(
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

    /// <summary>Reads <c>{prefix}PayerBreakdown</c> ? payer × month pivot.</summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    Task<SharedPayerBreakdownResult> GetPayerBreakdownAsync(
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

    /// <summary>Reads <c>{prefix}PayerByPanel</c> ? payer × panel pivot.</summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    Task<SharedPayerPanelResult> GetPayerByPanelAsync(
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

    /// <summary>
    /// Reads <c>{prefix}UnbilledAging</c> ? panel/payer × aging-bucket pivot.
    /// The row key column and bucket column vary per lab (see <see cref="LabSummaryTableConfig"/>).
    /// </summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    Task<SharedUnbilledAgingResult> GetUnbilledAgingAsync(
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

    /// <summary>Reads <c>{prefix}CPTBreakdown</c> ? CPT × month pivot.</summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    /// <summary>
    /// Reads <c>usp_Get{prefix}PanelBreakdownWithPayers</c> - the Production Summary
    /// "Panel Breakdown" table: one parent row per panel with its payers as
    /// <see cref="PayerBreakdownRow.ChildRows"/>, pivoted by billed month.
    /// Deployed by <c>Sql\40_AllLabs_PanelBreakdownWithPayers.sql</c>; returns an
    /// empty result (never throws) when that SP is not yet on the lab's database.
    /// </summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    Task<SharedPayerBreakdownResult> GetPanelBreakdownAsync(
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

    Task<SharedCptBreakdownResult> GetCptBreakdownAsync(
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
