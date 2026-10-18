namespace LRN.ReportsApi.Models;

// ============================================================================================
// Status Change Verification: the weekly claim sync (dbo.ARWB_usp_LoadClaimsFromSource step 3g)
// moves an assigned, not-completed claim whose master-file claim status changed (e.g. No Response
// -> Paid) to WorkflowStatus 'Pending Verification' under an RCM Manager of the lab
// (dbo.ARWB_StatusVerification). The manager returns it to the agent, releases it to the pool, or
// completes it.
//
// Notifications: dbo.ARWB_Notification rows addressed to the user, or to their workbench role.
// ============================================================================================

public static class ArWorkbenchStatusVerificationActions
{
    public const string ReturnToAgent = "ReturnToAgent";
    public const string Unassign = "Unassign";
    public const string Complete = "Complete";

    public static readonly string[] All = [ReturnToAgent, Unassign, Complete];

    /// <summary>The canonical action name, or null for anything else.</summary>
    public static string? Normalize(string? action) =>
        All.FirstOrDefault(a => string.Equals(a, action?.Trim(), StringComparison.OrdinalIgnoreCase));
}

public sealed class ArWorkbenchStatusVerificationFilter
{
    public int LabId { get; set; }
    /// <summary>Pending (default) | Resolved | All</summary>
    public string? Status { get; set; }
    /// <summary>true = only the caller's own (routed to them, or to no one in particular).</summary>
    public bool Mine { get; set; }
    public string? Search { get; set; }
}

public sealed class ArWorkbenchStatusVerificationRow
{
    public long StatusVerificationId { get; set; }
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? PatientName { get; set; }
    public string? PayerName { get; set; }
    public DateTime? DateOfService { get; set; }
    public decimal InsuranceBalance { get; set; }
    public string? PrimaryDenialCode { get; set; }
    public string? PreviousSourceStatus { get; set; }
    public string? NewSourceStatus { get; set; }
    /// <summary>The claim's status in the master file today (may have moved again since raised).</summary>
    public string? CurrentSourceStatus { get; set; }
    public string PreviousWorkflowStatus { get; set; } = string.Empty;
    public string WorkflowStatus { get; set; } = string.Empty;
    public string? AgentUser { get; set; }
    public string? AgentName { get; set; }
    public string? ManagerUser { get; set; }
    public string? ManagerName { get; set; }
    public string VerificationStatus { get; set; } = string.Empty;
    public DateTime RaisedOn { get; set; }
    public int? RefreshRunId { get; set; }
    public string? ResolvedAction { get; set; }
    public string? ResolvedBy { get; set; }
    public string? ResolvedByName { get; set; }
    public DateTime? ResolvedOn { get; set; }
    public string? ResolutionNote { get; set; }
}

public sealed class ArWorkbenchStatusVerificationQueue
{
    public int Pending { get; set; }
    /// <summary>Pending and routed to the caller.</summary>
    public int PendingMine { get; set; }
    /// <summary>Pending and routed to no manager in particular (no RCM Manager was on file).</summary>
    public int PendingUnrouted { get; set; }
    public int ResolvedLast30Days { get; set; }
    public List<ArWorkbenchStatusVerificationRow> Rows { get; set; } = new();
    public bool Truncated { get; set; }
}

/// <summary>POST status-verification/resolve.</summary>
public sealed class ArWorkbenchStatusVerificationResolve
{
    public List<long>? ClaimKeys { get; set; }
    /// <summary>ReturnToAgent | Unassign | Complete</summary>
    public string? Action { get; set; }
    public string? Note { get; set; }
}

public sealed class ArWorkbenchStatusVerificationResolveResult
{
    public int Resolved { get; set; }
    /// <summary>Not pending any more, out of scope or not found - left as they were.</summary>
    public int Skipped { get; set; }
    public string Message { get; set; } = string.Empty;
}

public sealed class ArWorkbenchNotification
{
    public long NotificationId { get; set; }
    public long? ClaimKey { get; set; }
    public string? ClaimID { get; set; }
    public string NotificationType { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
    public DateTime CreatedOn { get; set; }
    public bool IsRead { get; set; }
    /// <summary>Addressed to the caller's role rather than to them by name.</summary>
    public bool IsRoleBroadcast { get; set; }
}

public sealed class ArWorkbenchNotificationList
{
    public int UnreadCount { get; set; }
    public List<ArWorkbenchNotification> Items { get; set; } = new();
}

/// <summary>
/// Claims export: the workflow columns beside each claim - assignment, the latest follow-up note as
/// the agent / manager logged it, its QA review, and the latest status change verification.
/// </summary>
public sealed class ArWorkbenchClaimExportDetail
{
    // Claim-level source columns (QC 10.12.2026 "Missing Columns")
    public string? AccessionNumber { get; set; }
    public DateTime? PatientDOB { get; set; }
    public string? SubscriberId { get; set; }
    public string? BillingProvider { get; set; }
    public DateTime? ChargeEnteredDate { get; set; }
    public DateTime? FirstBilledDate { get; set; }
    public string? CptSummary { get; set; }
    public string? Facility { get; set; }
    public string? POS { get; set; }
    public string? TOS { get; set; }
    public string? ICDCode { get; set; }
    public decimal AllowedAmount { get; set; }
    public decimal InsurancePayment { get; set; }
    public decimal PatientPayment { get; set; }
    public decimal TotalPayments { get; set; }
    public decimal InsuranceAdjustments { get; set; }
    public decimal PatientAdjustments { get; set; }
    public decimal TotalAdjustments { get; set; }
    public decimal TotalBalance { get; set; }
    public DateTime? CheckDate { get; set; }
    public string? BillStatus { get; set; }
    /// <summary>Every follow-up note on the claim, newest first, one per line.</summary>
    public string? Notes { get; set; }

    public string? AssignedBy { get; set; }
    public DateTime? AssignedOn { get; set; }
    public int FollowUpCount { get; set; }
    // Latest follow-up note (Log Follow-Up Note pop-up)
    public string? ClaimType { get; set; }
    public string? FollowUpType { get; set; }
    public string? FollowUpClaimStatus { get; set; }
    public string? DenialRootCause { get; set; }
    public string? FixResolution { get; set; }
    public string? FollowUpComment { get; set; }
    public DateTime? NextFollowUpDate { get; set; }
    public string? CipCategory { get; set; }
    public string? CipRequiredInfo { get; set; }
    public string? CipComment { get; set; }
    public string? FollowUpBy { get; set; }
    public string? FollowUpByRole { get; set; }
    public DateTime? FollowUpOn { get; set; }
    // Current QA review (reviewer / manager decision on that note)
    public string? QaStatus { get; set; }
    public string? QaReviewedBy { get; set; }
    public string? QaReviewedByRole { get; set; }
    public DateTime? QaReviewedOn { get; set; }
    public string? QaErrorType { get; set; }
    public string? QaComment { get; set; }
    // Latest status change verification (RCM Manager)
    public string? VerificationStatus { get; set; }
    public string? VerificationChange { get; set; }
    public string? VerificationManager { get; set; }
    public string? VerificationAction { get; set; }
    public string? VerificationBy { get; set; }
    public DateTime? VerificationOn { get; set; }
    public string? VerificationComment { get; set; }
}

/// <summary>POST notifications/read: the ids, or All = every notification of the caller.</summary>
public sealed class ArWorkbenchNotificationReadRequest
{
    public List<long>? NotificationIds { get; set; }
    public bool All { get; set; }
}
