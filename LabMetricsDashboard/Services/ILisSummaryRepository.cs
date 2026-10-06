using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Everything the background worker needs to stream the whole LIMS Master line-level
/// table for one filter set: the un-paged SELECT (same WHERE/ORDER BY as the page's
/// line-data tab), its parameters, the resolved column list and the total row count
/// (drives the report's progress %).
/// <para>
/// <see cref="AdditionalFieldKeys"/> are the JSON property names discovered in
/// dbo.LIMSMaster.AdditionalFields; each one is already selected as its own column in
/// <see cref="DataSql"/> via JSON_VALUE, so the export needs no per-row JSON parsing.
/// </para>
/// </summary>
public sealed record LisLineExportPlan(
    string DataSql,
    IReadOnlyList<SqlParameter> Parameters,
    IReadOnlyList<LisLineDataColumn> Columns,
    IReadOnlyList<string> AdditionalFieldKeys,
    int TotalRows);

/// <summary>Outcome of one LIS Summary aggregate refresh (see <see cref="LisSummaryAggregateLabs"/>).</summary>
public sealed record LisSummaryAggregateRefreshResult(
    bool Refreshed,
    string Message,
    int SummaryRows,
    int KeyMetricRows,
    int FilterOptionRows,
    string SourceFileName,
    long ElapsedMs);

public interface ILisSummaryRepository
{
	/// <summary>
	/// Rebuilds the lab's LIS Summary aggregate tables from dbo.LIMSMaster with the same
	/// grouping logic the page uses live. With <paramref name="onlyIfLimsChanged"/> the
	/// rebuild is skipped when LIMSMaster's row count / latest CreatedOn / latest RunId
	/// match the last refresh. Labs without aggregate tables return Refreshed = false.
	/// </summary>
	Task<LisSummaryAggregateRefreshResult> RefreshSummaryAggregateAsync(
		string connectionString,
		string labName,
		int? labId = null,
		bool onlyIfLimsChanged = true,
		CancellationToken ct = default);

	Task<LisSummaryResult> GetLisSummaryAsync(
		string connectionString,
		string labName,
		int? labId = null,
		string dateType = "Collected",
		DateOnly? dateFrom = null,
		DateOnly? dateTo = null,
		string? panel = null,
		string? clinic = null,
		string? refPhy = null,
		string? salesRep = null,
		string? collector = null,
		CancellationToken ct = default,
		bool includeKeyMetrics = false);

	/// <summary>
	/// Recent 4 months average Time to Result / Time to Bill by Date of Collection.
	/// Loaded separately from the main pivot so the summary page is not blocked by it.
	/// </summary>
	Task<LisKeyMetricsBlock?> GetKeyMetricsAsync(
		string connectionString,
		string labName,
		int? labId = null,
		DateOnly? dateFrom = null,
		DateOnly? dateTo = null,
		string? panel = null,
		string? clinic = null,
		string? refPhy = null,
		string? salesRep = null,
		string? collector = null,
		CancellationToken ct = default);

    Task<LisSummaryFilterOptions> GetFilterOptionsAsync(
        string connectionString,
        string labName,
        CancellationToken ct = default);

    Task<LisLineDataResult> GetLisLineDataAsync(
        string connectionString,
        string labName,
        string dateType = "Collected",
        DateOnly? dateFrom = null,
        DateOnly? dateTo = null,
        string? panel = null,
        string? clinic = null,
        string? refPhy = null,
        string? salesRep = null,
        string? collector = null,
        int pageNumber = 1,
        int pageSize = 100,
        CancellationToken ct = default);

    /// <summary>
    /// Builds the un-paged line-level export query for LRN.ReportWorker. Unlike
    /// <see cref="GetLisLineDataAsync"/> (which samples for speed on every page render),
    /// AdditionalFields keys are discovered across the FULL filtered set so no extra
    /// column is missed from the downloaded workbook.
    /// </summary>
    Task<LisLineExportPlan> BuildLineDataExportPlanAsync(
        string connectionString,
        string labName,
        string dateType = "Collected",
        DateOnly? dateFrom = null,
        DateOnly? dateTo = null,
        string? panel = null,
        string? clinic = null,
        string? refPhy = null,
        string? salesRep = null,
        string? collector = null,
        CancellationToken ct = default);
}
