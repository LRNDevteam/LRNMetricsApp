namespace LRN.ReportsApi.Models;

// ============================================================================================
// AR Workbench - DTOs for /api/ar-workbench. Backed by the [arwb] schema in each lab database
// (LRN.ReportsApi/Sql/ArWorkbench).
// ============================================================================================

public sealed class ArWorkbenchPermissions
{
    public bool Assign { get; set; }
    public bool EditClaim { get; set; }
    public bool QaDecide { get; set; }
    public bool Approve { get; set; }
    public bool ManageUsers { get; set; }
    public bool ViewAudit { get; set; }
    public bool ManageSettings { get; set; }
    public bool AllClients { get; set; }
    public bool ViewClientMgmt { get; set; }
}

/// <summary>Normalized access grant: level is all | client | clinic | provider.</summary>
public sealed class ArWorkbenchAccessScope
{
    public string Level { get; set; } = "all";
    public string? Client { get; set; }
    public string? Clinic { get; set; }
    public string? Provider { get; set; }
}

/// <summary>
/// The signed-in user as the workbench sees them, built from LRNMaster: dbo.LabUsers (who), their
/// "AR Workbench - ..." roles (RoleNames), dbo.RoleFeatureAccess 'ARWorkbench.*' (Permissions) and
/// dbo.ARWorkbenchUserScope (Access). RoleCode is derived from the combined permissions.
/// </summary>
public sealed class ArWorkbenchUserContext
{
    public int LabId { get; set; }
    public int? LabUserId { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    /// <summary>admin | manager | lead | agent | qa | viewer - drives navigation and own-caseload scoping.</summary>
    public string RoleCode { get; set; } = string.Empty;
    /// <summary>The user's AR Workbench role name(s) without the "AR Workbench - " prefix, for display.</summary>
    public string RoleLabel { get; set; } = string.Empty;
    public List<string> RoleNames { get; set; } = new();
    /// <summary>True for Super Admin / Admin / LRN Admin / Lab Admin: every page opens, whatever the RoleCode's menu.</summary>
    public bool SiteAdmin { get; set; }
    public ArWorkbenchPermissions Permissions { get; set; } = new();
    public ArWorkbenchAccessScope Access { get; set; } = new();
}

public sealed class ArWorkbenchQueueNode
{
    public string QueueId { get; set; } = string.Empty;
    public string? ParentQueueId { get; set; }
    public string Label { get; set; } = string.Empty;
    public bool IsPriority { get; set; }
    public int SortOrder { get; set; }
    public string? BadgeClass { get; set; }
    public int ClaimCount { get; set; }
    public decimal RemainingAR { get; set; }
    public List<ArWorkbenchQueueNode> Sub { get; set; } = new();
}

public sealed class ArWorkbenchQueueSummary
{
    public int TotalClaims { get; set; }
    public decimal TotalInitialAR { get; set; }
    public decimal TotalRecovered { get; set; }
    public decimal TotalRemainingAR { get; set; }
    public int UnassignedOpen { get; set; }
    public int AwaitingQa { get; set; }
    public int RefollowupDue { get; set; }
    public List<ArWorkbenchQueueNode> Queues { get; set; } = new();
}

// ============================================================================================
// Dashboard - the mockup's System Administrator dashboard (docs/Denial_WorkFlow/
// LRN_Denial_AR_Workbench_Demo_Account.html, App.views.dashboard), every figure computed in SQL
// over the caller's scoped claims.
// ============================================================================================

public sealed class ArWorkbenchDashboard
{
    // KPI tiles
    public int TotalClaims { get; set; }
    /// <summary>Claims first billed in the last 7 days / the 7 days before - the "identified this wk" delta.</summary>
    public int IdentifiedThisWeek { get; set; }
    public int IdentifiedLastWeek { get; set; }
    public decimal TotalOutstandingAR { get; set; }
    public DateTime? DataRefreshedOn { get; set; }
    public DateTime? SourcePeriodStart { get; set; }
    public DateTime? SourcePeriodEnd { get; set; }
    public int Unassigned { get; set; }
    public int InProgress { get; set; }
    public int AwaitingQa { get; set; }
    public int QaRejected { get; set; }
    public int Completed { get; set; }
    public decimal TotalRecovered { get; set; }
    public decimal PotentialRecovery { get; set; }
    public int OverdueFollowUps { get; set; }
    public decimal TotalInitialAR { get; set; }
    public int Worked { get; set; }

    // Charts
    public List<ArWorkbenchDashboardBar> DenialCategories { get; set; } = new();
    public List<ArWorkbenchDashboardBar> AgingBuckets { get; set; } = new();
    public List<ArWorkbenchDashboardBar> WorkflowStatuses { get; set; } = new();
    /// <summary>Workable AR Queue leaves (not Closed / Patient AR) with an open insurance balance.</summary>
    public List<ArWorkbenchDashboardBar> QueueVolumes { get; set; } = new();
    /// <summary>AR Collections Progress: per top-level AR queue, revenue expectation (initial insurance AR) and count.</summary>
    public List<ArWorkbenchDashboardBar> ArProgress { get; set; } = new();

    // Tables
    public List<ArWorkbenchDenialHighlight> DenialHighlights { get; set; } = new();
    public List<ArWorkbenchAgentProductivity> Agents { get; set; } = new();
}

/// <summary>One bar. Key is what the Work Queue filters on (queue|sub, status, category); null when it cannot drill.</summary>
public sealed class ArWorkbenchDashboardBar
{
    public string Label { get; set; } = string.Empty;
    public string? Key { get; set; }
    public int Count { get; set; }
    public decimal Amount { get; set; }
}

public sealed class ArWorkbenchDenialHighlight
{
    public string Code { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int Count { get; set; }
    public decimal Balance { get; set; }
    public string? TopPayer { get; set; }
    public decimal TopPayerBalance { get; set; }
    public decimal ImpactPct { get; set; }
    public string Observation { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
}

public sealed class ArWorkbenchAgentProductivity
{
    public string UserName { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public int Assigned { get; set; }
    public int Completed { get; set; }
    public int AwaitingReview { get; set; }
    public decimal Recovery { get; set; }
}

/// <summary>
/// Work Queue filters. Every list is a multi-select (the mockup's filter popovers): repeat the query
/// key per value (?payer=A&amp;payer=B). An empty list means "All".
/// </summary>
public sealed class ArWorkbenchClaimFilter
{
    public const int MaxValuesPerFilter = 100;
    /// <summary>The value for "no agent" in <see cref="Agent"/>.</summary>
    public const string UnassignedAgent = "__unassigned";

    public int LabId { get; set; }
    /// <summary>"queueId" for a whole top-level queue, or "queueId|subQueueId" for one sub-queue.</summary>
    public List<string> Queue { get; set; } = new();
    public List<string> Status { get; set; } = new();
    public List<string> Payer { get; set; } = new();
    public List<string> Category { get; set; } = new();
    public List<string> Agent { get; set; } = new();
    public List<string> Priority { get; set; } = new();
    public List<string> Aging { get; set; } = new();
    public List<string> Panel { get; set; } = new();
    public List<string> Clinic { get; set; } = new();
    public string? Search { get; set; }
    public bool OpenInsuranceArOnly { get; set; }
    public bool TflRiskOnly { get; set; }
    /// <summary>Only claims that have an agent (Assignment Management's reassign table, My Work).</summary>
    public bool AssignedOnly { get; set; }
    /// <summary>Only claims waiting on the agent's next touch (dbo.ARWB_Claim.IsFollowUpActionable) - Follow-Up Management.</summary>
    public bool FollowUpActionableOnly { get; set; }
    /// <summary>Not financially closed.</summary>
    public bool ActiveOnly { get; set; }
    /// <summary>Only claims with a non-collectible denial code anywhere on the claim.</summary>
    public bool NonCollectibleOnly { get; set; }
    /// <summary>Next follow-up date window: overdue | today | upcoming | none.</summary>
    public string? FollowUpWindow { get; set; }
    /// <summary>My Work quick filter: fix / resolution of the last note is one that waits on the payer.</summary>
    public bool AwaitingPayerOnly { get; set; }
    public List<string> FixResolution { get; set; } = new();
    /// <summary>The ingested source claim status (Fully Denied / Partially Paid / ...).</summary>
    public List<string> SourceStatus { get; set; } = new();
    /// <summary>Only claims with no activity for at least this many days (never-touched claims count).</summary>
    public int? MinDaysUntouched { get; set; }
    public string? SortBy { get; set; }
    public bool SortDesc { get; set; } = true;
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public sealed class ArWorkbenchClaimRow
{
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? LabName { get; set; }
    public string? PatientID { get; set; }
    public string? PatientName { get; set; }
    public string? FirstCptCode { get; set; }
    public int LineCount { get; set; }
    public string? DenialReason { get; set; }
    public string? SourceClaimStatus { get; set; }
    public string? FixResolution { get; set; }
    public DateTime? LastFollowUpDate { get; set; }
    public string? PayerName { get; set; }
    public string? PayerType { get; set; }
    public string? ClinicName { get; set; }
    public string? ReferringProvider { get; set; }
    public string? PanelName { get; set; }
    public DateTime? DateOfService { get; set; }
    public string? DenialCode { get; set; }
    public string? DenialCategory { get; set; }
    public decimal ChargeAmount { get; set; }
    public decimal InsuranceBalance { get; set; }
    public decimal PatientBalance { get; set; }
    public decimal InitialInsuranceAR { get; set; }
    /// <summary>Expected payment: the fee-schedule allowable over the claim's lines (handoff section 7).</summary>
    public decimal RevenueExpectation { get; set; }
    public decimal RecoveredAmount { get; set; }
    public decimal RemainingAR { get; set; }
    public string WorkflowStatus { get; set; } = string.Empty;
    public string? Priority { get; set; }
    public string? AssignedAgentUser { get; set; }
    public string? AssignedAgentName { get; set; }
    public DateTime? NextFollowUpDate { get; set; }
    public int? AgingDays { get; set; }
    public string? AgingBucket { get; set; }
    public bool IsTflRisk { get; set; }
    public bool IsNonCollectible { get; set; }
    /// <summary>Any denial code on the claim (not only the primary) is on the lab's Non-Collectible list.</summary>
    public bool HasNonCollectibleDenial { get; set; }
    public string? ArQueueId { get; set; }
    public string? ArQueueLabel { get; set; }
    public string? ArQueueBadgeClass { get; set; }
    public string? ArSubQueueId { get; set; }
    public string? ArSubQueueLabel { get; set; }
    public int? DaysSinceLastTouch { get; set; }
    public string? QaStatus { get; set; }
    public int OpenCipCases { get; set; }
    public int PendingAgentRequests { get; set; }
}

public static class ArWorkbenchFilterValues
{
    /// <summary>The value for a blank payer / panel / clinic / denial category in a list filter.</summary>
    public const string None = "__none";
}

/// <summary>Option lists for the Work Queue filter popovers, from the caller's scoped claims.</summary>
public sealed class ArWorkbenchFilterOptions
{
    public List<ArWorkbenchFilterOption> Queues { get; set; } = new();
    public List<ArWorkbenchFilterOption> Payers { get; set; } = new();
    public List<ArWorkbenchFilterOption> Panels { get; set; } = new();
    public List<ArWorkbenchFilterOption> Clinics { get; set; } = new();
    public List<ArWorkbenchFilterOption> Categories { get; set; } = new();
    public List<ArWorkbenchFilterOption> Statuses { get; set; } = new();
    public List<ArWorkbenchFilterOption> Agents { get; set; } = new();
    public List<ArWorkbenchFilterOption> Priorities { get; set; } = new();
    public List<ArWorkbenchFilterOption> AgingBuckets { get; set; } = new();
    public List<ArWorkbenchFilterOption> FixResolutions { get; set; } = new();
    public List<ArWorkbenchFilterOption> SourceStatuses { get; set; } = new();
}

/// <summary>Tile counts for My Work and Follow-Up Management, over the caller's scope.</summary>
public sealed class ArWorkbenchWorkSummary
{
    // My Work: every assigned claim (an agent's own, a lead's whole team)
    public int TotalAssigned { get; set; }
    public int DueToday { get; set; }
    public int Overdue { get; set; }
    public int HighPriority { get; set; }
    public int RefollowupRequired { get; set; }
    public int CipResponseReceived { get; set; }
    public int AwaitingPayer { get; set; }
    public int SubmittedForQa { get; set; }
    public int QaRejected { get; set; }

    // Follow-Up Management: claims waiting on the next touch
    public int ActionableAll { get; set; }
    public int ActionableOverdue { get; set; }
    public int ActionableDueToday { get; set; }
    public int ActionableUpcoming { get; set; }
    public int ActionableNoFollowUp { get; set; }
}

public sealed class ArWorkbenchFilterOption
{
    public string Value { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public int Count { get; set; }
}

public sealed class ArWorkbenchPagedResult<T>
{
    public int Page { get; set; }
    public int PageSize { get; set; }
    public int TotalCount { get; set; }
    public List<T> Items { get; set; } = new();
}

public sealed class ArWorkbenchClaimLine
{
    public int LineNumber { get; set; }
    public string? CPTCode { get; set; }
    public decimal? Units { get; set; }
    public string? Modifier { get; set; }
    public decimal ChargeAmount { get; set; }
    public decimal AllowedAmount { get; set; }
    public decimal InsurancePayment { get; set; }
    public decimal InsuranceAdjustments { get; set; }
    public decimal InsuranceBalance { get; set; }
    public decimal PatientBalance { get; set; }
    public string? LineClaimStatus { get; set; }
    public string? PayStatus { get; set; }
    public string? DenialCode { get; set; }
    public DateTime? DenialDate { get; set; }
    public string? ICDCode { get; set; }
}

public sealed class ArWorkbenchActivity
{
    public long ActivityId { get; set; }
    public DateTime ActivityOn { get; set; }
    public string ActionType { get; set; } = string.Empty;
    public string? Detail { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string? RoleCode { get; set; }
    public bool IsSystem { get; set; }
}

public sealed class ArWorkbenchFollowUp
{
    public long FollowUpId { get; set; }
    public string? ClaimType { get; set; }
    public string? FollowUpType { get; set; }
    public string FollowUpClaimStatus { get; set; } = string.Empty;
    public string? DenialRootCause { get; set; }
    public string FixResolution { get; set; } = string.Empty;
    public string? FollowUpComment { get; set; }
    public DateTime? NextFollowUpDate { get; set; }
    public string CreatedBy { get; set; } = string.Empty;
    public DateTime CreatedOn { get; set; }
}

public sealed class ArWorkbenchTemplateStage
{
    public int StageOrder { get; set; }
    public string StageName { get; set; } = string.Empty;
}

public sealed class ArWorkbenchClaimDetail
{
    /// <summary>Every column of dbo.ARWB_vw_ClaimWorklist, keyed by column name.</summary>
    public Dictionary<string, object?> Claim { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public string? WorkflowTemplateLabel { get; set; }
    public List<ArWorkbenchTemplateStage> WorkflowStages { get; set; } = new();
    public List<ArWorkbenchClaimLine> Lines { get; set; } = new();
    public List<ArWorkbenchActivity> Activity { get; set; } = new();
    public List<ArWorkbenchFollowUp> FollowUps { get; set; } = new();
    /// <summary>Central Denial Code Master rows for the claim's primary and line-level codes.</summary>
    public List<ArWorkbenchCodeMasterRow> DenialCodeInfo { get; set; } = new();
}

public sealed class ArWorkbenchMasterData
{
    /// <summary>ListType -> active values in sort order (DENIAL_CATEGORY, FIX_RESOLUTION, ...).</summary>
    public Dictionary<string, List<string>> Lists { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, List<string>> FixResolutionsByStatus { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> Settings { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class ArWorkbenchRefreshRun
{
    public int RefreshRunId { get; set; }
    public string? SourceRunId { get; set; }
    public string? SourceFileName { get; set; }
    public DateTime? SourcePeriodStart { get; set; }
    public DateTime? SourcePeriodEnd { get; set; }
    public string RunStatus { get; set; } = string.Empty;
    public DateTime StartedOn { get; set; }
    public DateTime? CompletedOn { get; set; }
    public int? SourceClaimRows { get; set; }
    public int? SourceLineRows { get; set; }
    public int? ClaimsInserted { get; set; }
    public int? ClaimsUpdated { get; set; }
    public int? ClaimsUnchanged { get; set; }
    public int? ClaimsNoLongerInSource { get; set; }
    public int? ClaimsLinesReloaded { get; set; }
    public string? RunBy { get; set; }
    public string? ErrorMessage { get; set; }
}
