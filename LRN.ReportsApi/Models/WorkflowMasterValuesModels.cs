namespace LRN.ReportsApi.Models;

/// <summary>
/// One of the seven workflow master lists, with every value in it (inactive ones included, so an
/// admin can switch them back on) and how many active Super Master mappings use each.
/// </summary>
public sealed class WorkflowMasterList
{
    public string Type { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;

    /// <summary>Action Category is the only list whose values carry a second field.</summary>
    public bool HasActionCode { get; set; }

    public int MaxLength { get; set; }
    public string? FormatHint { get; set; }
    public IReadOnlyList<WorkflowMasterValue> Values { get; set; } = Array.Empty<WorkflowMasterValue>();
}

public sealed class WorkflowMasterValue
{
    public string Value { get; set; } = string.Empty;
    public string? ActionCode { get; set; }
    public int SortOrder { get; set; }
    public bool IsActive { get; set; }

    /// <summary>
    /// Active Super Master mappings that store this exact text. Those rows keep the text they were
    /// saved with, so a value in use cannot be renamed or deleted — only deactivated.
    /// </summary>
    public int UsageCount { get; set; }

    public DateTime? CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? ModifiedOn { get; set; }
    public string? ModifiedBy { get; set; }
}

public sealed class WorkflowMasterValuesResponse
{
    public IReadOnlyList<WorkflowMasterList> Lists { get; set; } = Array.Empty<WorkflowMasterList>();

    /// <summary>False when dbo.DenialMapperSuperMaster does not exist yet; usage counts are then all zero.</summary>
    public bool UsageAvailable { get; set; }
}

public sealed class WorkflowMasterValueSaveRequest
{
    /// <summary>The value being edited, as it was loaded. Null on add.</summary>
    public string? OriginalValue { get; set; }

    public string? Value { get; set; }
    public string? ActionCode { get; set; }
    public int? SortOrder { get; set; }
    public bool IsActive { get; set; } = true;
}
