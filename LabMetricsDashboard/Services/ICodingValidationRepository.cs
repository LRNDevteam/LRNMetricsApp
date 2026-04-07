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
}


