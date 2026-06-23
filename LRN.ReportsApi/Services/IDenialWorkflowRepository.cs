using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

public interface IDenialWorkflowRepository
{
    Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsAsync(CancellationToken ct);
    Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct);
    Task<DenialWorkflowRunReference?> GetLastRunReferenceAsync(int labId, CancellationToken ct);
    Task<DenialWorkflowDashboardSummary> GetDashboardSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<AgingDashboardSummary> GetAgingDashboardAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<DenialWorkflowFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<ReviewerOption>> GetReviewerOptionsAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<WorkflowTaskRow>> GetActiveTasksAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<WorkflowTaskRow>> GetHistoryTasksByUidAsync(int labId, IEnumerable<string> uniqueTrackIds, CancellationToken ct);
    Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct);
    Task<ClaimSubMenuCounts> GetClaimSubMenuCountsAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<DenialWorkflowInsightRow>> GetInsightsAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<ClaimLevelRow>> GetClaimsAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<int> WriteClaimsExportAsync(DenialWorkflowFilter filter, Stream output, CancellationToken ct);
    Task<IReadOnlyList<WorkflowTaskRow>> GetTasksByClaimAsync(int labId, string claimId, CancellationToken ct);
    Task<ClaimAssignmentResult> AssignClaimsAsync(AssignClaimRequest request, CancellationToken ct);
    Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task UpsertActiveTaskAsync(DenialTaskImportRow row, WorkflowTaskRow? existing, int labId, string labName, string runId, string taskId, CancellationToken ct);
    Task MoveActiveToVerificationAsync(WorkflowTaskRow task, string currentRunId, string reason, CancellationToken ct);
    Task MoveActiveToHistoryAsync(WorkflowTaskRow task, string actionType, string actionBy, string comments, CancellationToken ct);
    Task InsertHistoryAsync(string taskId, string uniqueTrackId, int labId, string runId, string actionType, string oldStatus, string newStatus, string oldAssignedTo, string newAssignedTo, string comments, string actionBy, string snapshotJson, CancellationToken ct);
    Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct);
    Task<int> UpdateTaskAsync(UpdateTaskRequest request, bool isClosed, bool isDuplicate, CancellationToken ct);
    Task<int> DecideVerificationAsync(VerificationDecisionRequest request, bool isClosed, CancellationToken ct);
    Task EnsureClaimSupportTablesAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<DenialNoteRow>> GetNotesAsync(int labId, string claimId, string? taskId, string? cptCode, string noteLevel, CancellationToken ct);
    Task<DenialNoteRow> SaveNoteAsync(SaveDenialNoteRequest request, CancellationToken ct);
    Task<IReadOnlyList<ClaimDocumentRow>> GetClaimDocumentsAsync(int labId, string claimId, CancellationToken ct);
    Task<ClaimDocumentRow?> GetClaimDocumentAsync(int labId, long documentId, CancellationToken ct);
    Task<ClaimDocumentRow> SaveClaimDocumentAsync(ClaimDocumentRow row, CancellationToken ct);
    Task<bool> CanDeleteClaimDocumentAsync(int labId, string claimId, CancellationToken ct);
    Task<int> DeleteClaimDocumentAsync(int labId, long documentId, CancellationToken ct);
    Task<IReadOnlyList<DenialClaimHistoryRow>> GetClaimHistoryAsync(int labId, string claimId, string? taskId, string? cptCode, string historyLevel, CancellationToken ct);
    Task<IReadOnlyList<DenialEscalationRow>> GetEscalationsAsync(int labId, string claimId, string? taskId, string? cptCode, string escalationLevel, CancellationToken ct);
    Task<PagedResult<DenialEscalationQueueRow>> GetEscalationQueueAsync(DenialWorkflowFilter filter, string escalationLevel, CancellationToken ct);
    Task<int> ResolveEscalationAsync(ResolveDenialEscalationRequest request, CancellationToken ct);
    Task<DenialEscalationRow> SaveEscalationAsync(SaveDenialEscalationRequest request, CancellationToken ct);
    Task<int> UpdateEscalationAsync(UpdateDenialEscalationRequest request, CancellationToken ct);
}
