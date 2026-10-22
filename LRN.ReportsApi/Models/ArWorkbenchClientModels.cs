namespace LRN.ReportsApi.Models;

/// <summary>Client (lab) activation in LRNMaster dbo.ARWB_ClientSetting (T068).</summary>
public sealed class ArWorkbenchClientStatus
{
    public bool IsActive { get; set; } = true;
    public string? StatusNote { get; set; }
    public string? ChangedBy { get; set; }
    public DateTime? ChangedOn { get; set; }
    public ArWorkbenchClientConfig Config { get; set; } = new();
}

/// <summary>FR-CM-03 per-client configuration (LRNMaster dbo.ARWB_ClientSetting).</summary>
public sealed class ArWorkbenchClientConfig
{
    public static readonly IReadOnlyList<string> OnboardingStatuses = ["Not Started", "Onboarding", "Live", "On Hold"];

    /// <summary>SharePoint folder the client's weekly master files are picked up from.</summary>
    public string? SharePointFolder { get; set; }
    public string? OnboardingStatus { get; set; }
    /// <summary>Primary account manager (name or email).</summary>
    public string? AccountManager { get; set; }
    public string? UpdatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
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
    public ArWorkbenchClientConfig Config { get; set; } = new();
}

public sealed class ArWorkbenchClientActiveRequest
{
    public bool IsActive { get; set; }
    public string? Note { get; set; }
}
