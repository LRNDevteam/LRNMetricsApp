using LabMetricsDashboard.Models;

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
    Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default);

    /// <summary>
    /// <c>true</c> when this lab's <c>usp_Get{Prefix}MonthlyBilledProductionSummary</c>
    /// and <c>usp_Get{Prefix}WeeklyBilledProductionSummary</c> stored procedures
    /// accept filter parameters and aggregate live from <c>dbo.ClaimLevelData</c>
    /// when filters are supplied. When <c>false</c>, callers must fall back to
    /// <see cref="IProductionReportRepository"/> for the filtered query.
    /// </summary>
    bool SupportsFilteredMonthlyWeeklySp { get; }

    /// <summary>Reads <c>{prefix}MonthlyBilledProductionSummary</c> ? monthly panel + top-3 payer pivot.</summary>
    /// <remarks>
    /// When <see cref="SupportsFilteredMonthlyWeeklySp"/> is <c>true</c>, the optional filter
    /// parameters are passed to the read SP which switches to a live aggregation against
    /// <c>dbo.ClaimLevelData</c>. When all filter parameters are <c>null</c> the SP returns
    /// rows from the pre-aggregated snapshot table (fast path).
    /// </remarks>
    Task<ProductionReportResult> GetMonthlyAsync(
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
    Task<WeeklyClaimVolumeResult> GetWeeklyAsync(
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
    Task<CodingResult> GetCodingAsync(
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
        CancellationToken ct = default);

    /// <summary>Reads <c>{prefix}PayerByPanel</c> ? payer × panel pivot.</summary>
    /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
    Task<PayerPanelResult> GetPayerByPanelAsync(
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
    Task<UnbilledAgingResult> GetUnbilledAgingAsync(
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
    Task<CptBreakdownResult> GetCptBreakdownAsync(
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
