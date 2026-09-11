namespace LabMetricsDashboard.Models;

/// <summary>One lab ticked in the re-run dialog.</summary>
public sealed class MasterProcessorRerunLabSelection
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
}

/// <summary>What the browser posts when the confirmation is accepted.</summary>
public sealed class MasterProcessorRerunRequestBody
{
    public List<int> LabIds { get; set; } = new();

    /// <summary>Why this re-run is being asked for. Recorded against every lab in the batch.</summary>
    public string? Notes { get; set; }
}

/// <summary>
/// Everything about the origin of a re-run, assembled by the controller rather than the browser.
/// A client that could name its own requester would make the audit trail worthless.
/// </summary>
public sealed class MasterProcessorRerunContext
{
    public string RequestedBy { get; set; } = string.Empty;
    public string? RequestedByRole { get; set; }
    public string? App { get; set; }
    public string? Host { get; set; }
    public string? ClientIp { get; set; }
    public string? UserAgent { get; set; }
    public string? Notes { get; set; }
}

/// <summary>
/// The outcome of one click, per lab. Split three ways because "nothing happened" and "it was
/// already running" are different answers and the screen has to say which.
/// </summary>
public sealed class MasterProcessorRerunSubmitResult
{
    public Guid BatchId { get; set; }
    public List<string> Queued { get; } = new();
    public List<string> AlreadyQueued { get; } = new();
    public List<string> Failed { get; } = new();
}

/// <summary>One row of the re-run history panel.</summary>
public sealed class MasterProcessorRerunRow
{
    public long RerunRequestId { get; set; }
    public Guid BatchId { get; set; }
    public int LabId { get; set; }
    public string? LabName { get; set; }
    public string? Status { get; set; }
    public string? RequestedBy { get; set; }
    public string? RequestedByRole { get; set; }
    public DateTime RequestedOn { get; set; }
    public string? RequestedFromApp { get; set; }
    public string? RequestedFromHost { get; set; }
    public string? RequestedFromIp { get; set; }
    public string? Notes { get; set; }
    public DateTime? ClaimedOn { get; set; }
    public string? ClaimedByHost { get; set; }
    public DateTime? CompletedOn { get; set; }
    public string? RunId { get; set; }
    public string? ResultStatus { get; set; }
    public string? ResultMessage { get; set; }
}
