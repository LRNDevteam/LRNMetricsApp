namespace LRN.ReportsApi.Models;

/// <summary>Audit Logs filter (T067).</summary>
public sealed class ArWorkbenchAuditFilter
{
    public int LabId { get; set; }
    public string? Search { get; set; }
    public List<string> User { get; set; } = new();
    public List<string> Action { get; set; } = new();
    /// <summary>Client = the claim's LabName.</summary>
    public List<string> Client { get; set; } = new();
    public DateTime? From { get; set; }
    public DateTime? To { get; set; }
    /// <summary>Include the data sync's system entries (Claim Identified, Source Data Updated ...).</summary>
    public bool IncludeSystem { get; set; }
    public string? SortBy { get; set; }
    public bool SortDesc { get; set; } = true;
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public sealed class ArWorkbenchAuditRow
{
    public long ActivityId { get; set; }
    public DateTime ActivityOn { get; set; }
    public long ClaimKey { get; set; }
    public string ClaimID { get; set; } = string.Empty;
    public string? LabName { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string? RoleCode { get; set; }
    public string ActionType { get; set; } = string.Empty;
    public string? PreviousValue { get; set; }
    public string? NewValue { get; set; }
    public string? Detail { get; set; }
    public bool IsSystem { get; set; }
}

public sealed class ArWorkbenchAuditPage
{
    public ArWorkbenchPagedResult<ArWorkbenchAuditRow> Rows { get; set; } = new();
    public List<ArWorkbenchFilterOption> Users { get; set; } = new();
    public List<ArWorkbenchFilterOption> Actions { get; set; } = new();
    public List<ArWorkbenchFilterOption> Clients { get; set; } = new();
}
