using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads PayerValidation report rows from the SQL PayerValidationReport table.
/// The actual columns returned are controlled by usp_GetPayerValidationReport �
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
    /// Lightweight fetch for the Forecasting Summary page via
    /// dbo.usp_GetForecastingRecords: only the ~16 columns the page needs,
    /// pre-filtered in SQL to forecast-payable rows. Dramatically faster than
    /// <see cref="GetRecordsAsync"/> for large labs (CERTUS etc.).
    /// </summary>
    Task<List<PredictionRecord>> GetForecastRecordsAsync(
        string  connectionString,
        string? runId = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Returns pre-aggregated Median/Mode weekly summaries via
    /// dbo.usp_GetForecastingSummaryByWeekRange. Returns null when the SP is
    /// missing or cannot parse the run WeekFolder — caller should fall back to
    /// in-memory aggregation.
    /// </summary>
    Task<ForecastingSummaryFromDb?> TryGetForecastingSummaryAsync(
        string  connectionString,
        string? runId = null,
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

    // ?? Aggregated SP methods (SP 6-11) ?????????????????????????????????????

    /// <summary>Returns the 6 summary bucket rows (usp_GetPredictionSummaryBuckets).</summary>
    Task<List<PredictionBucketSpRow>> GetSummaryBucketsAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        string? filterForecastingPayability = null, string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null, string? filterPredictionStatus = null,
        CancellationToken cancellationToken = default);

    /// <summary>Returns payer-level validation rows (usp_GetPredictionValidationByPayer).</summary>
    Task<List<PredictionPayerSpRow>> GetValidationByPayerAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        string? filterForecastingPayability = null, string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null, string? filterPredictionStatus = null,
        CancellationToken cancellationToken = default);

    /// <summary>Returns panel-level validation rows (usp_GetPredictionValidationByPanel).</summary>
    Task<List<PredictionPanelSpRow>> GetValidationByPanelAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default);

    /// <summary>Returns CPT-level validation rows (usp_GetPredictionValidationByCPT).</summary>
    Task<List<PredictionCptSpRow>> GetValidationByCptAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default);

    /// <summary>Returns flat denial breakdown rows (usp_GetPredictionDenialBreakdown).</summary>
    Task<List<DenialBreakdownSpRow>> GetDenialBreakdownAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        string? filterForecastingPayability = null, string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null, string? filterPredictionStatus = null,
        CancellationToken cancellationToken = default);

    /// <summary>Returns flat no-response breakdown rows (usp_GetPredictionNoResponseBreakdown).</summary>
    Task<List<NoResponseBreakdownSpRow>> GetNoResponseBreakdownAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        string? filterForecastingPayability = null, string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null, string? filterPredictionStatus = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Returns the single summary-metrics row containing all bucket counts, all Ratio
    /// percentages, and all Prediction Accuracy percentages
    /// (usp_GetPredictionSummaryMetrics � SP 12).
    /// Returns null when the SP returns no rows (empty dataset).
    /// </summary>
    Task<PredictionSummaryMetricsSpRow?> GetSummaryMetricsAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        string? filterForecastingPayability = null, string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null, string? filterPredictionStatus = null,
        CancellationToken cancellationToken = default);

    /// <summary>Payer x PayStatus drill-down for Section B modal.</summary>
    Task<List<PayerPayStatusSpRow>> GetPayerPayStatusBreakdownAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null,
        string? filterForecastingPayability = null, string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null, string? filterPredictionStatus = null,
        CancellationToken cancellationToken = default);

    /// <summary>Section E — Predicted to Pay Adjusted by payer.</summary>
    Task<List<AdjustedByPayerSpRow>> GetAdjustedByPayerAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        string? filterForecastingPayability = null, string? filterPayStatus = null,
        string? filterForecastingPayabilitySubstatus = null, string? filterPredictionStatus = null,
        CancellationToken cancellationToken = default);

    /// <summary>Distinct filter dropdown values from PayerValidationReport.</summary>
    Task<PredictionFilterOptions> GetFilterOptionsAsync(
        string connectionString, string? runId = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Server-side paged read via dbo.usp_GetPayerValidationReportPaged — filters and
    /// OFFSET/FETCH run in SQL so only one page crosses the network, instead of the
    /// entire PayerValidationReport table. <paramref name="pageSize"/> null/&lt;=0
    /// returns all filtered rows (Excel export).
    /// </summary>
    Task<PagedPredictionRecords> GetRecordsPagedAsync(
        string  connectionString,
        string? runId                                = null,
        string? filterPayerName                      = null,
        string? filterPanelName                      = null,
        string? filterFinalCoverageStatus            = null,
        string? filterCPTCode                        = null,
        string? filterForecastingPayabilitySubstatus = null,
        string? filterPredictionStatus               = null,
        string? filterPayStatus                      = null,
        int     pageNumber                           = 1,
        int?    pageSize                             = 50,
        CancellationToken cancellationToken = default);
}

/// <summary>One page of PayerValidationReport rows plus the counts the pager needs.</summary>
public sealed record PagedPredictionRecords(
    List<PredictionRecord> Rows,
    int TotalFiltered,
    int TotalAll);

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
    string?   ErrorMessage,
    string?   WeekFolder     = null,
    string?   SourceFileName = null)
{
    /// <summary>True when the database is set up AND has at least one row.</summary>
    public bool IsReady => TableExists && ProcedureExists && RowCount > 0 && ErrorMessage is null;
}
