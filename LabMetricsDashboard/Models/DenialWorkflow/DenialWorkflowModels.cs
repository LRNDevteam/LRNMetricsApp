using System.Text.Json.Serialization;

namespace LabMetricsDashboard.Models.DenialWorkflow;

public class PagedResult<T>
{
    public List<T> Items { get; set; } = new();
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 100;
    public int TotalRecords { get; set; }
    public int TotalCount { get => TotalRecords; set => TotalRecords = value; }
    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling((double)TotalRecords / PageSize);

	public string ErrorMessage { get; internal set; }
}

public class DenialWorkflowFilter
{
    public int LabId { get; set; }
    public string? Role { get; set; }
    public string? UserName { get; set; }
    public string? Status { get; set; }
    public string? Reviewer { get; set; }
    public string? AssignedTo { get; set; }
    public string? DenialCode { get; set; }
    public string? PayerName { get; set; }
    public string? SearchText { get; set; }
    public string? RunId { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 100;
}

public class DenialWorkflowSummary
{
    public int Assigned { get; set; }
    public int Pending { get; set; }
    public int Completed { get; set; }
    public int VerificationPending { get; set; }
    public int Unassigned { get; set; }
}

public class DenialWorkflowCounts : DenialWorkflowSummary { }

public class ReviewerWorkflowSummaryRow
{
    public string? ReviewerName { get; set; }
    public int TotalAssigned { get; set; }
    public int Closed { get; set; }
    public int Pending { get; set; }
}

public class DenialWorkflowResult
{
    public bool Success { get; set; }
    public string? Message { get; set; }
    public int RowsAffected { get; set; }
}

public class WorkflowTaskRow
{
    public string? TaskID { get; set; }
    public string? ClaimID { get; set; }
    public string? CPTCode { get; set; }

    [JsonIgnore] public string? TaskId { get => TaskID; set => TaskID = value; }
    [JsonIgnore] public string? ClaimId { get => ClaimID; set => ClaimID = value; }
    [JsonIgnore] public string? CptCode { get => CPTCode; set => CPTCode = value; }

    public string? PatientId { get; set; }
    public string? UniqueTrackId { get; set; }
    public string? DenialCode { get; set; }
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? ActionCode { get; set; }
    public string? RecommendedAction { get; set; }
    public string? Task { get; set; }
    public string? ActionCategory { get; set; }
    public string? Priority { get; set; }
    public decimal InsuranceBalance { get; set; }
    public string? Status { get; set; }
    public string? SLAStatus { get; set; }
    [JsonIgnore] public string? SlaStatus { get => SLAStatus; set => SLAStatus = value; }
    public string? AssignedTo { get; set; }
    public string? PayerName { get; set; }
    public string? PayerNameNormalized { get; set; }
    public string? PayerType { get; set; }
    public string? ClinicName { get; set; }
    public string? SalesRepname { get; set; }
    public string? ReferringProvider { get; set; }
    public string? PanelName { get; set; }
    public DateTime? DateOfService { get; set; }
    public string? LabName { get; set; }
    public int LabId { get; set; }
    public string? RunId { get; set; }
    public string? ReviewerComments { get; set; }
    public string? ReviewerUpdatedBy { get; set; }
    public DateTime? ReviewerUpdatedOn { get; set; }
    public DateTime? DateOpened { get; set; }
    public DateTime? DueDate { get; set; }
    public DateTime? DateCompleted { get; set; }
    public int? DaysRemaining { get; set; }
}

public class VerificationTaskRow : WorkflowTaskRow
{
    public long VerificationId { get; set; }
    public string? VerificationStatus { get; set; }
    public string? VerificationComments { get; set; }
    public string? OriginalRunId { get; set; }
    public string? MissingDetectedRunId { get; set; }
    public DateTime? MovedOn { get; set; }
    public string? VerifiedBy { get; set; }
    public DateTime? VerifiedOn { get; set; }
}

public class DenialWorkflowTaskRow : WorkflowTaskRow { }
public class DenialVerificationTaskRow : VerificationTaskRow { }

public class AssignInsightRequest
{
    public List<string> TaskIds { get; set; } = new();
    public string? ReviewerUserName { get; set; }
    public int LabId { get; set; }
    public string? RunId { get; set; }
    public string? AssignedBy { get; set; }
    public string? ActionBy { get; set; }
    public string? DenialCode { get; set; }
    public string? PayerName { get; set; }
}

public class AssignWorkflowTasksRequest : AssignInsightRequest { }

public class UpdateTaskRequest
{
    public string? TaskID { get; set; }
    [JsonIgnore] public string? TaskId { get => TaskID; set => TaskID = value; }
    public string? Status { get; set; }
    public string? Comments { get; set; }
    public string? UpdatedBy { get; set; }
    public string? ActionBy { get; set; }
    public int LabId { get; set; }
    public string? RunId { get; set; }
}

public class UpdateWorkflowTaskStatusRequest : UpdateTaskRequest { }

public class VerificationDecisionRequest
{
    public long VerificationId { get; set; }
    public string? TaskID { get; set; }
    [JsonIgnore] public string? TaskId { get => TaskID; set => TaskID = value; }
    public bool IsValidDenial { get; set; }
    public string? VerificationComments { get; set; }
    public string? Comments { get; set; }
    public string? UpdatedBy { get; set; }
    public string? ActionBy { get; set; }
    public string? Status { get; set; }
    public int LabId { get; set; }
}

public class DenialWorkflowInsightRow
{
    public string? DenialCodes { get; set; }
    public string? Descriptions { get; set; }
    public int? NoOfDenialCount { get; set; }
    public int? NoOfClaimsCount { get; set; }
    public decimal? TotalBalance { get; set; }
    public string? HighImpactInsurance { get; set; }
    public decimal InsuranceBalance { get; set; }
    public decimal? ImpactPercentage { get; set; }
    public string? ActionCategory { get; set; }
    public string? ActionCode { get; set; }
    public string? Action { get; set; }
    public string? Task { get; set; }
    public string? Feedback { get; set; }
    public string? Responsibility { get; set; }
    public DateTime? DiscussionDate { get; set; }
    public string? ETA { get; set; }
    public string? LabName { get; set; }
    public int LabId { get; set; }
    public string? RunId { get; set; }
    public DateTime? CreatedOn { get; set; }
    public string? AssignedTo { get; set; }
    public string? ResponsibilityReviewer { get; set; }
}

public class DenialWorkflowLabOption
{
    public int LabId { get; set; }
    public string? LabName { get; set; }
}

public class DenialWorkflowReviewerOption
{
    public string? UserName { get; set; }
    public string? DisplayName { get; set; }
}

public class DenialWorkflowPageViewModel
{
    public int LabId { get; set; }
    public string? LabName { get; set; }
    public string? ActiveTab { get; set; }
    public bool IsAdmin { get; set; }
    public bool IsArManager { get; set; }
    public bool IsArReviewer { get; set; }
    public DenialWorkflowCounts Summary { get; set; } = new();
    public PagedResult<DenialWorkflowInsightRow> Insights { get; set; } = new();
    public PagedResult<WorkflowTaskRow> Tasks { get; set; } = new();
    public PagedResult<VerificationTaskRow> VerificationTasks { get; set; } = new();
    public List<ReviewerWorkflowSummaryRow> ReviewerSummary { get; set; } = new();
    public List<DenialWorkflowLabOption> LabOptions { get; set; } = new();
    public List<DenialWorkflowReviewerOption> ReviewerOptions { get; set; } = new();
    public DenialWorkflowFilter Filter { get; set; } = new();
}

public class DenialWorkflowOptions
{
    public string BaseUrl { get; set; } = "";
}
