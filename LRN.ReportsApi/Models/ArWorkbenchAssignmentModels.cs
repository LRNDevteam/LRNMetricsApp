namespace LRN.ReportsApi.Models;

// ============================================================================================
// AR Workbench - Assignment Management (/api/ar-workbench/assignment/*). Named batches with a
// running log (dbo.ARWB_AssignmentBatch / dbo.ARWB_AssignmentBatchClaim) and bulk assign /
// reassign, following the mockup's App.views.assignment and App.actions.assignClaim.
// ============================================================================================

/// <summary>A user who can be given claims: an AR Agent or Team Lead with access to the lab, plus their live workload.</summary>
public sealed class ArWorkbenchAgent
{
    public string UserName { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    /// <summary>agent | lead; empty for a user who holds claims but can no longer be assigned any.</summary>
    public string RoleCode { get; set; } = string.Empty;
    public string RoleLabel { get; set; } = string.Empty;
    public bool IsAssignable { get; set; }
    /// <summary>Not work-complete and still carrying an open insurance balance (the mockup's Agent Workload).</summary>
    public int OpenClaims { get; set; }
    public decimal OpenInsuranceAR { get; set; }
    public int AwaitingQa { get; set; }
    public int TotalAssigned { get; set; }
}

/// <summary>Which unassigned, open-balance claims a batch takes. An empty list means "any".</summary>
public sealed class ArWorkbenchBatchCriteria
{
    public List<string> Category { get; set; } = new();
    public List<string> Payer { get; set; } = new();
    public List<string> Panel { get; set; } = new();
    public List<string> Priority { get; set; } = new();
    public List<string> Clinic { get; set; } = new();
    public List<string> Aging { get; set; } = new();
    public bool TflRiskOnly { get; set; }

    public bool IsEmpty => Category.Count + Payer.Count + Panel.Count + Priority.Count + Clinic.Count + Aging.Count == 0 && !TflRiskOnly;

    /// <summary>Lists bound as null become empty; values are trimmed, de-duplicated and capped.</summary>
    public ArWorkbenchBatchCriteria Clean()
    {
        static List<string> C(List<string>? v) => (v ?? [])
            .Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(ArWorkbenchClaimFilter.MaxValuesPerFilter).ToList();
        return new ArWorkbenchBatchCriteria
        {
            Category = C(Category), Payer = C(Payer), Panel = C(Panel), Priority = C(Priority), Clinic = C(Clinic), Aging = C(Aging),
            TflRiskOnly = TflRiskOnly
        };
    }
}

public sealed class ArWorkbenchBatchPreviewRequest
{
    public ArWorkbenchBatchCriteria Criteria { get; set; } = new();
}

public sealed class ArWorkbenchBatchPreview
{
    public int ClaimCount { get; set; }
    public decimal TotalInsuranceAR { get; set; }
    public int TflRiskCount { get; set; }
    public int HighPriorityCount { get; set; }
}

public sealed class ArWorkbenchBatchCreateRequest
{
    public string? BatchName { get; set; }
    public string? AgentUser { get; set; }
    public DateTime? DueDate { get; set; }
    public string? Note { get; set; }
    public ArWorkbenchBatchCriteria Criteria { get; set; } = new();
    /// <summary>Optional cap: assign only the N highest-AR matching claims (null = all of them).</summary>
    public int? MaxClaims { get; set; }
}

public sealed class ArWorkbenchAssignRequest
{
    public List<long> ClaimKeys { get; set; } = new();
    public string? AgentUser { get; set; }
    public string? Note { get; set; }
    public DateTime? DueDate { get; set; }
}

public sealed class ArWorkbenchAssignResult
{
    public int AssignedCount { get; set; }
    public int ReassignedCount { get; set; }
    /// <summary>Already with that agent: nothing changed.</summary>
    public int UnchangedCount { get; set; }
    /// <summary>Requested but not found or outside the caller's scope.</summary>
    public int SkippedCount { get; set; }
    /// <summary>No open insurance balance: assigned ad hoc (the claim still reaches the agent's follow-up list).</summary>
    public int AdHocCount { get; set; }
    public int ResolvedRequestCount { get; set; }
    public int? AssignmentBatchId { get; set; }
    public string? BatchNumber { get; set; }
    public string Message { get; set; } = string.Empty;
}

public sealed class ArWorkbenchBatch
{
    public int AssignmentBatchId { get; set; }
    public string BatchNumber { get; set; } = string.Empty;
    public string BatchName { get; set; } = string.Empty;
    public string AgentUser { get; set; } = string.Empty;
    public string? AgentName { get; set; }
    public DateTime? DueDate { get; set; }
    public ArWorkbenchBatchCriteria? Criteria { get; set; }
    public string CriteriaSummary { get; set; } = string.Empty;
    public int ClaimCount { get; set; }
    public decimal TotalInsuranceAR { get; set; }
    /// <summary>Remaining AR now, over the batch's claims.</summary>
    public decimal RemainingAR { get; set; }
    public int CompletedCount { get; set; }
    /// <summary>Claims since moved to another agent.</summary>
    public int ReassignedAwayCount { get; set; }
    public int CompletionPct { get; set; }
    /// <summary>Open | Completed | Cancelled (Completed once every claim's work is complete).</summary>
    public string BatchStatus { get; set; } = string.Empty;
    public bool IsOverdue { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime CreatedOn { get; set; }
}

public sealed class ArWorkbenchBatchClaim
{
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? PayerName { get; set; }
    public string? DenialCategory { get; set; }
    public string? Priority { get; set; }
    public decimal InsuranceARAtAssignment { get; set; }
    public decimal RemainingAR { get; set; }
    public string WorkflowStatus { get; set; } = string.Empty;
    public bool IsWorkComplete { get; set; }
    public string? CurrentAgentUser { get; set; }
    public string? CurrentAgentName { get; set; }
    public string? PreviousAgentUser { get; set; }
    public DateTime? LastFollowUpDate { get; set; }
}

public sealed class ArWorkbenchBatchLogEntry
{
    public DateTime ActivityOn { get; set; }
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string ActionType { get; set; } = string.Empty;
    public string? Detail { get; set; }
    public string UserName { get; set; } = string.Empty;
    public bool IsSystem { get; set; }
}

public sealed class ArWorkbenchBatchDetail
{
    public ArWorkbenchBatch Batch { get; set; } = new();
    public List<ArWorkbenchBatchClaim> Claims { get; set; } = new();
    public List<ArWorkbenchBatchLogEntry> Log { get; set; } = new();
}

/// <summary>The Assignment Management screen's header data.</summary>
public sealed class ArWorkbenchAssignmentOverview
{
    public List<ArWorkbenchAgent> Agents { get; set; } = new();
    /// <summary>Unassigned claims with an open insurance balance - the pool a batch draws from.</summary>
    public int UnassignedOpenCount { get; set; }
    public decimal UnassignedOpenAR { get; set; }
    /// <summary>Of those, untouched for UntouchedDays or more (the Unassigned Claims table).</summary>
    public int UnassignedStaleCount { get; set; }
    public int AssignedOpenCount { get; set; }
    public int UntouchedDays { get; set; }
    public int OpenBatchCount { get; set; }
    public int PendingReassignmentRequests { get; set; }
    /// <summary>Option lists with counts, over the unassigned open pool, for the batch criteria.</summary>
    public ArWorkbenchFilterOptions PoolOptions { get; set; } = new();
}
