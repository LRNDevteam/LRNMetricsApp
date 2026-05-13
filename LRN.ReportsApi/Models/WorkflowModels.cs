namespace LRN.ReportsApi.Models;


public sealed class DenialWorkflowLabOption
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
}

public sealed class ReviewerOption
{
    public int LabUserId { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string FullName { get => DisplayName; set => DisplayName = value ?? string.Empty; }
    public string Email { get; set; } = string.Empty;
}

public sealed class DenialWorkflowOptions
{
    public string[] ClosedStatuses { get; set; } = ["Closed", "Completed"];
    public string[] ClaimLevelActionCategories { get; set; } = ["Rebill"];
}

public sealed class PagedResult<T>
{
    public List<T> Items { get; set; } = new();
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 100;
    public int TotalCount { get; set; }
    public int TotalRecords { get => TotalCount; set => TotalCount = value; }
    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling((double)TotalCount / PageSize);
}

public sealed class DenialWorkflowFilter
{
    public int LabId { get; set; }
    public string Role { get; set; } = string.Empty;
    public string UserName { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string Reviewer { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string Clinic { get; set; } = string.Empty;
    public string SalesRepname { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public string SearchText { get; set; } = string.Empty;
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 100;
}



public sealed class DenialWorkflowFilterOptions
{
    public IReadOnlyList<string> Statuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ActionCategories { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Priorities { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> DenialCodes { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> PayerNames { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> DenialClassifications { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Clinics { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> SalesReps { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ReferringProviders { get; set; } = Array.Empty<string>();
}

public sealed class DenialWorkflowUserContext
{
    public string UserName { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public string Role { get; set; } = string.Empty;
    public IReadOnlyList<DenialWorkflowLabOption> Labs { get; set; } = Array.Empty<DenialWorkflowLabOption>();
}

public sealed class DenialWorkflowDashboardSummary
{
    public int TotalDenials { get; set; }
    public decimal OutstandingAmount { get; set; }
    public int OpenInProgressCount { get; set; }
    public int ClosedCount { get; set; }
    public IReadOnlyList<DenialClassificationSummaryRow> DenialClassifications { get; set; } = Array.Empty<DenialClassificationSummaryRow>();
    public IReadOnlyList<ReviewerWorkflowSummaryRow> AnalystWorkload { get; set; } = Array.Empty<ReviewerWorkflowSummaryRow>();
    public IReadOnlyList<ActionCategorySummaryRow> ActionCategories { get; set; } = Array.Empty<ActionCategorySummaryRow>();
    public IReadOnlyList<SlaSummaryRow> SlaTiles { get; set; } = Array.Empty<SlaSummaryRow>();
}

public sealed class DenialClassificationSummaryRow
{
    public string Classification { get; set; } = string.Empty;
    public int Count { get; set; }
    public decimal Outstanding { get; set; }
    public decimal PercentageOfTotal { get; set; }
    public int Open { get; set; }
    public int InProgress { get; set; }
    public int Closed { get; set; }
}

public sealed class ActionCategorySummaryRow
{
    public string ActionCategory { get; set; } = string.Empty;
    public int Count { get; set; }
    public decimal Outstanding { get; set; }
    public decimal PercentageOfTotal { get; set; }
}

public sealed class SlaSummaryRow
{
    public string Label { get; set; } = string.Empty;
    public int Count { get; set; }
    public string Status { get; set; } = string.Empty;
}

public sealed class DenialTaskImportRequest
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public List<DenialTaskImportRow> Tasks { get; set; } = new();
}

public sealed class DenialTaskImportRow
{
    public string UniqueTrackId { get; set; } = string.Empty;
    public string ClaimId { get; set; } = string.Empty;
    public string PatientId { get; set; } = string.Empty;
    public string CptCode { get; set; } = string.Empty;
    public int? Units { get; set; }
    public string Modifier { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string ActionCode { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public int? SlaDays { get; set; }
    public DateTime? DateOpened { get; set; }
    public DateTime? DueDate { get; set; }
    public DateTime? DateCompleted { get; set; }
    public string SalesRepname { get; set; } = string.Empty;
    public string ClinicName { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PayerNameNormalized { get; set; } = string.Empty;
    public int? PayerCode { get; set; }
    public string PayerType { get; set; } = string.Empty;
    public DateTime? FirstBilledDate { get; set; }
    public DateTime? ChargeEnteredDate { get; set; }
    public string BillingProvider { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public DateTime? DateOfService { get; set; }
}

public sealed class DenialWorkflowImportResult
{
    public int Imported { get; set; }
    public int Created { get; set; }
    public int Updated { get; set; }
    public int MovedToVerification { get; set; }
    public int MovedToHistory { get; set; }
    public int ReopenedToVerification { get; set; }
}

public sealed class DenialWorkflowResult
{
    public bool Success { get; set; }
    public string Message { get; set; } = string.Empty;
    public int RowsAffected { get; set; }
}

public class DenialWorkflowSummary
{
    public int Assigned { get; set; }
    public int Completed { get; set; }
    public int Pending { get; set; }
    public int VerificationPending { get; set; }
    public int Unassigned { get; set; }
}

public sealed class ReviewerWorkflowSummaryRow
{
    public string ReviewerName { get; set; } = string.Empty;
    public int TotalAssigned { get; set; }
    public int Closed { get; set; }
    public int Pending { get; set; }
}

public sealed class DenialWorkflowInsightRow
{
    public string DenialCodes { get; set; } = string.Empty;
    public string Descriptions { get; set; } = string.Empty;
    public int NoOfDenialCount { get; set; }
    public int NoOfClaimsCount { get; set; }
    public decimal TotalBalance { get; set; }
    public string HighImpactInsurance { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public decimal ImpactPercentage { get; set; }
    public string ActionCategory { get; set; } = string.Empty;
    public string ActionCode { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string Feedback { get; set; } = string.Empty;
    public string Responsibility { get; set; } = string.Empty;
    public DateTime? DiscussionDate { get; set; }
    public string ETA { get; set; } = string.Empty;
    public string LabName { get; set; } = string.Empty;
    public int LabId { get; set; }
    public string RunId { get; set; } = string.Empty;
    public DateTime? CreatedOn { get; set; }
    public string AssignedTo { get; set; } = string.Empty;
    public string ResponsibilityReviewer { get; set; } = string.Empty;
}

public class WorkflowTaskRow
{
    public string TaskId { get; set; } = string.Empty;
    public string UniqueTrackId { get; set; } = string.Empty;
    public string ClaimId { get; set; } = string.Empty;
    public string PatientId { get; set; } = string.Empty;
    public string CptCode { get; set; } = string.Empty;
    public int? Units { get; set; }
    public string Modifier { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string ActionCode { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public bool IsCurrentDenial { get; set; }
    public int? SlaDays { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime? DateOpened { get; set; }
    public DateTime? DueDate { get; set; }
    public DateTime? DateCompleted { get; set; }
    public int? DaysRemaining { get; set; }
    public string SlaStatus { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public DateTime? CreatedOn { get; set; }
    public string SalesRepname { get; set; } = string.Empty;
    public string ClinicName { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PayerNameNormalized { get; set; } = string.Empty;
    public int? PayerCode { get; set; }
    public string PayerType { get; set; } = string.Empty;
    public DateTime? FirstBilledDate { get; set; }
    public DateTime? ChargeEnteredDate { get; set; }
    public string BillingProvider { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public DateTime? DateOfService { get; set; }
    public string ReviewerComments { get; set; } = string.Empty;
    public DateTime? ReviewerUpdatedOn { get; set; }
    public string ReviewerUpdatedBy { get; set; } = string.Empty;
    public string ICDCodes { get; set; } = string.Empty;
    public string CoverageStatus { get; set; } = string.Empty;
    public string ICDComplianceStatus { get; set; } = string.Empty;
    public string DenialValidity { get; set; } = string.Empty;
}

public class VerificationTaskRow : WorkflowTaskRow
{
    public long VerificationId { get; set; }
    public string VerificationStatus { get; set; } = string.Empty;
    public string VerificationComments { get; set; } = string.Empty;
    public string OriginalRunId { get; set; } = string.Empty;
    public string MissingDetectedRunId { get; set; } = string.Empty;
    public DateTime? MovedOn { get; set; }
    public string VerifiedBy { get; set; } = string.Empty;
    public DateTime? VerifiedOn { get; set; }
}

public sealed class ClaimLevelRow
{
    public string ClaimId { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public DateTime? PatientDOB { get; set; }
    public string PatientId { get; set; } = string.Empty;
    public string ClinicName { get; set; } = string.Empty;
    public string SalesRepname { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public DateTime? DateOfService { get; set; }
    public string AssignedTo { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public int TaskCount { get; set; }
    public decimal InsuranceBalance { get; set; }
}

public sealed class ClaimAssignmentConflict
{
    public string ClaimId { get; set; } = string.Empty;
    public string TaskId { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
}

public sealed class AssignClaimRequest
{
    public int LabId { get; set; }
    public List<string> ClaimIds { get; set; } = new();
    public string ReviewerUserName { get; set; } = string.Empty;
    public string ActionBy { get; set; } = string.Empty;
    public bool OverwriteExisting { get; set; }
}

public sealed class ClaimAssignmentResult
{
    public bool Success { get; set; }
    public string Message { get; set; } = string.Empty;
    public int RowsAffected { get; set; }
    public bool HasConflicts { get; set; }
    public IReadOnlyList<ClaimAssignmentConflict> Conflicts { get; set; } = Array.Empty<ClaimAssignmentConflict>();
}

public sealed class AssignInsightRequest
{
    public int LabId { get; set; }
    public string? RunId { get; set; }
    public string DenialCode { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string ReviewerUserName { get; set; } = string.Empty;
    public string ActionBy { get; set; } = string.Empty;
}

public sealed class UpdateTaskRequest
{
    public int LabId { get; set; }
    public string TaskId { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string Comments { get; set; } = string.Empty;
    public string ActionBy { get; set; } = string.Empty;
}

public sealed class VerificationDecisionRequest
{
    public int LabId { get; set; }
    public long VerificationId { get; set; }
    public bool IsValidDenial { get; set; }
    public string Status { get; set; } = string.Empty;
    public string Comments { get; set; } = string.Empty;
    public string ActionBy { get; set; } = string.Empty;
}

public sealed class DenialNoteRow
{
    public long NoteId { get; set; }
    public int LabId { get; set; }
    public string ClaimId { get; set; } = string.Empty;
    public string? TaskId { get; set; }
    public string? CptCode { get; set; }
    public string NoteLevel { get; set; } = string.Empty;
    public string NoteText { get; set; } = string.Empty;
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime CreatedOn { get; set; }
}

public sealed class SaveDenialNoteRequest
{
    public int LabId { get; set; }
    public string ClaimId { get; set; } = string.Empty;
    public string? TaskId { get; set; }
    public string? CptCode { get; set; }
    public string NoteLevel { get; set; } = "Claim";
    public string NoteText { get; set; } = string.Empty;
    public string CreatedBy { get; set; } = string.Empty;
}

public sealed class ClaimDocumentRow
{
    public long DocumentId { get; set; }
    public int LabId { get; set; }
    public string ClaimId { get; set; } = string.Empty;
    public string OriginalFileName { get; set; } = string.Empty;
    public string StoredFileName { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long FileSizeBytes { get; set; }
    public string FilePath { get; set; } = string.Empty;
    public string Comment { get; set; } = string.Empty;
    public string UploadedBy { get; set; } = string.Empty;
    public DateTime UploadedOn { get; set; }
}


public sealed class DenialEscalationRow
{
    public long EscalationId { get; set; }
    public int LabId { get; set; }
    public string ClaimId { get; set; } = string.Empty;
    public string? TaskId { get; set; }
    public string? CptCode { get; set; }
    public string EscalationLevel { get; set; } = "Claim";
    public string EscalationReason { get; set; } = string.Empty;
    public string Comments { get; set; } = string.Empty;
    public string Status { get; set; } = "Open";
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime CreatedOn { get; set; }
}

public sealed class SaveDenialEscalationRequest
{
    public int LabId { get; set; }
    public string ClaimId { get; set; } = string.Empty;
    public string? TaskId { get; set; }
    public string? CptCode { get; set; }
    public string EscalationLevel { get; set; } = "Claim";
    public string EscalationReason { get; set; } = string.Empty;
    public string Comments { get; set; } = string.Empty;
    public string Status { get; set; } = "Open";
    public string CreatedBy { get; set; } = string.Empty;
}
