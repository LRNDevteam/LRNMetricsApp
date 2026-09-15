using LRN.CpuMonitor.Models;

namespace LRN.CpuMonitor.Services;

public interface ISqlActivityProbe
{
    /// <summary>
    /// Reads the in-flight requests burning the most CPU, so a <c>sqlservr.exe</c>
    /// breach can be attributed to a client application and query. Returns an empty
    /// list when no connection string is configured or the server cannot be reached.
    /// </summary>
    Task<IReadOnlyList<SqlRequestActivity>> GetTopCpuRequestsAsync(
        string connectionString,
        int topN,
        CancellationToken cancellationToken);
}
