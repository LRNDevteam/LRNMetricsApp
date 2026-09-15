namespace LRN.CpuMonitor.Models;

/// <summary>
/// One process's processor usage measured across a single window.
/// </summary>
public sealed record ProcessCpuSample(
    int Pid,
    string ProcessName,
    double CpuPercent,
    TimeSpan CpuConsumed);

/// <summary>
/// The result of one measurement window.
/// </summary>
/// <param name="Samples">Per-process usage, highest first.</param>
/// <param name="MachineCpuPercent">
/// Approximate whole-machine usage, summed from the per-process figures and capped at
/// 100. Logged for context so a breach can be read as "this process is the load"
/// rather than "the box is busy and this process is one of several".
/// </param>
/// <param name="Window">Actual elapsed time between the two readings.</param>
public sealed record CpuSnapshot(
    IReadOnlyList<ProcessCpuSample> Samples,
    double MachineCpuPercent,
    TimeSpan Window);
