using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

public interface ILisSummaryRepository
{
    Task<LisSummaryResult> GetLisSummaryAsync(
        string connectionString,
        string labName,
        DateOnly? collectedFrom = null,
        DateOnly? collectedTo = null,
        CancellationToken ct = default);
}
