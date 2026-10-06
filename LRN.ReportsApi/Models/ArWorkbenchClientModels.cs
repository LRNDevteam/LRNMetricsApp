namespace LRN.ReportsApi.Models;

/// <summary>Client (lab) activation in LRNMaster dbo.ARWB_ClientSetting (T068).</summary>
public sealed class ArWorkbenchClientStatus
{
    public bool IsActive { get; set; } = true;
    public string? StatusNote { get; set; }
    public string? ChangedBy { get; set; }
    public DateTime? ChangedOn { get; set; }
}

public sealed class ArWorkbenchClientStats
{
    /// <summary>Claims with an open insurance balance - eligible for the workflow.</summary>
    public int EligibleClaims { get; set; }
    public int ClaimsInSource { get; set; }
    public decimal OutstandingAR { get; set; }
    public decimal Recovered { get; set; }
    public int AssignedClaims { get; set; }
    public int AwaitingQa { get; set; }
    public DateTime? LastRefreshOn { get; set; }
}

/// <summary>One Client Management card.</summary>
public sealed class ArWorkbenchClientCard
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
    public string? StatusNote { get; set; }
    public string? ChangedBy { get; set; }
    public DateTime? ChangedOn { get; set; }
    /// <summary>Null when the AR Workbench is not set up for this lab.</summary>
    public ArWorkbenchClientStats? Stats { get; set; }
}

public sealed class ArWorkbenchClientActiveRequest
{
    public bool IsActive { get; set; }
    public string? Note { get; set; }
}
