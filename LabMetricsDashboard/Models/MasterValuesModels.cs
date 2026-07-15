namespace LabMetricsDashboard.Models;

public sealed class InsurancePayerMasterDto
{
    public int LabInsuranceMasterId { get; set; }
    public string? PayerCode { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public int? GlobalPayerID { get; set; }
    public string? PayerGroupCode { get; set; }
    public string? PayerCommonCode { get; set; }
    public string? Parent { get; set; }
    public string? PlanType { get; set; }
    public string? MCOType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public string? Remarks { get; set; }
    public string? LabName { get; set; }
    public int? LabId { get; set; }
    public string? LabState { get; set; }
    public string? LabStateCode { get; set; }
    // System-managed by the payer mapping pipeline.
    public string? MappingStatus { get; set; }
    public string? MappedBy { get; set; }
    public string? MappedSource { get; set; }
    public DateTime? MappedOn { get; set; }
}

public sealed class PayerPolicyInsuranceMasterDto
{
    public int PPInsuranceMasterId { get; set; }
    public int? GlobalPayerId { get; set; }
    public string GlobalPayerCode { get; set; } = string.Empty;
    public int? PayerGroupCode { get; set; }
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public string? PayerShortCode { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? Remarks { get; set; }
    // Brand-family classification (from the classified import); shown read-only in the listing.
    public string? PayerFamily { get; set; }
    public string? PayerFamilySource { get; set; }
}

public sealed class MasterValuesPageViewModel
{
    public string ApiBasePath { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public bool IsPolicy { get; set; }
    public string RoleLabel { get; set; } = string.Empty;
    public bool CanWrite { get; set; }
    public bool RequiresApproval { get; set; }
    public bool IsViewOnly => !CanWrite;
}

public sealed class MasterValueLabOption
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
}

public sealed class ImportResultDto
{
    public int TotalRows { get; set; }
    public int InsertedRows { get; set; }
    public int UpdatedRows { get; set; }
    public int SkippedRows { get; set; }
    public int ErrorRows { get; set; }
    public List<string> Warnings { get; set; } = new();
    public List<string> Errors { get; set; } = new();
    public List<GlobalPayerIdConflictDto> Conflicts { get; set; } = new();
    public List<ImportDuplicateDto> Duplicates { get; set; } = new();
    // Outcome counts of the payer matching pipeline run over the just-imported unmapped rows.
    public MappingEvaluationSummaryDto? Mapping { get; set; }
}

// ── Payer mapping intelligence (suggestions / typeahead / Approve-ManualMap-Reject) ──

public sealed class MappingEvaluationSummaryDto
{
    public int Evaluated { get; set; }
    public int AutoMapped { get; set; }
    public int PendingReview { get; set; }
    public int NoMatch { get; set; }
    public int Failed { get; set; }
}

public sealed class PayerMappingSuggestionDto
{
    public int Rank { get; set; }
    public int PPInsuranceMasterId { get; set; }
    public int? GlobalPayerId { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public string? PayerFamily { get; set; }
    public string? State { get; set; }
    public string? ProgramType { get; set; }
    public decimal Score { get; set; }
    public decimal BaseNameScore { get; set; }
    public int StateAdjustment { get; set; }
    public int ProgramAdjustment { get; set; }
    public bool MissingGlobalPayerId { get; set; }
}

public sealed class PayerMappingSuggestionsResponse
{
    public int LabInsuranceMasterId { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string CanonicalName { get; set; } = string.Empty;
    public string? ResolvedStateCode { get; set; }
    public string StateSignalSource { get; set; } = "None";
    public string? ResolvedProgramType { get; set; }
    public string? CandidateFamily { get; set; }
    public string? Decision { get; set; }
    public bool AliasHit { get; set; }
    public int? AliasGlobalPayerId { get; set; }
    public bool FromStoredCandidates { get; set; }
    public List<PayerMappingSuggestionDto> Suggestions { get; set; } = new();
}

public sealed class PayerPolicySearchResultDto
{
    public int PPInsuranceMasterId { get; set; }
    public int? GlobalPayerId { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public string? PayerFamily { get; set; }
    public string? State { get; set; }
    public string? ProgramType { get; set; }
    public decimal Score { get; set; }
    public bool MissingGlobalPayerId { get; set; }
}

public sealed class PayerMappingActionRequest
{
    public int PPInsuranceMasterId { get; set; }
}

// ── Payer Service Audit (worker run history + manual trigger) ────────────────

public sealed class PayerMapperRunDto
{
    public Guid RunId { get; set; }
    public string TriggerType { get; set; } = string.Empty;
    public string? Scope { get; set; }
    public string? RequestedBy { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime CreatedOn { get; set; }
    public DateTime? StartedOn { get; set; }
    public DateTime? CompletedOn { get; set; }
    public int TotalProcessed { get; set; }
    public int AutoMapped { get; set; }
    public int PendingReview { get; set; }
    public int NoMatch { get; set; }
    public int FailedRows { get; set; }
    public string? ErrorMessage { get; set; }
}

public sealed class PayerMapperRunListResponse
{
    public List<PayerMapperRunDto> Items { get; set; } = new();
    public int TotalCount { get; set; }
    public int Page { get; set; }
    public int PageSize { get; set; }
}

public sealed class PayerMapperRunDetailDto
{
    public long AuditId { get; set; }
    public int? LabInsuranceMasterId { get; set; }
    public string? PayerNameRaw { get; set; }
    public string? CanonicalName { get; set; }
    public string? Decision { get; set; }
    public decimal? ConfidenceScore { get; set; }
    public int? SelectedGlobalPayerId { get; set; }
    public string? MappingStatus { get; set; }
    public string? ActionType { get; set; }
    public DateTime PerformedOn { get; set; }
    public string? LabName { get; set; }
    public string? LabState { get; set; }
    public string? PayerState { get; set; }
}

public sealed class PayerMapperRunDetailsResponse
{
    public PayerMapperRunDto? Run { get; set; }
    public List<PayerMapperRunDetailDto> Details { get; set; } = new();
}

public sealed class PayerMapperTriggerResult
{
    public Guid RunId { get; set; }
    public string? Status { get; set; }
    public string? Message { get; set; }
}

/// <summary>MappingStatus row counts for the navbar notification bell.</summary>
public sealed class MappingStatusSummaryDto
{
    public int Mapped { get; set; }
    public int Unmapped { get; set; }
    public int PendingReview { get; set; }
    public int NoMatch { get; set; }
    public int Total { get; set; }
}

public sealed class PayerMappingActionResult
{
    public bool Success { get; set; }
    public string? Message { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? MappingStatus { get; set; }
}

public sealed class ImportDuplicateDto
{
    public int RowNumber { get; set; }
    public int KeptRowNumber { get; set; }
    public string? PayerCode { get; set; }
    public string? PayerNameRaw { get; set; }
    public string? PayerNameNormalized { get; set; }
    public int? GlobalPayerID { get; set; }
    public string? PayerGroupCode { get; set; }
    public string? PayerCommonCode { get; set; }
    public string? Parent { get; set; }
    public string? PlanType { get; set; }
    public string? MCOType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public string? Remarks { get; set; }
    public string? LabName { get; set; }
    public string? LabState { get; set; }
    public string? LabStateCode { get; set; }
    public string? Basis { get; set; }
}

public sealed class GlobalPayerIdConflictDto
{
    public int LabInsuranceMasterId { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string? LabName { get; set; }
    public int? ImportGlobalPayerId { get; set; }
    public int? PolicyGlobalPayerId { get; set; }
}

public sealed class GlobalPayerIdConflictResolutionRequest
{
    public List<GlobalPayerIdConflictResolution> Resolutions { get; set; } = new();
}

public sealed class GlobalPayerIdConflictResolution
{
    public int LabInsuranceMasterId { get; set; }
    public string Source { get; set; } = string.Empty;
    public int? ImportGlobalPayerId { get; set; }
    public int? PolicyGlobalPayerId { get; set; }
}

public sealed class GlobalPayerIdConflictResolutionResult
{
    public int Resolved { get; set; }
    public int Failed { get; set; }
    public List<string> Errors { get; set; } = new();
}

// ── Payer Master approval workflow ───────────────────────────────────────────

public sealed class PayerMasterApprovalRequestDto
{
    public int ApprovalRequestId { get; set; }
    public string Master { get; set; } = string.Empty;
    public string ActionType { get; set; } = string.Empty;
    public int? TargetId { get; set; }
    public string? PayerName { get; set; }
    public string SubmittedBy { get; set; } = string.Empty;
    public DateTime SubmittedOn { get; set; }
    public string Status { get; set; } = "Pending";
    public string? DecidedBy { get; set; }
    public DateTime? DecidedOn { get; set; }
    public string? RejectionReason { get; set; }
    public DateTime? EscalatedOn { get; set; }
    public DateTime SlaDeadline { get; set; }
    public bool IsOverdue { get; set; }
    public string? ChangeSummary { get; set; }
}

public sealed class PayerMasterApprovalDecisionRequest
{
    public List<int> Ids { get; set; } = new();
    public string? Reason { get; set; }
}

public sealed class PayerMasterApprovalDecisionResult
{
    public int Processed { get; set; }
    public int Failed { get; set; }
    public List<string> Errors { get; set; } = new();
}

public sealed class PayerMasterAuditEntryDto
{
    public long AuditId { get; set; }
    public string Master { get; set; } = string.Empty;
    public int? RecordId { get; set; }
    public int? GlobalPayerID { get; set; }
    public string? PayerName { get; set; }
    public string FieldName { get; set; } = string.Empty;
    public string? OldValue { get; set; }
    public string? NewValue { get; set; }
    public string ActionType { get; set; } = string.Empty;
    public string PerformedBy { get; set; } = string.Empty;
    public DateTime PerformedOn { get; set; }
    public string? ApprovalStatus { get; set; }
    public string? Approver { get; set; }
    public string? RejectionReason { get; set; }
}

public sealed class PayerMasterNotificationDto
{
    public int NotificationId { get; set; }
    public string Master { get; set; } = string.Empty;
    public string TriggerType { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string? Message { get; set; }
    public string? RecipientRole { get; set; }
    public string? RecipientUser { get; set; }
    public DateTime CreatedOn { get; set; }
}

public sealed class MasterPagedResult<T>
{
    public List<T> Items { get; set; } = new();
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
    public int TotalCount { get; set; }
    public int TotalRecords { get => TotalCount; set => TotalCount = value; }
    public int TotalPages { get; set; }
}
