using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

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
}
