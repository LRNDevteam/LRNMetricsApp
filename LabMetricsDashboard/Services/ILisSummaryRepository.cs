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

public interface ILisSummaryRepository
{
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
