namespace LRN.ReportsApi.Models;

public sealed class DenialCodeMasterRecord
{
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public string? ActionCode { get; set; }
    public string? RecommendedAction { get; set; }
    public string? ActionCategory { get; set; }
    public string? Task { get; set; }
    public string? ShortCategory { get; set; }
    public string? Priority { get; set; }
    public string? SLADays { get; set; }
    public string? NotesComments { get; set; }
    public DateTime CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }
}

public sealed class DenialCodeMasterRequest
{
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public string? ActionCode { get; set; }
    public string? RecommendedAction { get; set; }
    public string? ActionCategory { get; set; }
    public string? Task { get; set; }
    public string? ShortCategory { get; set; }
    public string? Priority { get; set; }
    public string? SLADays { get; set; }
    public string? NotesComments { get; set; }
}

public sealed class DenialCodeMasterLookups
{
    public IReadOnlyList<string> DenialClassifications { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> CoverageStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ICDComplianceStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> DenialValidities { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ActionCodes { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ActionCategories { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Tasks { get; set; } = Array.Empty<string>();
}

public sealed class DenialCodeMasterImportResult
{
    public int InsertedCount { get; set; }
    public int UpdatedCount { get; set; }
    public int SkippedCount { get; set; }
    public int FailedCount { get; set; }
    public IReadOnlyList<string> Errors { get; set; } = Array.Empty<string>();
    public bool HasActionChangeWarnings { get; set; }
    public long? BatchId { get; set; }
    public int AffectedClaims { get; set; }
    public int AffectedTasks { get; set; }
    public string? Message { get; set; }
}

public sealed class DenialCodeMasterImportRequest
{
    public IFormFile? File { get; set; }
}

public sealed class DenialCodeMasterExportOptions
{
    public string ExportFolderPath { get; set; } = @"D:\LRN\DenialCodeMaster";
    public string ExportFileName { get; set; } = "PCRLabsofAmerica_Denial_Action_Classifier_v1.1.xlsx";
}

public sealed class DenialActionChangeBatch
{
    public long BatchId { get; set; }
    public string SourceFileName { get; set; } = string.Empty;
    public string UploadedBy { get; set; } = string.Empty;
    public DateTime UploadedOn { get; set; }
    public int TotalAffectedClaims { get; set; }
    public int TotalAffectedTasks { get; set; }
    public int PendingCount { get; set; }
    public int ConfirmedCount { get; set; }
    public int IgnoredCount { get; set; }
    public string Status { get; set; } = "Pending";
}

public sealed class DenialActionChangeVerification
{
    public long VerificationId { get; set; }
    public long BatchId { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? TaskID { get; set; }
    public string? PatientId { get; set; }
    public string? CPTCode { get; set; }
    public int? Units { get; set; }
    public string? Modifier { get; set; }
    public string? PayerName { get; set; }
    public string? AssignedTo { get; set; }
    public string? ClaimStatus { get; set; }
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ActionCode { get; set; }
    public string? ActionCategory { get; set; }
    public string? RecommendedAction { get; set; }
    public string? Task { get; set; }
    public string? Priority { get; set; }
    public decimal? InsuranceBalance { get; set; }
    public int? SLADays { get; set; }
    public string? Status { get; set; }
    public DateTime? DateOpened { get; set; }
    public DateTime? DueDate { get; set; }
    public string? SLAStatus { get; set; }
    public DateTime? FirstBilledDate { get; set; }
    public DateTime? ChargeEnteredDate { get; set; }
    public string? DenialValidity { get; set; }
    public string? OldActionCode { get; set; }
    public string? NewActionCode { get; set; }
    public string? OldActionCategory { get; set; }
    public string? NewActionCategory { get; set; }
    public string? OldTask { get; set; }
    public string? NewTask { get; set; }
    public string? OldShortCategory { get; set; }
    public string? NewShortCategory { get; set; }
    public string VerificationStatus { get; set; } = "Pending";
    public string? VerifiedBy { get; set; }
    public DateTime? VerifiedOn { get; set; }
    public DateTime CreatedOn { get; set; }
}

public sealed class DenialActionChangeQuery
{
    public int LabId { get; set; }
    public long? BatchId { get; set; }
    public string? Search { get; set; }
    public string? DenialCode { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? CoverageStatus { get; set; }
    public string? AssignedTo { get; set; }
    public string? Status { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public sealed class DenialActionChangeLookups
{
    public IReadOnlyList<DenialActionChangeBatch> Batches { get; set; } = Array.Empty<DenialActionChangeBatch>();
    public IReadOnlyList<string> DenialCodes { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ICDComplianceStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> CoverageStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> AssignedUsers { get; set; } = Array.Empty<string>();
}

public sealed class DenialActionChangeResult
{
    public bool Success { get; set; }
    public string Message { get; set; } = string.Empty;
}
