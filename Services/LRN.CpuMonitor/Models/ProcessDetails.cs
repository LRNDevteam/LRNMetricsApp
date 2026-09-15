namespace LRN.CpuMonitor.Models;

/// <summary>
/// Identity of a process, resolved once a breach is confirmed.
/// </summary>
public sealed record ProcessDetails(
    int Pid,
    string Name,
    string ExecutablePath,
    string CommandLine,
    string Owner,
    int SessionId,
    DateTime? StartTimeUtc,
    IReadOnlyList<ProcessAncestor> Ancestry);

/// <summary>
/// A link in the parent chain. Walking this is how a breach gets attributed to
/// whatever launched it.
/// </summary>
public sealed record ProcessAncestor(
    int Pid,
    string Name,
    string ExecutablePath,
    string CommandLine,
    DateTime? StartTimeUtc);

/// <summary>
/// Why an Office process is running. COM automation is hidden behind DCOM, so the
/// parent chain alone cannot answer it, but the command line and session can.
/// </summary>
public enum OfficeLaunchKind
{
    /// <summary>No Office-specific signal found.</summary>
    Unknown,

    /// <summary>
    /// Started by COM automation. Office is launched by the DCOM service rather than
    /// the calling program, so the parent chain points at svchost, not the caller.
    /// </summary>
    ComAutomation,

    /// <summary>Started with a document argument, so someone opened a file.</summary>
    DocumentOpen,

    /// <summary>Started interactively with no document.</summary>
    Interactive,
}

/// <summary>
/// Launch-origin verdict for an Office process, with the evidence behind it.
/// </summary>
/// <param name="Kind">The verdict.</param>
/// <param name="Explanation">Why that verdict was reached, for the log record.</param>
/// <param name="CandidateAutomationClients">
/// Processes that plausibly drove a COM instance: same session, started before
/// Office, still alive. Correlation only, because DCOM does not record the caller.
/// </param>
public sealed record OfficeLaunchOrigin(
    OfficeLaunchKind Kind,
    string Explanation,
    IReadOnlyList<ProcessAncestor> CandidateAutomationClients);
