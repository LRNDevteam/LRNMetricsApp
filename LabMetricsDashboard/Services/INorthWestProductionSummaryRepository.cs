using LabMetricsDashboard.Models;


namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads NorthWest production report data from the pre-aggregated SP output tables
/// (NW_MonthlyBilledProductionSummary, NW_WeeklyBilledProductionSummary,
/// NW_PayerBreakdown, NW_PayerByPanel, NW_UnbilledAging, NW_CPTBreakdown,
/// NW_CodingPanelSummary, NW_CodingCPTDetail).
/// Used by the "Production Summary Report" page when no filters are active.
/// When filters are active the page falls back to <see cref="IProductionReportRepository"/>.
/// </summary>
public interface INorthWestProductionSummaryRepository
{
    /// <summary>
    /// Returns distinct PayerName_Raw and PanelType values for the filter dropdowns.
    /// Uses the same NW ClaimStatus exclusion filter as the SPs so the lists match
    /// exactly what is visible in the aggregate tables.
    /// Called on every page load — aggregate and filtered — to keep dropdowns populated.
    /// </summary>
    Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default);

    /// <summary>Reads NW_MonthlyBilledProductionSummary ? monthly panel + top-3 payer pivot.</summary>
    Task<ProductionReportResult> GetMonthlyAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads NW_WeeklyBilledProductionSummary ? last-4-week panel + top-3 payer pivot.</summary>
    Task<WeeklyClaimVolumeResult> GetWeeklyAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads NW_CodingPanelSummary + NW_CodingCPTDetail ? coding panel + CPT drill-down.</summary>
    Task<CodingResult> GetCodingAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads NW_PayerBreakdown ? payer × month pivot.</summary>
    Task<PayerBreakdownResult> GetPayerBreakdownAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads NW_PayerByPanel ? payer × panel pivot.</summary>
    Task<PayerPanelResult> GetPayerByPanelAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads NW_UnbilledAging ? payer × aging bucket pivot.</summary>
    Task<UnbilledAgingResult> GetUnbilledAgingAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads NW_CPTBreakdown ? payer × month CPT count + charge pivot.</summary>
    Task<CptBreakdownResult> GetCptBreakdownAsync(string connectionString, CancellationToken ct = default);
}

