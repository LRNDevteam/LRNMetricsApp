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

public sealed class ArWorkbenchClaimFilter
{
    public int LabId { get; set; }
    public string? QueueId { get; set; }
    public string? SubQueueId { get; set; }
    public string? WorkflowStatus { get; set; }
    public string? Payer { get; set; }
    public string? DenialCategory { get; set; }
    public string? AssignedAgent { get; set; }
    public string? Search { get; set; }
    public bool OpenInsuranceArOnly { get; set; }
    public string? SortBy { get; set; }
    public bool SortDesc { get; set; } = true;
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public sealed class ArWorkbenchClaimRow
{
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? PatientName { get; set; }
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
    /// <summary>Every column of arwb.vw_ClaimWorklist, keyed by column name.</summary>
    public Dictionary<string, object?> Claim { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public string? WorkflowTemplateLabel { get; set; }
    public List<ArWorkbenchTemplateStage> WorkflowStages { get; set; } = new();
    public List<ArWorkbenchClaimLine> Lines { get; set; } = new();
    public List<ArWorkbenchActivity> Activity { get; set; } = new();
    public List<ArWorkbenchFollowUp> FollowUps { get; set; } = new();
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
