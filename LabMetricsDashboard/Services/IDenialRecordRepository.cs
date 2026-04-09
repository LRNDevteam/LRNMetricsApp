using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

public interface IDenialRecordRepository
{
    Task<IReadOnlyList<LabOption>> GetLabsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialRecord>> GetByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialInsightRecord>> GetInsightsByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsByLabAsync(int labId, int page, int pageSize, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsForExportByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialBreakdownSourceRecord>> GetBreakdownSourceByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<int> GetLineItemCountByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<string>> GetPayerNamesByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<string>> GetPanelNamesByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<DenialFilterAutocompleteOptions> GetFilterAutocompleteOptionsAsync(int labId, CancellationToken cancellationToken = default);
    Task<string?> GetCurrentRunIdAsync(int labId, CancellationToken cancellationToken = default);
    Task<string?> GetLatestExportFilePathForLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<TaskBoardUploadResult> UpdateTaskBoardAsync(int labId, IReadOnlyList<TaskBoardCsvUpdate> updates, CancellationToken cancellationToken = default);
}
