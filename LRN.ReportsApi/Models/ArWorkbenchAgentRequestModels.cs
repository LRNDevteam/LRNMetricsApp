namespace LRN.ReportsApi.Models;

// ============================================================================================
// Escalation & Reassignment Requests (mockup App.views['agent-requests']): an AR agent's
// "Escalate to Supervisor" / "Request Reassignment" on a claim (dbo.ARWB_AgentRequest), answered
// by a Team Lead, RCM Manager or System Administrator. Internal only - never a CIP.
// ============================================================================================

/// <summary>POST claims/{claimKey}/agent-requests.</summary>
public sealed class ArWorkbenchAgentRequestCreate
{
    /// <summary>escalation | reassignment</summary>
    public string? RequestType { get; set; }
    /// <summary>From Master Values: ESCALATION_REASON / REASSIGNMENT_REASON.</summary>
    public string? ReasonCategory { get; set; }
    public string? Note { get; set; }
}

/// <summary>POST agent-requests/resolve: one shared note for one or many pending requests.</summary>
public sealed class ArWorkbenchAgentRequestResolve
{
    public List<long>? RequestIds { get; set; }
    public string? Note { get; set; }
}

public sealed class ArWorkbenchAgentRequestResolveResult
{
    public int Resolved { get; set; }
    /// <summary>Already resolved, out of scope or not found - left as they were.</summary>
    public int Skipped { get; set; }
    public string Message { get; set; } = string.Empty;
}

public sealed class ArWorkbenchAgentRequestFilter
{
    public int LabId { get; set; }
    public string? Search { get; set; }
    /// <summary>Escalation to Supervisor | Reassignment Request</summary>
    public List<string> Type { get; set; } = new();
    /// <summary>Pending | Resolved</summary>
    public List<string> Status { get; set; } = new();
    public List<string> Payer { get; set; } = new();
    /// <summary>The claim's current assigned agent (user name).</summary>
    public List<string> Agent { get; set; } = new();
    public List<string> RequestedBy { get; set; } = new();
    /// <summary>Top-level AR queue id.</summary>
    public List<string> Queue { get; set; } = new();
}

public sealed class ArWorkbenchAgentRequestRow
{
    public long AgentRequestId { get; set; }
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? LabName { get; set; }
    public string? PayerName { get; set; }
    public string? AssignedAgentUser { get; set; }
    public string? AssignedAgentName { get; set; }
    public decimal InsuranceBalance { get; set; }
    public string? ArQueueId { get; set; }
    public string? ArQueueLabel { get; set; }
    public string? WorkflowStatus { get; set; }
    public string RequestType { get; set; } = string.Empty;
    public string ReasonCategory { get; set; } = string.Empty;
    public string RequestNote { get; set; } = string.Empty;
    public string RequestedBy { get; set; } = string.Empty;
    public string? RequestedByName { get; set; }
    public string? RequestedByRole { get; set; }
    public DateTime RequestedOn { get; set; }
    public string RequestStatus { get; set; } = string.Empty;
    public string? ResolvedBy { get; set; }
    public string? ResolvedByName { get; set; }
    public DateTime? ResolvedOn { get; set; }
    public string? ResolutionNote { get; set; }
    public bool IsBulk { get; set; }
}

public sealed class ArWorkbenchAgentRequestQueue
{
    public int PendingEscalations { get; set; }
    public int PendingReassignments { get; set; }
    public int Resolved { get; set; }
    public int Total { get; set; }
    /// <summary>Matching requests, pending first then newest; at most MaxRows.</summary>
    public List<ArWorkbenchAgentRequestRow> Rows { get; set; } = new();
    public bool Truncated { get; set; }
    public List<ArWorkbenchFilterOption> Payers { get; set; } = new();
    public List<ArWorkbenchFilterOption> Agents { get; set; } = new();
    public List<ArWorkbenchFilterOption> RequestedBy { get; set; } = new();
    public List<ArWorkbenchFilterOption> Queues { get; set; } = new();
}
