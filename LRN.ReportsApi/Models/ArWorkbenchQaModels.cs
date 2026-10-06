namespace LRN.ReportsApi.Models;

/// <summary>QA Verification Queue filter (the claims with a current QA review).</summary>
public sealed class ArWorkbenchQaFilter
{
    public int LabId { get; set; }
    public string? Search { get; set; }
    /// <summary>Awaiting QA | Approved | Rejected. Empty = all.</summary>
    public List<string> ReviewStatus { get; set; } = new();
    public List<string> Payer { get; set; } = new();
    public List<string> Panel { get; set; } = new();
    public List<string> Category { get; set; } = new();
    public List<string> Agent { get; set; } = new();
    public List<string> Reviewer { get; set; } = new();
    /// <summary>"yes" = CIP escalation notes only, "no" = the others.</summary>
    public string? Escalation { get; set; }
    public string? SortBy { get; set; }
    public bool SortDesc { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class ArWorkbenchQaRow
{
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? LabName { get; set; }
    public string? PayerName { get; set; }
    public string? PanelName { get; set; }
    public string? DenialCategory { get; set; }
    public decimal InsuranceBalance { get; set; }
    public string WorkflowStatus { get; set; } = string.Empty;
    public string? AssignedAgentUser { get; set; }
    public string? AssignedAgentName { get; set; }
    public long QaReviewId { get; set; }
    public string ReviewStatus { get; set; } = string.Empty;
    public bool IsEscalation { get; set; }
    public bool IsWriteOff { get; set; }
    public string SubmittedBy { get; set; } = string.Empty;
    public DateTime SubmittedOn { get; set; }
    public string? ReviewedBy { get; set; }
    public DateTime? ReviewedOn { get; set; }
    public string? ErrorType { get; set; }
    public string? ReviewNote { get; set; }
    /// <summary>The note under review.</summary>
    public string? FollowUpClaimStatus { get; set; }
    public string? FixResolution { get; set; }
    public string? FollowUpComment { get; set; }
    /// <summary>The caller submitted this note or holds the claim: they may not decide it.</summary>
    public bool IsOwnWork { get; set; }
}

public sealed class ArWorkbenchQaSummary
{
    public int AwaitingQa { get; set; }
    public int EscalationsPending { get; set; }
    public int WriteOffsPending { get; set; }
    public int Rejected { get; set; }
    public int Approved { get; set; }
    /// <summary>Rejected / (approved + rejected) of the current reviews; null before any decision.</summary>
    public decimal? RejectRate { get; set; }
}

public sealed class ArWorkbenchQaQueue
{
    public ArWorkbenchQaSummary Summary { get; set; } = new();
    public ArWorkbenchPagedResult<ArWorkbenchQaRow> Rows { get; set; } = new();
    public List<ArWorkbenchFilterOption> Reviewers { get; set; } = new();
}

/// <summary>The six quality-scoring criteria (true = met). Null = not scored.</summary>
public sealed class ArWorkbenchQaScores
{
    public bool? ClaimAnalysis { get; set; }
    public bool? DenialCategory { get; set; }
    public bool? ActionTaken { get; set; }
    public bool? Documentation { get; set; }
    public bool? FinancialUpdate { get; set; }
    public bool? FollowUpTiming { get; set; }
}

public sealed class ArWorkbenchQaDecisionRequest
{
    /// <summary>approve | reject</summary>
    public string? Decision { get; set; }
    /// <summary>Required on reject: a QA_ERROR_TYPE value.</summary>
    public string? ErrorType { get; set; }
    /// <summary>Required on reject: what needs correcting.</summary>
    public string? Note { get; set; }
    public ArWorkbenchQaScores? Scores { get; set; }
}

public sealed class ArWorkbenchQaBulkApproveRequest
{
    public List<long> ClaimKeys { get; set; } = new();
    public string? Note { get; set; }
}

public sealed class ArWorkbenchQaBulkResult
{
    public int Approved { get; set; }
    public int SkippedOwnWork { get; set; }
    public int SkippedNotAwaiting { get; set; }
    public int SkippedNotFound { get; set; }
    public int EscalationsReleased { get; set; }
    public int WriteOffsApproved { get; set; }
    public string Message { get; set; } = string.Empty;
}

/// <summary>The claim's current QA review, for the claim page's QA tab.</summary>
public sealed class ArWorkbenchQaReview
{
    public long QaReviewId { get; set; }
    public string ReviewStatus { get; set; } = string.Empty;
    public bool IsEscalation { get; set; }
    public bool IsWriteOff { get; set; }
    public string SubmittedBy { get; set; } = string.Empty;
    public DateTime SubmittedOn { get; set; }
    public string? ReviewedBy { get; set; }
    public DateTime? ReviewedOn { get; set; }
    public string? ErrorType { get; set; }
    public string? ReviewNote { get; set; }
    public ArWorkbenchQaScores Scores { get; set; } = new();
}
