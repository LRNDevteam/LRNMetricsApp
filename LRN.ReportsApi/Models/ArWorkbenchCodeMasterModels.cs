namespace LRN.ReportsApi.Models;

/// <summary>
/// One code in the central Denial Code Master (LRNMaster dbo.ARWB_DenialCodeMaster). DenialCode is
/// normalized: no CO / PR / PI / OA prefix, so PR4, CO4 and PI4 share code 4.
/// </summary>
public sealed class ArWorkbenchCodeMasterRow
{
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? ActionCategory { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public bool IsNonCollectible { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime? CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }
}

public sealed class ArWorkbenchCodeMasterSaveRequest
{
    public string? DenialCode { get; set; }
    public string? DenialDescription { get; set; }
    public string? ActionCategory { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public bool IsNonCollectible { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>The screen's data: every code plus the dropdown options.</summary>
public sealed class ArWorkbenchCodeMasterData
{
    /// <summary>False until LRNMaster_02_ARWB_DenialCodeMaster.sql has been run.</summary>
    public bool Installed { get; set; }
    public List<ArWorkbenchCodeMasterRow> Rows { get; set; } = new();
    public ArWorkbenchCodeMasterOptions Options { get; set; } = new();
}

public sealed class ArWorkbenchCodeMasterOptions
{
    /// <summary>Values already used plus the lab's Denial Root Cause list (the sheet's categorization).</summary>
    public List<string> ActionCategories { get; set; } = new();
    public List<string> DenialClassifications { get; set; } = new();
    public List<string> CoverageStatuses { get; set; } = new();
    public List<string> ICDComplianceStatuses { get; set; } = new();
    public List<string> DenialValidities { get; set; } = new();
}

public sealed class ArWorkbenchCodeMasterImportResult
{
    public int RowsRead { get; set; }
    public int Inserted { get; set; }
    public int Updated { get; set; }
    public int Unchanged { get; set; }
    public int NonCollectibleCodes { get; set; }
    public List<string> Errors { get; set; } = new();
    public List<string> Warnings { get; set; } = new();
    public string Message { get; set; } = string.Empty;
}

/// <summary>What "Apply Non-Collectible codes to this lab" changes in the lab's NON_COLLECTIBLE_CODE list.</summary>
public sealed class ArWorkbenchNonCollectibleSync
{
    public List<string> MasterCodes { get; set; } = new();
    public List<string> ToAdd { get; set; } = new();
    public List<string> ToDeactivate { get; set; } = new();
    public int Unchanged { get; set; }
    public int ClaimsRecalculated { get; set; }
    public int ClaimsWithNonCollectibleDenial { get; set; }
    public string? Message { get; set; }
}
