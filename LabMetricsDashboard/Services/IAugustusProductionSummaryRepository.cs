using SharedCodingResult = LRN.ProductionReports.Services.CodingResult;
using SharedCptBreakdownResult = LRN.ProductionReports.Services.CptBreakdownResult;
using SharedPayerBreakdownResult = LRN.ProductionReports.Services.PayerBreakdownResult;
using SharedPayerPanelResult = LRN.ProductionReports.Services.PayerPanelResult;
using SharedProductionReportResult = LRN.ProductionReports.Services.ProductionReportResult;
using SharedUnbilledAgingResult = LRN.ProductionReports.Services.UnbilledAgingResult;
using SharedWeeklyClaimVolumeResult = LRN.ProductionReports.Services.WeeklyClaimVolumeResult;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Augustus Labs production report data from the pre-aggregated SP output tables
/// (Aug_MonthlyBilledProductionSummary, Aug_WeeklyBilledProductionSummary,
///  Aug_PayerBreakdown, Aug_PayerByPanel, Aug_UnbilledAging, Aug_CPTBreakdown,
///  Aug_CodingPanelSummary, Aug_CodingCPTDetail).
/// Used by the "Production Summary Report" page when no filters are active.
/// When filters are active the page falls back to <see cref="IProductionReportRepository"/>.
/// </summary>
public interface IAugustusProductionSummaryRepository
{
    /// <summary>
    /// Returns distinct PayerName_Raw and PanelNew values for the filter dropdowns.
    /// Applies the Augustus base filter (FirstBilledDate IS NOT NULL AND ChargeEnteredDate IS NOT NULL)
    /// so the lists match exactly what is visible in the aggregate tables.
    /// </summary>
    Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default);

    /// <summary>Reads Aug_MonthlyBilledProductionSummary ? monthly panel + top-3 payer pivot.</summary>
        /// <remarks>
        /// When all filter parameters are <c>null</c> the SP serves rows from the pre-aggregated
        /// snapshot table (fast path). When any filter is supplied the SP aggregates live from
        /// <c>dbo.ClaimLevelData</c> using the same Augustus filter semantics.
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

        /// <summary>Reads Aug_WeeklyBilledProductionSummary ? last-4-week panel + top-3 payer pivot.</summary>
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

        /// <summary>Reads Aug_CodingPanelSummary + Aug_CodingCPTDetail ? coding panel + CPT drill-down.</summary>
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

        /// <summary>Reads Aug_PayerBreakdown ? payer × month pivot.</summary>
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

        /// <summary>Reads Aug_PayerByPanel ? payer × panel pivot.</summary>
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

        /// <summary>Reads Aug_UnbilledAging ? panel × aging bucket pivot.</summary>
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

        /// <summary>Reads Aug_CPTBreakdown ? CPT code × month pivot.</summary>
        /// <remarks>See <see cref="GetMonthlyAsync"/> for filter-parameter behaviour.</remarks>
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
