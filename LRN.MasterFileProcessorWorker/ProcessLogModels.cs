using System;

public sealed class RunLogRow
{
    public string RunID { get; set; } = "";
    public string LabName { get; set; } = "";
    public string? PipelineName { get; set; }
    public string? TriggerType { get; set; }
    public string? TriggeredBy { get; set; }

    public DateTime? StartTimeIST { get; set; }
    public DateTime? EndTimeIST { get; set; }
    public int? DurationSeconds { get; set; }

    public string? OverallStatus { get; set; } // IN_PROGRESS/SUCCESS/FAILED/SKIPPED
    public string? LatestMasterFileFound { get; set; } // YES/NO

    public string? InputMasterSharePointPath { get; set; }
    public string? InputMasterFileName { get; set; }
    public DateTime? InputMasterFileModifiedTime { get; set; }
    public decimal? InputMasterFileSizeMB { get; set; }

    public string? MandatoryColumnCheck { get; set; } // PASS/FAIL/SKIPPED
    public string? SplitOutputWrittenToSharePoint { get; set; } // YES/NO/SKIPPED

    public string? PayerPolicyValidationStatus { get; set; } // SUCCESS/FAILED/SKIPPED
    public string? CodingValidationStatus { get; set; }
    public string? AveragesProcessStatus { get; set; }

    public string? OutputsCopiedToSharePoint { get; set; } // YES/NO/SKIPPED
    public string? MasterSyncPerformed { get; set; } // YES/NO/SKIPPED

    public int TotalErrors { get; set; }
    public int TotalWarnings { get; set; }

    public string? Notes { get; set; }
}

public sealed class StepLogRow
{
    public string RunID { get; set; } = "";
    public string? LabName { get; set; }
    public int StepSeq { get; set; }
    public string StepName { get; set; } = "";
    public string? StepCategory { get; set; }
    public string? SourceSystem { get; set; }
    public DateTime? StartTimeIST { get; set; }
    public DateTime? EndTimeIST { get; set; }
    public int? DurationSeconds { get; set; }
    public string? Status { get; set; } // IN_PROGRESS/SUCCESS/FAILED/SKIPPED/WARNING
    public int? RecordsIn { get; set; }
    public int? RecordsOut { get; set; }
    public string? FileNameIn { get; set; }
    public string? FileNameOut { get; set; }
    public string? PathIn { get; set; }
    public string? PathOut { get; set; }
    public string? ErrorCode { get; set; }
    public string? ErrorMessage { get; set; }
    public string? ErrorDetail { get; set; }
    public int? RetryCount { get; set; }
    public string? ExecutedBy { get; set; }
    public string? Host { get; set; }
    public string? ModuleVersion { get; set; }
}

public sealed class ErrorLogRow
{
    public string RunID { get; set; } = "";
    public string? LabName { get; set; }
    public DateTime ErrorTimeIST { get; set; }
    public string Severity { get; set; } = "ERROR"; // ERROR/WARNING
    public string? StepName { get; set; }
    public string? ErrorCode { get; set; }
    public string ErrorSummary { get; set; } = "";
    public string? MissingColumns { get; set; }
    public string? SheetName { get; set; }
    public string? FileName { get; set; }
    public string? FilePath { get; set; }
    public string? RowExample { get; set; }
    public string? RecommendedAction { get; set; }
    public string? OwnerTeam { get; set; }
    public string? TicketID { get; set; }
    public string? Status { get; set; } // OPEN/RESOLVED
}

public sealed class ProcessRunContext
{
    public string RunId { get; init; } = "";
    public string LabName { get; init; } = "";
    public DateTime StartTimeIST { get; init; }
}
