using LRN.ProductionReports.Models;
using SharedCodingResult = LRN.ProductionReports.Services.CodingResult;
using SharedCptBreakdownResult = LRN.ProductionReports.Services.CptBreakdownResult;
using SharedPayerBreakdownResult = LRN.ProductionReports.Services.PayerBreakdownResult;
using SharedPayerPanelResult = LRN.ProductionReports.Services.PayerPanelResult;
using SharedProductionReportResult = LRN.ProductionReports.Services.ProductionReportResult;
using SharedRawDataSegment = LRN.ProductionReports.Services.RawDataSegment;
using SharedUnbilledAgingResult = LRN.ProductionReports.Services.UnbilledAgingResult;
using SharedWeeklyClaimVolumeResult = LRN.ProductionReports.Services.WeeklyClaimVolumeResult;


namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads NorthWest production report data from the pre-aggregated SP output tables
/// (NW_MonthlyBilledProductionSummary, NW_WeeklyBilledProductionSummary,
/// NW_PayerBreakdown, NW_PayerByPanel, NW_UnbilledAging, NW_CPTBreakdown,
/// NW_CodingPanelSummary, NW_CodingCPTDetail).
/// Used by the "Production Summary Report" page.
/// When all filter parameters are null the SPs serve the pre-aggregated snapshot tables.
/// When any filter is supplied the SPs aggregate live from dbo.ClaimLevelData /
/// dbo.LineLevelData using NorthWest filter semantics.
/// </summary>
public interface INorthWestProductionSummaryRepository
{
    /// <summary>
    /// Returns distinct PayerName_Raw and PanelType values for the filter dropdowns.
    /// </summary>
    Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default);

    /// <summary>Calls usp_GetNW_MonthlyBilledProductionSummary — monthly panel + top-3 payer pivot.</summary>
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

    /// <summary>
    /// Returns <c>dbo.ClaimLevelData</c> Excel rows already split into worksheet segments using
    /// NorthWest filter semantics.
    /// </summary>
    Task<List<SharedRawDataSegment>> GetClaimLevelDataExportSegmentsAsync(
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

    /// <summary>Calls usp_GetNW_WeeklyBilledProductionSummary — last-4-week panel + top-3 payer pivot (Thu–Wed).</summary>
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

    /// <summary>Calls usp_GetNW_CodingBreakdown — coding panel + CPT drill-down (2 result sets).</summary>
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

    /// <summary>Calls usp_GetNW_PayerBreakdown — payer × month pivot.</summary>
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

    /// <summary>Calls usp_GetNW_PayerByPanel — payer × panel pivot.</summary>
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

    /// <summary>Calls usp_GetNW_UnbilledAging — payer × aging bucket pivot.</summary>
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

    /// <summary>Calls usp_GetNW_CPTBreakdown — payer × month line-count + charge pivot.</summary>
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

    /// <summary>
    /// Returns all <c>dbo.ClaimLevelData</c> rows for Excel export using NorthWest filter semantics
    /// (excludes unbilled ClaimStatus values; filters on <c>PanelType</c> and <c>PayerName_Raw</c>).
    /// </summary>
    Task<List<Dictionary<string, object?>>> GetClaimLevelDataExportAsync(
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
    /// Returns all <c>dbo.LineLevelData</c> rows for Excel export using NorthWest filter semantics
    /// (joins to <c>ClaimLevelData</c> to apply the same <c>ClaimStatus</c> / <c>PanelType</c> exclusions).
    /// </summary>
    Task<List<Dictionary<string, object?>>> GetLineLevelDataExportAsync(
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
    /// Returns <c>dbo.LineLevelData</c> Excel rows already split into worksheet segments using
    /// NorthWest filter semantics.
    /// </summary>
    Task<List<SharedRawDataSegment>> GetLineLevelDataExportSegmentsAsync(
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


