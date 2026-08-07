using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

// Denial Dashboard data access, moved out of LabMetricsDashboard. The web app now calls the
// matching api/denial-dashboard/* endpoints instead of touching SQL directly.
public interface IDenialDashboardRepository
{
    Task<IReadOnlyList<LabOption>> GetLabsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialRecord>> GetByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialInsightRecord>> GetInsightsByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialInsightRecord>> GetInsightTableByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsByLabAsync(int labId, int page, int pageSize, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsForExportByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialBreakdownSourceRecord>> GetBreakdownSourceByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<int> GetLineItemCountByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<string>> GetPayerNamesByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<string>> GetPanelNamesByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<DenialFilterAutocompleteOptions> GetFilterAutocompleteOptionsAsync(int labId, CancellationToken cancellationToken = default);
    Task<string?> GetCurrentRunIdAsync(int labId, CancellationToken cancellationToken = default);
    Task<DenialRunInfo> GetRunInfoAsync(int labId, CancellationToken cancellationToken = default);
    Task<string?> GetLatestExportFilePathForLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<TaskBoardUploadResult> UpdateTaskBoardAsync(int labId, IReadOnlyList<TaskBoardCsvUpdate> updates, CancellationToken cancellationToken = default);
    Task<int> AssignReviewerByInsightAsync(int labId, string denialCode, string payerName, string reviewerUserName, string? runId, CancellationToken cancellationToken = default);
    Task<int> UpdateReviewerTaskAsync(int labId, string taskId, string status, string comments, string reviewerUserName, string? runId, CancellationToken cancellationToken = default);
}
