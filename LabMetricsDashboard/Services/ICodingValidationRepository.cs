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


