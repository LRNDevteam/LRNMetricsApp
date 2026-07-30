using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Loads the latest billed-week / RunId / inserted-date banner from
/// <c>dbo.LineClaimFileLogs</c> (best-effort; missing table → empty).
/// </summary>
public interface IAnalysisRangeService
{
    Task<AnalysisRangeInfo> GetAsync(string connectionString, CancellationToken ct = default);
}
