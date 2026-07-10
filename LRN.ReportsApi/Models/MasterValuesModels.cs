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
    // System-managed by the payer mapping pipeline (read-only for edits; never written by save paths).
    public string? MappingStatus { get; set; }
    public string? MappedBy { get; set; }
}

public sealed class PayerPolicyInsuranceMasterDto
{
    // PK is PPInsuranceMasterId in the real dbo.PayerPolicyInsuranceMaster table.
    public int PPInsuranceMasterId { get; set; }
    // GlobalPayerId is stored as nvarchar(50) in the DB but is always numeric ("require numeric
    // everywhere"), so it is surfaced as int? and mapped to/from the string column.
    public int? GlobalPayerId { get; set; }
    public string GlobalPayerCode { get; set; } = string.Empty; // NOT NULL in the DB
    public int? PayerGroupCode { get; set; }                    // int column in the policy table
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public string? PayerShortCode { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? Remarks { get; set; }
    // Brand-family classification used by the payer mapping pipeline (Step 6 candidate blocking).
    // Populated by the classified import file; a null on save preserves the stored value.
    public string? PayerFamily { get; set; }
    public string? PayerFamilySource { get; set; }
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
    public string? GlobalPayerCode { get; set; }
    public string? PayerName { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? PayerShortCode { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
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
    // GlobalPayerID conflicts detected during a Lab import (import value != Payer Policy master value).
    // The affected Lab records are saved with a NULL GlobalPayerID until the user resolves each one.
    public List<GlobalPayerIdConflictDto> Conflicts { get; set; } = new();
    // Import-file rows skipped as duplicates of another row in the same workbook (counted in SkippedRows).
    public List<ImportDuplicateDto> Duplicates { get; set; } = new();
    // Lab import only: ids of imported rows left without a GlobalPayerID - the upload hook runs the
    // matching pipeline over exactly these and fills Mapping with the outcome counts.
    public List<int> UnmappedRecordIds { get; set; } = new();
    public MappingEvaluationSummaryDto? Mapping { get; set; }
}

/// <summary>
/// A workbook row skipped as a duplicate during import (same Payer_Name_Raw + Lab Name as the
/// surviving row, KeptRowNumber; the last matching row in the file wins). Carries every import
/// column so the full row can be downloaded from the import summary.
/// </summary>
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

/// <summary>
/// A single Lab Insurance Master row whose imported Global Payer ID disagrees with the
/// Payer Policy Insurance Master value for the same PayerNameRaw. Saved with GlobalPayerID = NULL
/// until the user chooses which value to keep.
/// </summary>
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
    // "Import" => keep the import file value; "Policy" => keep the Payer Policy master value.
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
