using LRN.ProductionReports.Models;

namespace LRN.ProductionReports.Services;

/// <summary>
/// Reads Collection Summary data for display and Excel generation.
/// </summary>
public interface ICollectionSummaryReportRepository
{
    /// <summary>
    /// Reads NorthWest Collection Summary Monthly Claim Volume using <c>dbo.usp_GetNW_CS_MonthlyClaimVolume</c>.
    /// </summary>
    Task<CollectionSummaryMonthlyClaimVolumeResult> GetNorthWestMonthlyClaimVolumeAsync(
        string connectionString,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default);

    /// <summary>
    /// Reads NorthWest Collection Summary Weekly Claim Volume using <c>dbo.usp_GetNW_CS_WeeklyClaimVolume</c>.
    /// </summary>
    Task<CollectionSummaryWeeklyClaimVolumeResult> GetNorthWestWeeklyClaimVolumeAsync(
        string connectionString,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default);

    /// <summary>
    /// Reads Monthly Claim Volume data by calling the supplied stored-procedure name.
    /// All lab-specific SPs share the same output columns:
    /// <c>PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment</c>.
    /// Pass <c>dbo.usp_Get{prefix}_CS_MonthlyClaimVolume</c> as <paramref name="storedProcedureName"/>.
    /// </summary>
    Task<CollectionSummaryMonthlyClaimVolumeResult> GetMonthlyClaimVolumeAsync(
        string connectionString,
        string storedProcedureName,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default);

    /// <summary>
    /// Reads Weekly Claim Volume data by calling the supplied stored-procedure name.
    /// All lab-specific SPs share the same output columns:
    /// <c>PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment</c>.
    /// Pass <c>dbo.usp_Get{prefix}_CS_WeeklyClaimVolume</c> as <paramref name="storedProcedureName"/>.
    /// </summary>
    Task<CollectionSummaryWeeklyClaimVolumeResult> GetWeeklyClaimVolumeAsync(
        string connectionString,
        string storedProcedureName,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default);
}
