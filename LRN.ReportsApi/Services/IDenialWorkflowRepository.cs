using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

public interface IDenialWorkflowRepository
{
    Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsAsync(CancellationToken ct);
    Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct);
    Task<DenialWorkflowDashboardSummary> GetDashboardSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<DenialWorkflowFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<ReviewerOption>> GetReviewerOptionsAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<WorkflowTaskRow>> GetActiveTasksAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<WorkflowTaskRow>> GetHistoryTasksByUidAsync(int labId, IEnumerable<string> uniqueTrackIds, CancellationToken ct);
    Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct);
    Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<DenialWorkflowInsightRow>> GetInsightsAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task UpsertActiveTaskAsync(DenialTaskImportRow row, WorkflowTaskRow? existing, int labId, string labName, string runId, string taskId, CancellationToken ct);
    Task MoveActiveToVerificationAsync(WorkflowTaskRow task, string currentRunId, string reason, CancellationToken ct);
    Task MoveActiveToHistoryAsync(WorkflowTaskRow task, string actionType, string actionBy, string comments, CancellationToken ct);
    Task InsertHistoryAsync(string taskId, string uniqueTrackId, int labId, string runId, string actionType, string oldStatus, string newStatus, string oldAssignedTo, string newAssignedTo, string comments, string actionBy, string snapshotJson, CancellationToken ct);
    Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct);
    Task<int> UpdateTaskAsync(UpdateTaskRequest request, bool isClosed, bool isDuplicate, CancellationToken ct);
    Task<int> DecideVerificationAsync(VerificationDecisionRequest request, bool isClosed, CancellationToken ct);
}
