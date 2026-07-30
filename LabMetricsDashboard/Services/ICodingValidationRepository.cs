using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

public interface ICodingValidationRepository
{
    Task<List<CodingInsightRow>>             GetYtdInsightsAsync(string connectionString, string labName, CancellationToken ct = default);
    Task<List<CodingSummaryRow>>             GetYtdSummaryAsync(string connectionString, string labName, CancellationToken ct = default);
    Task<List<CodingWtdInsightRow>>          GetWtdInsightsAsync(string connectionString, string labName, CancellationToken ct = default);
    Task<List<CodingWtdSummaryRow>>          GetWtdSummaryAsync(string connectionString, string labName, CancellationToken ct = default);
    Task<List<CodingFinancialSummaryRow>>    GetFinancialSummaryAsync(string connectionString, CancellationToken ct = default);
    Task<List<CodingValidationDetailRow>>    GetValidationDetailRowsAsync(string connectionString, CancellationToken ct = default);

    // >>> CVDETAIL-ALL (2026-07-27): uncapped detail rows (all weeks, no TOP) for the Excel export.
    //     REVERT: delete this method.
    Task<List<CodingValidationDetailRow>>    GetValidationDetailExportRowsAsync(string connectionString, CancellationToken ct = default);
    // <<< END CVDETAIL-ALL

    // >>> CVDETAIL-PAGE (2026-07-28): one filtered page for the Validation Detail tab.
    //     REVERT: delete this method.
    Task<CodingValidationDetailPage>         GetValidationDetailPagedAsync(
        string connectionString, int page, int pageSize,
        string? panelName, string? status, string? search, CancellationToken ct = default);
    // <<< END CVDETAIL-PAGE

    // >>> CVUI-SRC CHANGE (2026-07-27): source-data provenance for the Coding Summary header.
    //     REVERT: delete this method.
    /// <summary>Returns the processed source files (RunId + inserted datetime) feeding CodingValidation, newest first.</summary>
    Task<List<CodingSourceFileRow>>          GetSourceFilesAsync(string connectionString, string labName, CancellationToken ct = default);
    // <<< END CVUI-SRC CHANGE

    /// <summary>
    /// Returns Lost Revenue / Revenue at Risk calculation detail for a Year+Panel,
    /// Week+Panel, or Week (financial) scope, including CPT group rollups and claim samples.
    /// </summary>
    Task<CodingCalculationDetail> GetCalculationDetailAsync(
        string connectionString,
        string labName,
        string scope,
        int? year,
        string? weekFolder,
        string? panelName,
        string? missingCpts,
        string? additionalCpts,
        CancellationToken ct = default);
}


