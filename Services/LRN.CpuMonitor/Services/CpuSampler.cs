using System.Diagnostics;
using LRN.CpuMonitor.Models;

namespace LRN.CpuMonitor.Services;

/// <summary>
/// Measures per-process CPU by reading total processor time twice and dividing the
/// delta by elapsed wall-clock time. Deliberately avoids performance counters: the
/// "Process" counter category identifies processes by an ambiguous name#index that
/// collides whenever several share a name, which is exactly the case here for w3wp,
/// dotnet and EXCEL.
/// </summary>
public sealed class CpuSampler : ICpuSampler
{
    private readonly ILogger<CpuSampler> _logger;

    public CpuSampler(ILogger<CpuSampler> logger)
    {
        _logger = logger;
    }

    public async Task<CpuSnapshot> SampleAsync(
        TimeSpan window,
        bool normalizeByCoreCount,
        CancellationToken cancellationToken)
    {
        var before = ReadProcessorTimes();
        var startedAt = Stopwatch.GetTimestamp();

        await Task.Delay(window, cancellationToken).ConfigureAwait(false);

        var after = ReadProcessorTimes();
        var elapsed = Stopwatch.GetElapsedTime(startedAt);

        if (elapsed <= TimeSpan.Zero)
        {
            return new CpuSnapshot([], 0, elapsed);
        }

        // Normalizing by core count makes a process that saturates every core read
        // 100%, which is what Task Manager shows; otherwise one core reads 100%.
        var coreMilliseconds = elapsed.TotalMilliseconds * Environment.ProcessorCount;
        var divisor = normalizeByCoreCount ? coreMilliseconds : elapsed.TotalMilliseconds;

        var samples = new List<ProcessCpuSample>(after.Count);
        var machineCpuPercent = 0d;

        foreach (var (pid, current) in after)
        {
            // Absent from the first reading means it started mid-window, so there is
            // no rate to compute yet.
            if (!before.TryGetValue(pid, out var previous))
            {
                continue;
            }

            // Windows recycles PIDs aggressively. A different start time means this is
            // a new process wearing a dead one's PID, and the delta would be nonsense.
            if (current.StartTicks != previous.StartTicks)
            {
                continue;
            }

            var cpuDelta = current.Cpu - previous.Cpu;
            if (cpuDelta <= TimeSpan.Zero)
            {
                continue;
            }

            if (pid != 0)
            {
                machineCpuPercent += cpuDelta.TotalMilliseconds / coreMilliseconds * 100;
            }

            samples.Add(new ProcessCpuSample(
                pid,
                current.Name,
                cpuDelta.TotalMilliseconds / divisor * 100,
                cpuDelta));
        }

        samples.Sort(static (left, right) => right.CpuPercent.CompareTo(left.CpuPercent));

        return new CpuSnapshot(samples, Math.Clamp(machineCpuPercent, 0, 100), elapsed);
    }

    private Dictionary<int, Reading> ReadProcessorTimes()
    {
        var readings = new Dictionary<int, Reading>(400);
        var unreadable = 0;

        foreach (var process in Process.GetProcesses())
        {
            try
            {
                // Both of these throw for protected processes, and for processes owned
                // by another account when the service lacks privilege. Those are simply
                // skipped rather than failing the whole sweep.
                var cpu = process.TotalProcessorTime;
                var startTicks = process.StartTime.Ticks;

                readings[process.Id] = new Reading(process.ProcessName, cpu, startTicks);
            }
            catch (Exception ex) when (ex is InvalidOperationException
                or System.ComponentModel.Win32Exception
                or NotSupportedException)
            {
                unreadable++;
            }
            finally
            {
                process.Dispose();
            }
        }

        if (unreadable > 0)
        {
            _logger.LogDebug("Skipped {UnreadableCount} process(es) that could not be read", unreadable);
        }

        return readings;
    }

    private readonly record struct Reading(string Name, TimeSpan Cpu, long StartTicks);
}
