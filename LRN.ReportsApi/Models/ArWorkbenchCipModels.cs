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
