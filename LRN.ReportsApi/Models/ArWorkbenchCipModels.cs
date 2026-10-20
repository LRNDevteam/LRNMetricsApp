namespace LRN.ReportsApi.Models;

/// <summary>CIP Escalations queue filter (internal) and the client's Escalation Requests list.</summary>
public sealed class ArWorkbenchCipFilter
{
    public int LabId { get; set; }
    /// <summary>Pending Approval | Sent to Client | Client Responded | Returned to Agent (| Awaiting QA). Empty = the four after QA.</summary>
    public List<string> Status { get; set; } = new();
    public List<string> Category { get; set; } = new();
    public List<string> Payer { get; set; } = new();
    public string? Search { get; set; }
    public string? SortBy { get; set; }
    public bool SortDesc { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class ArWorkbenchCipCaseRow
{
    public long CipCaseId { get; set; }
    public string CaseNumber { get; set; } = string.Empty;
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? LabName { get; set; }
    public string? PayerName { get; set; }
    public string? PatientID { get; set; }
    public DateTime? DateOfService { get; set; }
    public string? ClinicName { get; set; }
    public string? ReferringProvider { get; set; }
    public string CaseStatus { get; set; } = string.Empty;
    public int RoundNumber { get; set; }
    public string CipCategory { get; set; } = string.Empty;
    public string RequiredInfo { get; set; } = string.Empty;
    public string CipComment { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public string? ArQueueId { get; set; }
    public string? ArQueueLabel { get; set; }
    public string RequestedBy { get; set; } = string.Empty;
    public DateTime RequestedOn { get; set; }
    public DateTime? FollowUpDate { get; set; }
    public string? OriginalAgentUser { get; set; }
    public string? LastReviewDecision { get; set; }
    public string? LastReviewNote { get; set; }
    public string? LastReviewedBy { get; set; }
    public DateTime? LastReviewedOn { get; set; }
    public string? ClientResponseText { get; set; }
    public string? ClientRespondedBy { get; set; }
    public DateTime? ClientRespondedOn { get; set; }
    public DateTime? ClosedOn { get; set; }
    /// <summary>Files the client attached to their responses.</summary>
    public List<ArWorkbenchDocumentInfo> Attachments { get; set; } = new();
}

public sealed class ArWorkbenchDocumentInfo
{
    public long DocumentId { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string? ContentType { get; set; }
    public long SizeBytes { get; set; }
    public int? RoundNumber { get; set; }
    public string UploadedBy { get; set; } = string.Empty;
    public DateTime UploadedOn { get; set; }
}

/// <summary>
/// A claim document in the Document Vault / a claim's Documents tab (handoff §8.2, DEF-13 / DEF-14):
/// follow-up attachments and CIP responses, with the claim and patient they belong to.
/// </summary>
public sealed class ArWorkbenchDocumentRow
{
    public long DocumentId { get; set; }
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? AccessionNumber { get; set; }
    public string? PatientName { get; set; }
    public string? PatientID { get; set; }
    public DateTime? DateOfService { get; set; }
    public string? PayerName { get; set; }
    /// <summary>FollowUp | CipResponse | Other.</summary>
    public string DocumentSource { get; set; } = string.Empty;
    public string DocumentCategory { get; set; } = string.Empty;
    /// <summary>From LRNMaster dbo.ARDocumentTypeMaster; null on CIP responses and older uploads.</summary>
    public string? DocumentTypeName { get; set; }
    public string? DocumentTypeCode { get; set; }
    /// <summary>The uploader's notes on the file (optional).</summary>
    public string? Description { get; set; }
    public long? FollowUpId { get; set; }
    public long? CipCaseId { get; set; }
    public int? RoundNumber { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string? ContentType { get; set; }
    public long SizeBytes { get; set; }
    public string UploadedBy { get; set; } = string.Empty;
    public DateTime UploadedOn { get; set; }
}

/// <summary>The document type and notes of one uploaded file (claim document upload, same order as the files).</summary>
public sealed class ArWorkbenchDocumentUploadInfo
{
    /// <summary>LRNMaster dbo.ARDocumentTypeMaster.DocumentTypeID - mandatory.</summary>
    public int? DocumentTypeId { get; set; }
    /// <summary>Notes on the file (optional), stored in ARWB_Document.Description.</summary>
    public string? Description { get; set; }
}

/// <summary>An active row of LRNMaster dbo.ARDocumentTypeMaster - the upload's Document Type dropdown.</summary>
public sealed class ArWorkbenchDocumentType
{
    public int DocumentTypeId { get; set; }
    public string DocumentCategory { get; set; } = string.Empty;
    public string DocumentTypeCode { get; set; } = string.Empty;
    public string DocumentTypeName { get; set; } = string.Empty;
}

/// <summary>Document Vault search: claim / visit, patient and category (handoff §8.2).</summary>
public sealed class ArWorkbenchDocumentFilter
{
    public int LabId { get; set; }
    /// <summary>Claim ID, accession (visit) number, patient name or patient account - partial match.</summary>
    public string? Search { get; set; }
    public string? Category { get; set; }
    public string? Source { get; set; }
    public DateTime? From { get; set; }
    public DateTime? To { get; set; }
    public long? ClaimKey { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

/// <summary>T065 bulk CSV response upload outcome (mockup handleBulkCipUpload).</summary>
public sealed class ArWorkbenchCipBulkResponseResult
{
    public int Updated { get; set; }
    public int SkippedBlank { get; set; }
    public int SkippedNotOpen { get; set; }
    public int SkippedNotFound { get; set; }
    public List<string> Errors { get; set; } = new();
    public string Message { get; set; } = string.Empty;
}

public sealed class ArWorkbenchCipCounts
{
    public int AwaitingQa { get; set; }
    public int PendingApproval { get; set; }
    public int SentToClient { get; set; }
    public int ClientResponded { get; set; }
    public int ReturnedToAgent { get; set; }
}

public sealed class ArWorkbenchCipQueue
{
    public ArWorkbenchCipCounts Counts { get; set; } = new();
    public ArWorkbenchPagedResult<ArWorkbenchCipCaseRow> Rows { get; set; } = new();
}

public sealed class ArWorkbenchCipHistoryEntry
{
    public int RoundNumber { get; set; }
    public DateTime ActionOn { get; set; }
    public string Actor { get; set; } = string.Empty;
    public string? ActorRole { get; set; }
    public string ActionName { get; set; } = string.Empty;
    public string? Note { get; set; }
    public bool IsBulkAction { get; set; }
}

public sealed class ArWorkbenchCipCaseDetail
{
    public ArWorkbenchCipCaseRow Case { get; set; } = new();
    public List<ArWorkbenchCipHistoryEntry> History { get; set; } = new();
}

/// <summary>approve | reject (Pending Approval); approve-response | insufficient (Client Responded); respond (client, Sent to Client).</summary>
public sealed class ArWorkbenchCipActionRequest
{
    public string? Action { get; set; }
    public string? Note { get; set; }
}

/// <summary>Bulk from the queue: "approve" or "sendback"; each case gets the action for its own stage.</summary>
public sealed class ArWorkbenchCipBulkRequest
{
    public List<long> CaseIds { get; set; } = new();
    public string? Decision { get; set; }
    public string? Note { get; set; }
}

/// <summary>T063 legacy conversion: what would be / was converted.</summary>
public sealed class ArWorkbenchLegacyCipResult
{
    public int Candidates { get; set; }
    public int Converted { get; set; }
    public int SentToClient { get; set; }
    public int ClientResponded { get; set; }
    public int ReturnedToAgent { get; set; }
    public int NoMatchingClaim { get; set; }
    public string? Note { get; set; }
    public string? Message { get; set; }
}

public sealed class ArWorkbenchCipBulkResult
{
    public int SentToClient { get; set; }
    public int ReturnedToAgent { get; set; }
    public int ResentToClient { get; set; }
    public int Skipped { get; set; }
    public string Message { get; set; } = string.Empty;
}
