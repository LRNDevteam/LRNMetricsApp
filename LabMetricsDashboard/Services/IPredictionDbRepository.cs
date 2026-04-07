using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads PayerValidation report rows from the SQL PayerValidationReport table.
/// The actual columns returned are controlled by usp_GetPayerValidationReport —
/// add or remove columns there without changing this interface.
/// </summary>
public interface IPredictionDbRepository
{
    /// <summary>
    /// Returns all rows for the latest (or specified) run from the connected database,
    /// with optional dimension filters passed straight through to the SP.
    /// Lab scoping is handled by the database the connection string points to.
    /// Returns an empty list when <paramref name="connectionString"/> is blank.
    /// </summary>
    Task<List<PredictionRecord>> GetRecordsAsync(
        string  connectionString,
        string? runId                    = null,
        string? filterPayerName          = null,
        string? filterPayerType          = null,
        string? filterPanelName          = null,
        string? filterFinalCoverageStatus = null,
        string? filterPayability         = null,
        string? filterCPTCode            = null,
        CancellationToken cancellationToken = default);
}
