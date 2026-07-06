namespace LRN.ReportsApi.Models;

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
}

public sealed class PayerPolicyInsuranceMasterDto
{
    public int PayerPolicyInsuranceMasterId { get; set; }
    public string? PayerCode { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public int? GlobalPayerID { get; set; }
    public string? PayerGroupCode { get; set; }
    public string? PayerCommonCode { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public string? Remarks { get; set; }
    public string? IsMCO { get; set; }
}

public sealed class InsurancePayerMasterQuery
{
    public string? Search { get; set; }
    public int? LabId { get; set; }
    public string? PayerCode { get; set; }
    public string? PayerName { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? IsActive { get; set; }
    public string? SortColumn { get; set; }
    public string? SortDirection { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class PayerPolicyInsuranceMasterQuery
{
    public string? Search { get; set; }
    public string? PayerCode { get; set; }
    public string? PayerName { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? IsMCO { get; set; }
    public string? SortColumn { get; set; }
    public string? SortDirection { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
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
}

public sealed class MasterValueStatusRequest
{
    public string? IsActive { get; set; }
}

public sealed class MasterValueImportRequest
{
    public IFormFile? File { get; set; }
}

public sealed class MasterValueLabOption
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
}

// ── Payer Master approval workflow (Requirements Spec v1.0) ──────────────────

public sealed class PayerMasterApprovalRequestDto
{
    public int ApprovalRequestId { get; set; }
    public string Master { get; set; } = string.Empty;          // Policy | Lab
    public string ActionType { get; set; } = string.Empty;      // Add | Edit | Deactivate | Map
    public int? TargetId { get; set; }
    public string? PayerName { get; set; }
    public string? PayloadJson { get; set; }
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

public sealed class PayerMasterApprovalQuery
{
    public string? Master { get; set; }
    public string? Status { get; set; }
    public string? SubmittedBy { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
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

public sealed class PayerMasterAuditQuery
{
    public string? Master { get; set; }
    public string? ActionType { get; set; }
    public string? Search { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
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

public sealed class PayerMasterWorkflowActionResult
{
    public bool Success { get; set; } = true;
    public bool PendingApproval { get; set; }
    public int? Id { get; set; }
    public int? ApprovalRequestId { get; set; }
    public string? Message { get; set; }
}
