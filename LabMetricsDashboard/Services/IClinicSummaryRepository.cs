using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Clinic Summary aggregation from the <c>dbo.ClaimLevelData</c> table.
/// </summary>
public interface IClinicSummaryRepository
{
    /// <summary>
    /// Returns per-clinic aggregated rows from <c>dbo.ClaimLevelData</c>,
    /// optionally filtered by clinic names, payer names, and/or panel names (multi-select).
    /// Also returns distinct filter option lists (clinic, payer, panel) before filtering.
    /// </summary>
    Task<ClinicSummaryResult> GetClinicSummaryAsync(
        string connectionString,
        string labName,
        List<string>? filterClinicNames = null,
        List<string>? filterSalesRepNames = null,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default);
}

/// <summary>Result container for clinic summary query including filter option lists.</summary>
public sealed record ClinicSummaryResult(
    List<ClinicSummaryRow> Rows,
    List<string> ClinicNames,
    List<string> SalesRepNames,
    List<string> PayerNames,
    List<string> PanelNames,
    List<TopCollectedItem> TopCollectedClinics,
    List<TopCollectedItem> TopCollectedSalesReps,
    List<TopCollectedItem> TopCollectedPayers,
    List<TopCollectedItem> TopCollectedPanels,
    List<TopDeniedItem> TopDeniedClinics,
    List<TopDeniedItem> TopDeniedSalesReps,
    List<TopDeniedItem> TopDeniedPayers,
    List<TopDeniedItem> TopDeniedPanels);
