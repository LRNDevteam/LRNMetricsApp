namespace LabMetricsDashboard.Models;

/// <summary>
/// Wire shape of <c>GET api/report-board/latest</c>. Mirrors the LRN.ReportsApi pivot result:
/// the report columns are discovered from the SP, so they arrive as a list plus a per-row
/// dictionary rather than as fixed properties.
/// </summary>
public sealed class ReportBoardApiResult
{
    public List<string> ReportColumns { get; set; } = [];
    public List<ReportBoardApiRow> Rows { get; set; } = [];
}

public sealed class ReportBoardApiRow
{
    public string RunId { get; set; } = string.Empty;
    public string? Lab { get; set; }

    /// <summary>Formatted by the SP as MM/dd/yyyy.</summary>
    public string? SyncedOn { get; set; }

    /// <summary>Parsed form of <see cref="SyncedOn"/>; null when the SP value was not a date.</summary>
    public DateTime? SyncedOnDate { get; set; }

    public string? Week { get; set; }

    /// <summary>Keyed by report column name; value is Success / Failed / null.</summary>
    public Dictionary<string, string?> Statuses { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public int SuccessCount { get; set; }
    public int FailedCount { get; set; }
    public int SkippedCount { get; set; }
    public int NotRunCount { get; set; }
    public int ErrorLogCount { get; set; }
    public int TotalLogCount { get; set; }
}

/// <summary>Wire shape of <c>GET api/report-board/run-errors</c>.</summary>
public sealed class RunErrorsResult
{
    public string? RunId { get; set; }
    public string? LabName { get; set; }
    public string? ReportType { get; set; }
    public List<PipelineErrorDto> PipelineErrors { get; set; } = [];
    public List<RunLogEntryDto> RunLog { get; set; } = [];

    /// <summary>Per-source problems reported by the API (one log table unreadable, etc.).</summary>
    public List<string> Warnings { get; set; } = [];

    /// <summary>Set when the whole request failed, so the page can still name the run.</summary>
    public string? LoadError { get; set; }

    public bool IsEmpty => PipelineErrors.Count == 0 && RunLog.Count == 0;
}

public sealed class PipelineErrorDto
{
    public string? RunId { get; set; }
    public string? LabName { get; set; }
    public DateTime? ErrorTime { get; set; }
    public string? Severity { get; set; }
    public string? StepName { get; set; }
    public string? ErrorCode { get; set; }
    public string? ErrorSummary { get; set; }
    public string? MissingColumns { get; set; }
    public string? SheetName { get; set; }
    public string? FileName { get; set; }
    public string? RecommendedAction { get; set; }
    public string? OwnerTeam { get; set; }
    public string? TicketId { get; set; }
    public string? Status { get; set; }
    public string? SourceSystem { get; set; }
}

public sealed class RunLogEntryDto
{
    public long ReportRunIdInfoLogId { get; set; }
    public string? RunId { get; set; }
    public string? ReportType { get; set; }
    public string? SourceSystem { get; set; }
    public string? LogType { get; set; }
    public string? LogMessage { get; set; }
    public string? SourceFileName { get; set; }
    public DateTime? CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
}
