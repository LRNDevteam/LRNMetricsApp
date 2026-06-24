using LabMetricsDashboard.Models.DenialWorkflow;

namespace LabMetricsDashboard.Services.DenialWorkflow;

public interface IDenialWorkflowRepository
{
	Task<DenialWorkflowCounts> GetSummaryAsync(
		int labId,
		string role,
		string userName,
		CancellationToken cancellationToken = default);

	Task<IReadOnlyList<WorkflowTaskRow>> GetTasksAsync(
		int labId,
		string role,
		string userName,
		int page = 1,
		int pageSize = 100,
		CancellationToken cancellationToken = default);

	Task<IReadOnlyList<VerificationTaskRow>> GetVerificationAsync(
		int labId,
		string role,
		string userName,
		int page = 1,
		int pageSize = 100,
		CancellationToken cancellationToken = default);

	Task<DenialWorkflowResult> AssignTasksAsync(
		AssignInsightRequest request,
		CancellationToken cancellationToken = default);

	Task<DenialWorkflowResult> UpdateTaskAsync(
		UpdateTaskRequest request,
		CancellationToken cancellationToken = default);

	Task<DenialWorkflowResult> DecideVerificationAsync(
		VerificationDecisionRequest request,
		CancellationToken cancellationToken = default);
}