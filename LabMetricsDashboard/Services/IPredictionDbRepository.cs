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

    /// <summary>
    /// Probes the target database for Prediction-Analysis readiness. Returns a
    /// short diagnostic record describing why the report is empty (table missing,
    /// SP missing, no rows, schema mismatch, etc.) so the controller can surface
    /// an actionable message to the operator instead of an empty page.
    /// </summary>
    Task<PredictionDbDiagnostic> ProbeAsync(
        string connectionString,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Lightweight diagnostic returned by <see cref="IPredictionDbRepository.ProbeAsync"/>.
/// Used by the Prediction page to explain why the dataset is empty.
/// </summary>
public sealed record PredictionDbDiagnostic(
    bool      TableExists,
    bool      ProcedureExists,
    long      RowCount,
    string?   LatestRunId,
    DateTime? LatestRunInsertedAt,
    string?   ErrorMessage)
{
    /// <summary>True when the database is set up AND has at least one row.</summary>
    public bool IsReady => TableExists && ProcedureExists && RowCount > 0 && ErrorMessage is null;
}
