namespace LRN.ReportsApi.Models;

/// <summary>
/// Bulk Update (Excel): one row per claim. Assign To reassigns the claim; the follow-up columns log
/// a Comments Framework note (same rules as Log Follow-Up Note). Version is the claim's latest user
/// activity id when the template was downloaded - the conflict check.
/// </summary>
public sealed class ArWorkbenchBulkRow
{
    public int RowNumber { get; set; }
    public string? ClaimId { get; set; }
    public long? Version { get; set; }
    public string? AssignTo { get; set; }
    public string? ClaimType { get; set; }
    public string? FollowUpType { get; set; }
    public string? ClaimStatus { get; set; }
    public string? DenialRootCause { get; set; }
    public string? FixResolution { get; set; }
    public string? Comment { get; set; }
    public DateTime? NextFollowUpDate { get; set; }
    /// <summary>Set when the date cell held text that is not a date.</summary>
    public string? NextFollowUpDateError { get; set; }
    public string? CipCategory { get; set; }
    public string? CipRequiredInfo { get; set; }
    public string? CipComment { get; set; }

    public bool HasFollowUp =>
        new[] { ClaimType, FollowUpType, ClaimStatus, DenialRootCause, FixResolution, Comment, CipCategory, CipRequiredInfo, CipComment }
            .Any(v => !string.IsNullOrWhiteSpace(v)) || NextFollowUpDate is not null || NextFollowUpDateError is not null;
}

/// <summary>A claim as the bulk update sees it: identity, owner and the conflict-check version.</summary>
public sealed class ArWorkbenchBulkClaimState
{
    public long ClaimKey { get; set; }
    public string ClaimId { get; set; } = string.Empty;
    public string WorkflowStatus { get; set; } = string.Empty;
    public string? AssignedAgentUser { get; set; }
    /// <summary>Latest non-system ARWB_ClaimActivity id (0 when nobody has worked the claim).</summary>
    public long Version { get; set; }
    public string? LastActivityBy { get; set; }
    public DateTime? LastActivityOn { get; set; }
}

/// <summary>Which claims the template is pre-filled with.</summary>
public sealed class ArWorkbenchBulkTemplateRequest
{
    /// <summary>"filtered" (the page's filter), "selected" (ClaimKeys) or "blank".</summary>
    public string? Mode { get; set; }
    public ArWorkbenchClaimFilter? Filter { get; set; }
    public List<long>? ClaimKeys { get; set; }
}
