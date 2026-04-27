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
    Task<ProductionReportResult> GetMonthlyAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads Aug_WeeklyBilledProductionSummary ? last-4-week panel + top-3 payer pivot.</summary>
    Task<WeeklyClaimVolumeResult> GetWeeklyAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads Aug_CodingPanelSummary + Aug_CodingCPTDetail ? coding panel + CPT drill-down.</summary>
    Task<CodingResult> GetCodingAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads Aug_PayerBreakdown ? payer × month pivot.</summary>
    Task<PayerBreakdownResult> GetPayerBreakdownAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads Aug_PayerByPanel ? payer × panel pivot.</summary>
    Task<PayerPanelResult> GetPayerByPanelAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads Aug_UnbilledAging ? panel × aging bucket pivot.</summary>
    Task<UnbilledAgingResult> GetUnbilledAgingAsync(string connectionString, CancellationToken ct = default);

    /// <summary>Reads Aug_CPTBreakdown ? CPT code × month pivot.</summary>
    Task<CptBreakdownResult> GetCptBreakdownAsync(string connectionString, CancellationToken ct = default);
}
