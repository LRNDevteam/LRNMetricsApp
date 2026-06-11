using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// CPT Code Search repository.
/// All lab metadata (list, display names, SP names) is read from
/// <c>dbo.LabRegistry</c> on LRNMaster — no config files involved.
/// </summary>
public interface ICptSearchRepository
{
    /// <summary>
    /// Returns all active labs from <c>dbo.LabRegistry</c> on LRNMaster.
    /// Each entry contains the lab name, display label, and the SP to call.
    /// </summary>
    Task<List<CptLabEntry>> GetActiveLabsAsync(
        string connectionString,
        CancellationToken ct = default);

    /// <summary>
    /// Calls the named SP on <paramref name="connectionString"/> (LRNMaster)
    /// and maps all five result sets into a <see cref="LabCptResult"/>.
    /// </summary>
    Task<LabCptResult> SearchAsync(
        string connectionString,
        string sprocName,
        string labName,
        string displayName,
        string cptCode,
        CancellationToken ct = default);
}
