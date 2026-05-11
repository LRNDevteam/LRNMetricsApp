using System.Text.Json;
using LRN.ReportsApi.Models;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public interface IDenialWorkflowService
{
    Task<DenialWorkflowImportResult> ImportAsync(DenialTaskImportRequest request, CancellationToken ct);
    Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsAsync(CancellationToken ct);
    Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct);
    Task<DenialWorkflowDashboardSummary> GetDashboardSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<DenialWorkflowFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<ReviewerOption>> GetReviewerOptionsAsync(int labId, CancellationToken ct);
    Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct);
    Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<DenialWorkflowInsightRow>> GetInsightsAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct);
    Task<int> UpdateTaskAsync(UpdateTaskRequest request, CancellationToken ct);
    Task<int> DecideVerificationAsync(VerificationDecisionRequest request, CancellationToken ct);
}

public sealed class DenialWorkflowService : IDenialWorkflowService
{
    private readonly IDenialWorkflowRepository _repo;
    private readonly DenialWorkflowOptions _options;
    private readonly HashSet<string> _closedStatuses;

    public DenialWorkflowService(IDenialWorkflowRepository repo, IOptions<DenialWorkflowOptions> options)
    {
        _repo = repo;
        _options = options.Value;
        _closedStatuses = new HashSet<string>(_options.ClosedStatuses ?? ["Closed", "Completed"], StringComparer.OrdinalIgnoreCase);
    }

    public async Task<DenialWorkflowImportResult> ImportAsync(DenialTaskImportRequest request, CancellationToken ct)
    {
        var result = new DenialWorkflowImportResult { Imported = request.Tasks.Count };
        var incoming = request.Tasks
            .Where(x => !string.IsNullOrWhiteSpace(x.UniqueTrackId))
            .GroupBy(x => x.UniqueTrackId.Trim(), StringComparer.OrdinalIgnoreCase)
            .Select(g => g.First())
            .ToList();

        var incomingKeys = incoming.Select(x => x.UniqueTrackId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var active = await _repo.GetActiveTasksAsync(request.LabId, ct);
        var activeByUid = active.ToDictionary(x => x.UniqueTrackId, StringComparer.OrdinalIgnoreCase);
        var historyReturned = await _repo.GetHistoryTasksByUidAsync(request.LabId, incomingKeys, ct);
        var historyByUid = historyReturned.ToDictionary(x => x.UniqueTrackId, StringComparer.OrdinalIgnoreCase);

        foreach (var row in incoming)
        {
            if (activeByUid.TryGetValue(row.UniqueTrackId, out var existing))
            {
                await _repo.UpsertActiveTaskAsync(row, existing, request.LabId, request.LabName, request.RunId, existing.TaskId, ct);
                await _repo.InsertHistoryAsync(existing.TaskId, row.UniqueTrackId, request.LabId, request.RunId, "ImportUpdated", existing.Status, existing.Status, existing.AssignedTo, existing.AssignedTo, "Existing UID found in latest import; task state preserved.", "DenialWorker", JsonSerializer.Serialize(row), ct);
                result.Updated++;
            }
            else if (historyByUid.TryGetValue(row.UniqueTrackId, out var oldClosed))
            {
                row.DateOpened ??= DateTime.Today;
                row.DueDate ??= row.SlaDays > 0 ? row.DateOpened.Value.AddDays(row.SlaDays.Value) : null;
                var taskId = string.IsNullOrWhiteSpace(oldClosed.TaskId) ? NewTaskId() : oldClosed.TaskId;
                await _repo.UpsertActiveTaskAsync(row, null, request.LabId, request.LabName, request.RunId, taskId, ct);
                var activeRow = new WorkflowTaskRow
                {
                    TaskId = taskId,
                    UniqueTrackId = row.UniqueTrackId,
                    ClaimId = row.ClaimId,
                    CptCode = row.CptCode,
                    DenialCode = row.DenialCode,
                    Status = "Verification Pending",
                    AssignedTo = oldClosed.AssignedTo,
                    LabId = request.LabId,
                    LabName = request.LabName,
                    RunId = request.RunId,
                    ReviewerComments = oldClosed.ReviewerComments
                };
                await _repo.MoveActiveToVerificationAsync(activeRow, request.RunId, "Previously closed UID appeared again in a new import.", ct);
                result.ReopenedToVerification++;
            }
            else
            {
                row.DateOpened ??= DateTime.Today;
                row.DueDate ??= row.SlaDays > 0 ? row.DateOpened.Value.AddDays(row.SlaDays.Value) : null;
                var taskId = NewTaskId();
                await _repo.UpsertActiveTaskAsync(row, null, request.LabId, request.LabName, request.RunId, taskId, ct);
                await _repo.InsertHistoryAsync(taskId, row.UniqueTrackId, request.LabId, request.RunId, "Created", "", "New", "", "", "New UID created from denial import.", "DenialWorker", JsonSerializer.Serialize(row), ct);
                result.Created++;
            }
        }

        foreach (var old in active.Where(x => !incomingKeys.Contains(x.UniqueTrackId)))
        {
            if (IsClosed(old.Status))
            {
                await _repo.MoveActiveToHistoryAsync(old, "ClosedRemovedFromActive", "DenialWorker", "Closed task was not found in latest import; moved to history.", ct);
                result.MovedToHistory++;
            }
            else
            {
                await _repo.MoveActiveToVerificationAsync(old, request.RunId, "Active task was not found in latest import and needs user verification.", ct);
                result.MovedToVerification++;
            }
        }

        return result;
    }

    public Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsAsync(CancellationToken ct) => _repo.GetLabsAsync(ct);
    public Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct) => _repo.GetLabsForUserAsync(userName, ct);
    public Task<DenialWorkflowDashboardSummary> GetDashboardSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct) => _repo.GetDashboardSummaryAsync(filter, ct);
    public Task<DenialWorkflowFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct) => _repo.GetFilterOptionsAsync(labId, ct);
    public Task<IReadOnlyList<ReviewerOption>> GetReviewerOptionsAsync(int labId, CancellationToken ct) => _repo.GetReviewerOptionsAsync(labId, ct);

    public Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct) => _repo.GetSummaryAsync(labId, role, userName, ct);
    public Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct) => _repo.GetReviewerSummaryAsync(filter, ct);
    public Task<PagedResult<DenialWorkflowInsightRow>> GetInsightsAsync(DenialWorkflowFilter filter, CancellationToken ct) => _repo.GetInsightsAsync(filter, ct);
    public Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct) => _repo.GetTasksAsync(filter, ct);
    public Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(DenialWorkflowFilter filter, CancellationToken ct) => _repo.GetVerificationAsync(filter, ct);
    public Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct) => _repo.AssignByInsightAsync(request, ct);
    public Task<int> UpdateTaskAsync(UpdateTaskRequest request, CancellationToken ct) => _repo.UpdateTaskAsync(request, IsClosed(request.Status), request.Status.Equals("Duplicate", StringComparison.OrdinalIgnoreCase), ct);
    public Task<int> DecideVerificationAsync(VerificationDecisionRequest request, CancellationToken ct) => _repo.DecideVerificationAsync(request, !request.IsValidDenial || IsClosed(request.Status), ct);

    private bool IsClosed(string? status) => !string.IsNullOrWhiteSpace(status) && _closedStatuses.Contains(status.Trim());
    private static bool IsReviewerOnly(string role) => role.Contains("Reviewer", StringComparison.OrdinalIgnoreCase) && !role.Contains("Manager", StringComparison.OrdinalIgnoreCase) && !role.Contains("Admin", StringComparison.OrdinalIgnoreCase);
    private static string NewTaskId() => $"TSK-{DateTime.UtcNow:yyyyMMddHHmmssfff}-{Random.Shared.Next(100, 999)}";
}
