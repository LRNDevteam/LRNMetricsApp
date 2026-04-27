using LabMetricsDashboard.Models;

using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Dashboard Index aggregation data from the database.
/// Replaces the CSV-sourced data for the main Dashboard page.
/// </summary>
public interface IDashboardRepository
{
    /// <summary>
    /// Returns all aggregated KPIs, breakdowns, insights, and filter option lists
    /// from <c>dbo.ClaimLevelData</c> and <c>dbo.LineLevelData</c>.
    /// </summary>
    Task<DashboardResult> GetDashboardAsync(
        string connectionString,
        string labName,
        string? filterPayerName = null,
        string? filterPayerType = null,
        string? filterPanelName = null,
        string? filterClinicName = null,
        string? filterReferringProvider = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default);

    /// <summary>
    /// Returns Dashboard data from pre-aggregated snapshot tables populated by
    /// <c>dbo.usp_RefreshDashboard</c>. No filters are applied — the result reflects
    /// the full dataset at the time the snapshot was last refreshed.
    /// Called when <c>UseDBDashboard = true</c> and no active filters are present.
    /// </summary>
    Task<DashboardResult> GetDashboardFromAggregatesAsync(
        string connectionString,
        CancellationToken ct = default);
}

/// <summary>Result container for the Dashboard Index page.</summary>
public sealed record DashboardResult(
    // Filter option lists (unfiltered, lab-scoped)
    List<string> PayerNames,
    List<string> PayerTypes,
    List<string> PanelNames,
    List<string> ClinicNames,
    List<string> ReferringProviders,

    // Claim-level KPIs
    int TotalClaims,
    decimal TotalCharges,
    decimal TotalPayments,
    decimal TotalBalance,

    // Rate numerators
    decimal CollectionNumerator,
    decimal DenialNumerator,
    decimal AdjustmentNumerator,
    decimal OutstandingNumerator,

    // Claim status breakdown
    List<ClaimStatusRow> ClaimStatusRows,

    // Payer type payments
    Dictionary<string, decimal> PayerTypePayments,

    // Insight breakdowns (top 15 by charges)
    List<InsightRow> PayerLevelInsights,
    List<InsightRow> PanelLevelInsights,
    List<InsightRow> ClinicLevelInsights,
    List<InsightRow> ReferringPhysicianInsights,

    // Monthly trends
    List<(string Month, int Count)> DOSMonthly,
    List<(string Month, int Count)> FirstBillMonthly,

    // Average Allowed by Panel x Month
    List<string> AvgAllowedMonths,
    List<PanelMonthRow> AvgAllowedByPanelMonth,

    // Line-level KPIs
    int TotalLines,
    decimal LineTotalCharges,
    decimal LineTotalPayments,
    decimal LineTotalBalance,

    // Top CPT by charges
    Dictionary<string, decimal> TopCPTCharges,

    // Pay status breakdown (line-level)
    Dictionary<string, int> PayStatusBreakdown,

    // Top CPT detail rows
    List<CptDetailRow> TopCptDetail,

    /// <summary>The most recently ingested RunId in ClaimLevelData, or null when no data exists.</summary>
    string? LatestRunId);
