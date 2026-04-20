namespace LabMetricsDashboard.Models;

/// <summary>Row from CodingSetupMasterList table.</summary>
public sealed record PanelPathogenCptRecord
{
    public int Id { get; init; }
    public string LabName { get; init; } = string.Empty;
    public string PanelName { get; init; } = string.Empty;
    public string? TestName { get; init; }
    public string PathogenName { get; init; } = string.Empty;
    public string CPTCode { get; init; } = string.Empty;
    public decimal DefaultUnits { get; init; }
    public string? DefaultICDCodes { get; init; }
    public int SortOrder { get; init; }
    public bool IsActive { get; init; } = true;
    public string? CreatedBy { get; init; }
    public DateTime? CreatedDate { get; init; }
    public string? ModifiedBy { get; init; }
    public DateTime? ModifiedDate { get; init; }
}

/// <summary>Master list view model with search, paging, sorting.</summary>
public sealed class CodingSetupIndexViewModel
{
    public string LabName { get; init; } = string.Empty;
    public List<string> AvailableLabs { get; init; } = [];
    public List<PanelPathogenCptRecord> Records { get; init; } = [];
    public List<CodingSetupPanelWiseRow> GroupedRecords { get; init; } = [];
    public int TotalCount { get; init; }
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 20;
    public string? Search { get; init; }
    public string SortColumn { get; init; } = "PanelName";
    public string SortDirection { get; init; } = "asc";
    public string ActiveFilter { get; init; } = "active"; // "all", "active", "inactive"

    public int TotalPages => (int)Math.Ceiling((double)TotalCount / PageSize);
}

/// <summary>Create / Edit form model.</summary>
public sealed class CodingSetupFormModel
{
    public int Id { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public string? TestName { get; set; }
    public string PathogenName { get; set; } = string.Empty;
    public string CPTCode { get; set; } = string.Empty;
    public decimal DefaultUnits { get; set; } = 1;
    public string? DefaultICDCodes { get; set; }
    public int SortOrder { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>Clone panel request.</summary>
public sealed class ClonePanelRequest
{
    public string LabName { get; set; } = string.Empty;
    public string SourcePanelName { get; set; } = string.Empty;
    public string NewPanelName { get; set; } = string.Empty;
}

/// <summary>Dropdown lookup values for the Create / Edit forms.</summary>
public sealed record CodingSetupDropdownLookups
{
    public List<string> PanelNames { get; init; } = [];
    public List<string> TestNames { get; init; } = [];
    public List<string> PathogenNames { get; init; } = [];
    public List<string> CptCodes { get; init; } = [];
    public List<string> IcdCodes { get; init; } = [];
}

/// <summary>One CPT + Units pair submitted from the multi-CPT form.</summary>
public sealed class CptUnitEntry
{
    public string CptCode { get; set; } = string.Empty;
    public decimal Units { get; set; } = 1;
}

/// <summary>Create form model supporting multiple CPT/Unit pairs.</summary>
public sealed class CodingSetupMultiCreateModel
{
    public string LabName { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public string? TestName { get; set; }
    public string PathogenName { get; set; } = string.Empty;
    public List<CptUnitEntry> CptEntries { get; set; } = [new()];
    public string? DefaultICDCodes { get; set; }
    public int SortOrder { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>Audit entry for change history.</summary>
public sealed record CodingSetupAuditEntry
{
    public string FieldName { get; init; } = string.Empty;
    public string? OldValue { get; init; }
    public string? NewValue { get; init; }
    public string? ChangedBy { get; init; }
    public DateTime ChangedDate { get; init; }
}

/// <summary>Grouped panel-wise row for the Index display.</summary>
public sealed record CodingSetupPanelWiseRow
{
    public string PanelName { get; init; } = string.Empty;
    public string? TestName { get; init; }
    public string PathogenName { get; init; } = string.Empty;
    /// <summary>Combined CPTCode*Units pairs, e.g. "87798*12,87594*1".</summary>
    public string Procedure { get; init; } = string.Empty;
    public string? DefaultICDCodes { get; init; }
    public int SortOrder { get; init; }
    public bool IsActive { get; init; } = true;
    /// <summary>Ids of individual records in this group (for edit/deactivate).</summary>
    public List<int> RecordIds { get; init; } = [];
}
