namespace LRN.ReportsApi.Models;

// ============================================================================================
// AR Workbench - Master File Maintenance DTOs (/api/ar-workbench/masters and /denial-codes).
// The lists live in dbo.ARWB_MasterListItem and the code map in dbo.ARWB_DenialCodeCategoryMap,
// both in the lab database. The rules mirror the Denial Workflow's Workflow Master Values and
// Denial Code Master screens (WorkflowMasterValueRules, DenialCodeMasterController).
// ============================================================================================

public sealed class ArWorkbenchMasterValuesResponse
{
    public List<ArWorkbenchMasterList> Lists { get; set; } = new();
}

public sealed class ArWorkbenchMasterList
{
    public string Type { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public int MaxLength { get; set; }
    /// <summary>True for the denial-code lists: values are stored as normalized codes (CO-197 -> 197).</summary>
    public bool IsCodeList { get; set; }
    public string? FormatHint { get; set; }
    /// <summary>What the usage count counts, e.g. "follow-up notes"; null when the list has no usage count.</summary>
    public string? UsageLabel { get; set; }
    /// <summary>Values the workbench's own rules depend on. They cannot be renamed, deactivated or deleted.</summary>
    public List<string> ReservedValues { get; set; } = new();
    public List<ArWorkbenchMasterValue> Values { get; set; } = new();
}

public sealed class ArWorkbenchMasterValue
{
    public string Value { get; set; } = string.Empty;
    public int SortOrder { get; set; }
    public bool IsActive { get; set; }
    public int UsageCount { get; set; }
    public DateTime? CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }
}

public sealed class ArWorkbenchMasterValueSaveRequest
{
    /// <summary>The value being edited (update only). Sent in the body because values contain slashes.</summary>
    public string? OriginalValue { get; set; }
    public string? Value { get; set; }
    /// <summary>Null on add places the value last; null on edit keeps the current order.</summary>
    public int? SortOrder { get; set; }
    public bool IsActive { get; set; } = true;
}

// ---- Denial Code Master (dbo.ARWB_DenialCodeCategoryMap) ------------------------------------

public sealed class ArWorkbenchDenialCodeQuery
{
    public int LabId { get; set; }
    public string? Search { get; set; }
    /// <summary>all | active | inactive</summary>
    public string? Status { get; set; }
    public string? Category { get; set; }
    public string? SortBy { get; set; }
    public bool SortDesc { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class ArWorkbenchDenialCodeRow
{
    public string DenialCode { get; set; } = string.Empty;
    public string DenialCategory { get; set; } = string.Empty;
    public string? DenialReason { get; set; }
    /// <summary>The lab's Denial Workflow dbo.DenialCodeMaster description, which the claim sync prefers over DenialReason.</summary>
    public string? WorkflowDescription { get; set; }
    public bool IsActive { get; set; }
    /// <summary>Synced claims whose primary denial is this code.</summary>
    public int ClaimCount { get; set; }
    public DateTime? CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }
}

public sealed class ArWorkbenchDenialCodeSaveRequest
{
    /// <summary>The code being edited (update only).</summary>
    public string? OriginalDenialCode { get; set; }
    public string? DenialCode { get; set; }
    public string? DenialCategory { get; set; }
    public string? DenialReason { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>A primary denial code on synced claims with no active row in the code map (they land in 'Other').</summary>
public sealed class ArWorkbenchUnmappedDenialCode
{
    public string DenialCode { get; set; } = string.Empty;
    public string? SampleRawCode { get; set; }
    public string? DenialReason { get; set; }
    public int ClaimCount { get; set; }
    public decimal RemainingAR { get; set; }
    /// <summary>The code has a map row, but it is inactive.</summary>
    public bool HasInactiveMapping { get; set; }
}

public sealed class ArWorkbenchDenialCodeImpactQueue
{
    public string QueueLabel { get; set; } = string.Empty;
    public int ClaimCount { get; set; }
    public int AssignedCount { get; set; }
}

public sealed class ArWorkbenchDenialCodeImpact
{
    public string DenialCode { get; set; } = string.Empty;
    public string? CurrentCategory { get; set; }
    public int AffectedClaims { get; set; }
    public int AssignedClaims { get; set; }
    /// <summary>Claims whose category was set by hand; the claim sync keeps their category.</summary>
    public int ManualCategoryClaims { get; set; }
    public int AffectedLines { get; set; }
    public List<ArWorkbenchDenialCodeImpactQueue> Queues { get; set; } = new();
}

public sealed class ArWorkbenchDenialCodeImportResult
{
    public int InsertedCount { get; set; }
    public int UpdatedCount { get; set; }
    public int UnchangedCount { get; set; }
    public int SkippedCount { get; set; }
    public int MergedDuplicateCount { get; set; }
    public int FailedCount { get; set; }
    public List<string> Errors { get; set; } = new();
}
