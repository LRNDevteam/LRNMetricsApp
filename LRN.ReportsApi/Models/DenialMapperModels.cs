namespace LRN.ReportsApi.Models;

public sealed class DenialMapperRecord
{
    public long Id { get; set; }
    public long SuperMasterId { get; set; }
    public int? LabId { get; set; }
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public string ActionCode { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string SLA { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;
    public bool IsOverride { get; set; }
    public string? OriginalActionCode { get; set; }
    public string? OriginalActionCategory { get; set; }
    public string? OriginalTask { get; set; }
    public string? OriginalRecommendedAction { get; set; }
    public DateTime? ModifiedOn { get; set; }
}

public sealed class DenialMapperSaveRequest
{
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialClassification { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ICDComplianceStatus { get; set; }
    public string? DenialValidity { get; set; }
    public string ActionCode { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string SLA { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;
}

public sealed class DenialMapperOverrideRequest
{
    public string ActionCode { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
}

public sealed class DenialMapperPushRequest { public IReadOnlyList<int> LabIds { get; set; } = Array.Empty<int>(); }

public sealed class DenialMapperPushCompareResult
{
    public IReadOnlyList<long> PushAuditIds { get; set; } = Array.Empty<long>();
    public int TotalLabs { get; set; }
    public int TotalCompared { get; set; }
    public int TotalDifferences { get; set; }
    public int TotalAssignedOpenTasksAffected { get; set; }
    public IReadOnlyList<DenialMapperPushDifference> Differences { get; set; } = Array.Empty<DenialMapperPushDifference>();
    public string Message { get; set; } = string.Empty;
}

public sealed class DenialMapperPushDifference
{
    public long PushAuditDetailId { get; set; }
    public long PushAuditId { get; set; }
    public int TargetLabId { get; set; }
    public string TargetLabName { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string? ICDComplianceStatus { get; set; }
    public string? CoverageStatus { get; set; }
    public string? ExistingActionCode { get; set; }
    public string? NewActionCode { get; set; }
    public string? ExistingActionCategory { get; set; }
    public string? NewActionCategory { get; set; }
    public string? ExistingTask { get; set; }
    public string? NewTask { get; set; }
    public string? ExistingShortCategory { get; set; }
    public string? NewShortCategory { get; set; }
    public string? ExistingDenialClassification { get; set; }
    public string? NewDenialClassification { get; set; }
    public string DifferenceType { get; set; } = string.Empty;
    public bool IsAssignedToOpenTask { get; set; }
    public int OpenAssignedTaskCount { get; set; }
}

public sealed class DenialMapperPushAuditView
{
    public long PushAuditId { get; set; }
    public int SourceLabId { get; set; }
    public string SourceLabName { get; set; } = "Master Lab";
    public int TargetLabId { get; set; }
    public string TargetLabName { get; set; } = string.Empty;
    public string PushedByUserId { get; set; } = string.Empty;
    public string PushStatus { get; set; } = string.Empty;
    public int TotalCompared { get; set; }
    public int TotalDifferences { get; set; }
    public int TotalAssignedOpenTasksAffected { get; set; }
    public DateTime CreatedOn { get; set; }
    public DateTime? ConfirmedOn { get; set; }
    public IReadOnlyList<DenialMapperPushDifference> Differences { get; set; } = Array.Empty<DenialMapperPushDifference>();
}

public sealed class DenialMapperPushDecisionRequest
{
    public IReadOnlyList<long> PushAuditIds { get; set; } = Array.Empty<long>();
}

public sealed class DenialMapperPushDetailEditRequest
{
    public string ActionCode { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string? DenialClassification { get; set; }
}

public sealed class DenialMapperNotification
{
    public long PushAuditId { get; set; }
    public int SourceLabId { get; set; }
    public int TargetLabId { get; set; }
    public string TargetLabName { get; set; } = string.Empty;
    public string PushStatus { get; set; } = string.Empty;
    public int TotalDifferences { get; set; }
    public DateTime CreatedOn { get; set; }
    public string Message { get; set; } = "Denial Mapper update is available for your lab. Please verify and confirm the Denial Code Master changes.";
}

public sealed class DenialMapperLabStatus
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string? LabCode { get; set; }
    public bool IsActive { get; set; }
    public int MappingCount { get; set; }
    public int OverrideCount { get; set; }
    public DateTime? LastPushedOn { get; set; }
}

public sealed class DenialMapperAuditRecord
{
    public long Id { get; set; }
    public DateTime PerformedOn { get; set; }
    public string? PerformedBy { get; set; }
    public string? PerformedRole { get; set; }
    public int? LabId { get; set; }
    public string? DenialCode { get; set; }
    public string EventType { get; set; } = string.Empty;
    public string? FieldName { get; set; }
    public string? FromValue { get; set; }
    public string? ToValue { get; set; }
}

public sealed class DenialMapperDashboard
{
    public int TotalDenialCodes { get; set; }
    public int ActiveLabs { get; set; }
    public int PendingPushLabs { get; set; }
    public int TotalOverrides { get; set; }
    public DateTime? LastModifiedOn { get; set; }
}
