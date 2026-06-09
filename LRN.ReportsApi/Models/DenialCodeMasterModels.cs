namespace LRN.ReportsApi.Models;

public sealed class DenialCodeMasterRecord
{
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public string? ActionCode { get; set; }
    public string? RecommendedAction { get; set; }
    public string? ActionCategory { get; set; }
    public string? Task { get; set; }
    public string? ShortCategory { get; set; }
    public string? Priority { get; set; }
    public string? SLADays { get; set; }
    public string? NotesComments { get; set; }
    public DateTime CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }
}

public sealed class DenialCodeMasterRequest
{
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public string? ActionCode { get; set; }
    public string? RecommendedAction { get; set; }
    public string? ActionCategory { get; set; }
    public string? Task { get; set; }
    public string? ShortCategory { get; set; }
    public string? Priority { get; set; }
    public string? SLADays { get; set; }
    public string? NotesComments { get; set; }
}

public sealed class DenialCodeMasterLookups
{
    public IReadOnlyList<string> DenialClassifications { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> CoverageStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ICDComplianceStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> DenialValidities { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ActionCodes { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ActionCategories { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Tasks { get; set; } = Array.Empty<string>();
}

public sealed class DenialCodeMasterImportResult
{
    public int InsertedCount { get; set; }
    public int UpdatedCount { get; set; }
    public int SkippedCount { get; set; }
    public int FailedCount { get; set; }
    public IReadOnlyList<string> Errors { get; set; } = Array.Empty<string>();
}

public sealed class DenialCodeMasterImportRequest
{
    public IFormFile? File { get; set; }
}

public sealed class DenialCodeMasterExportOptions
{
    public string ExportFolderPath { get; set; } = @"D:\LRN\DenialCodeMaster";
    public string ExportFileName { get; set; } = "PCRLabsofAmerica_Denial_Action_Classifier_v1.1.xlsx";
}
