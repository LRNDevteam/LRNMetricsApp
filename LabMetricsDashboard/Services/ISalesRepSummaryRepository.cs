using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Sales Rep Summary aggregation from the <c>dbo.ClaimLevelData</c> table.
/// </summary>
public interface ISalesRepSummaryRepository
{
    /// <summary>
    /// Returns per-sales-rep aggregated rows from <c>dbo.ClaimLevelData</c>,
    /// optionally filtered by sales rep names, payer names, and/or panel names (multi-select).
    /// Also returns distinct filter option lists.
    /// </summary>
    Task<SalesRepSummaryResult> GetSalesRepSummaryAsync(
        string connectionString,
        string labName,
        List<string>? filterSalesRepNames = null,
        List<string>? filterClinicNames = null,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default);
}

/// <summary>Result container for sales rep summary query including filter option lists.</summary>
public sealed record SalesRepSummaryResult(
    List<SalesRepSummaryRow> Rows,
    List<string> SalesRepNames,
    List<string> ClinicNames,
    List<string> PayerNames,
    List<string> PanelNames);
