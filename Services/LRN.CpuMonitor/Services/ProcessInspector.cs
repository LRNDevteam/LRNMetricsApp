using System.Management;
using System.Text;
using LRN.CpuMonitor.Models;

namespace LRN.CpuMonitor.Services;

/// <summary>
/// Reads process identity from WMI. <c>Win32_Process</c> is used rather than
/// <see cref="System.Diagnostics.Process"/> because only WMI exposes the command line
/// and the parent PID, and its executable path also works for processes owned by
/// other accounts, where MainModule raises access denied.
/// </summary>
public sealed class ProcessInspector : IProcessInspector
{
    /// <summary>
    /// Walking a circular or corrupt parent chain has to terminate; real chains are
    /// only a few links deep.
    /// </summary>
    private const int MaxAncestryDepth = 8;

    /// <summary>
    /// A WMI process enumeration costs hundreds of milliseconds, and one breach cycle
    /// can inspect several processes plus their ancestors. Caching briefly collapses
    /// that to a single query per cycle while staying inside the shortest sensible
    /// poll interval.
    /// </summary>
    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(3);

    /// <summary>
    /// Shells and service hosts are never the interesting automation client, so they
    /// are left out of the COM candidate list to keep it readable.
    /// </summary>
    private static readonly HashSet<string> NonClientHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "svchost.exe", "explorer.exe", "csrss.exe", "wininit.exe", "winlogon.exe",
        "services.exe", "lsass.exe", "smss.exe", "dwm.exe", "taskhostw.exe",
        "sihost.exe", "ctfmon.exe", "RuntimeBroker.exe", "fontdrvhost.exe",
        "conhost.exe", "System", "Registry", "Idle", "Memory Compression",
    };

    private readonly ILogger<ProcessInspector> _logger;
    private readonly TimeProvider _timeProvider;

    private Dictionary<int, WmiProcess>? _cache;
    private DateTimeOffset _cachedAt = DateTimeOffset.MinValue;

    public ProcessInspector(ILogger<ProcessInspector> logger, TimeProvider timeProvider)
    {
        _logger = logger;
        _timeProvider = timeProvider;
    }

    public ProcessDetails? Describe(int pid)
    {
        var table = GetProcessTable();

        if (!table.TryGetValue(pid, out var process))
        {
            return null;
        }

        return new ProcessDetails(
            Pid: process.Pid,
            Name: process.Name,
            ExecutablePath: Fallback(process.ExecutablePath),
            CommandLine: Fallback(process.CommandLine),
            Owner: ResolveOwner(pid),
            SessionId: process.SessionId,
            StartTimeUtc: process.StartTimeUtc,
            Ancestry: BuildAncestry(table, process));
    }

    public OfficeLaunchOrigin ExplainOfficeLaunch(ProcessDetails details)
    {
        var commandLine = details.CommandLine;

        // Office adds -Embedding when started to serve a COM client, and /automation
        // when that client asked for a hidden instance.
        var embedding = commandLine.Contains("-Embedding", StringComparison.OrdinalIgnoreCase)
            || commandLine.Contains("/embedding", StringComparison.OrdinalIgnoreCase);
        var automation = commandLine.Contains("/automation", StringComparison.OrdinalIgnoreCase);

        if (embedding || automation)
        {
            var parent = details.Ancestry.FirstOrDefault();
            var viaDcom = parent is not null
                && parent.Name.Equals("svchost.exe", StringComparison.OrdinalIgnoreCase);

            var explanation = "Started by COM automation, so a program is driving it rather than a person. "
                + (viaDcom
                    ? "The parent is svchost.exe, confirming DCOM activation: Windows launches Office on the "
                        + "caller's behalf and keeps no link back to it, so the parent chain cannot name the caller. "
                    : "DCOM activation means the parent chain does not name the caller. ")
                + "The candidates below are correlation only.";

            return new OfficeLaunchOrigin(
                OfficeLaunchKind.ComAutomation,
                explanation,
                FindCandidateAutomationClients(details));
        }

        var documentArgument = FindDocumentArgument(commandLine);
        if (documentArgument is not null)
        {
            var parent = details.Ancestry.FirstOrDefault();
            var launcher = parent is null
                ? "The parent process has already exited."
                : $"Launched by {parent.Name} (PID {parent.Pid}).";

            return new OfficeLaunchOrigin(
                OfficeLaunchKind.DocumentOpen,
                $"Opened with a document argument ({documentArgument}), so the parent chain is meaningful. "
                    + launcher
                    + " A parent of explorer.exe means a person double-clicked the file.",
                []);
        }

        if (details.SessionId == 0)
        {
            return new OfficeLaunchOrigin(
                OfficeLaunchKind.Unknown,
                "Running in session 0, which has no interactive desktop, so this cannot be a person at a "
                    + "keyboard. Treat it as automation even though no COM marker was found on the command line.",
                FindCandidateAutomationClients(details));
        }

        return new OfficeLaunchOrigin(
            OfficeLaunchKind.Interactive,
            $"Started with no document and no COM marker in interactive session {details.SessionId}, "
                + "which looks like a person opening the application directly.",
            []);
    }

    /// <summary>
    /// Processes that could plausibly be driving a COM instance: alive, in the same
    /// session, started before Office. Ordered by proximity in start time, because a
    /// client normally creates the instance moments after it begins work.
    /// </summary>
    private IReadOnlyList<ProcessAncestor> FindCandidateAutomationClients(ProcessDetails details)
    {
        if (details.StartTimeUtc is null)
        {
            return [];
        }

        return GetProcessTable().Values
            .Where(candidate =>
                candidate.Pid != details.Pid
                && candidate.SessionId == details.SessionId
                && candidate.StartTimeUtc is not null
                && candidate.StartTimeUtc <= details.StartTimeUtc
                && !NonClientHosts.Contains(candidate.Name)
                && !candidate.Name.Equals(details.Name, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(candidate => candidate.StartTimeUtc)
            .Take(5)
            .Select(ToAncestor)
            .ToList();
    }

    /// <summary>
    /// Returns the first command-line argument that looks like a document rather than
    /// a switch, or null when the process was started bare.
    /// </summary>
    private static string? FindDocumentArgument(string commandLine)
    {
        foreach (var argument in SplitArguments(commandLine).Skip(1))
        {
            if (argument.Length == 0 || argument[0] is '-' or '/')
            {
                continue;
            }

            return argument;
        }

        return null;
    }

    /// <summary>
    /// Minimal quote-aware split. Enough to separate an executable from its switches,
    /// which is all the document check needs.
    /// </summary>
    private static IEnumerable<string> SplitArguments(string commandLine)
    {
        var current = new StringBuilder();
        var inQuotes = false;

        foreach (var character in commandLine)
        {
            if (character == '"')
            {
                inQuotes = !inQuotes;
            }
            else if (character == ' ' && !inQuotes)
            {
                if (current.Length > 0)
                {
                    yield return current.ToString();
                    current.Clear();
                }
            }
            else
            {
                current.Append(character);
            }
        }

        if (current.Length > 0)
        {
            yield return current.ToString();
        }
    }

    private static IReadOnlyList<ProcessAncestor> BuildAncestry(
        Dictionary<int, WmiProcess> table,
        WmiProcess process)
    {
        var ancestry = new List<ProcessAncestor>();
        var seen = new HashSet<int> { process.Pid };
        var current = process;

        for (var depth = 0; depth < MaxAncestryDepth; depth++)
        {
            if (!table.TryGetValue(current.ParentPid, out var parent) || !seen.Add(parent.Pid))
            {
                break;
            }

            // A parent that started after its child is not the real parent: the original
            // parent exited and Windows reissued its PID to something unrelated.
            if (parent.StartTimeUtc is not null
                && current.StartTimeUtc is not null
                && parent.StartTimeUtc > current.StartTimeUtc)
            {
                break;
            }

            ancestry.Add(ToAncestor(parent));
            current = parent;
        }

        return ancestry;
    }

    private static ProcessAncestor ToAncestor(WmiProcess process) => new(
        process.Pid,
        process.Name,
        Fallback(process.ExecutablePath),
        Fallback(process.CommandLine),
        process.StartTimeUtc);

    private Dictionary<int, WmiProcess> GetProcessTable()
    {
        var now = _timeProvider.GetUtcNow();

        if (_cache is not null && now - _cachedAt < CacheLifetime)
        {
            return _cache;
        }

        var table = new Dictionary<int, WmiProcess>(400);

        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, CreationDate, SessionId "
                    + "FROM Win32_Process");
            using var results = searcher.Get();

            foreach (var row in results)
            {
                using var process = (ManagementObject)row;

                var pid = ToInt(process["ProcessId"]);
                if (pid is null)
                {
                    continue;
                }

                table[pid.Value] = new WmiProcess(
                    Pid: pid.Value,
                    ParentPid: ToInt(process["ParentProcessId"]) ?? -1,
                    Name: process["Name"] as string ?? "(unknown)",
                    ExecutablePath: process["ExecutablePath"] as string ?? "",
                    CommandLine: process["CommandLine"] as string ?? "",
                    SessionId: ToInt(process["SessionId"]) ?? -1,
                    StartTimeUtc: ToUtc(process["CreationDate"] as string));
            }
        }
        catch (ManagementException ex)
        {
            _logger.LogWarning(ex, "WMI process enumeration failed; breach detail will be limited");
        }
        catch (UnauthorizedAccessException ex)
        {
            _logger.LogWarning(ex, "Not permitted to enumerate processes via WMI; run the service with more privilege");
        }

        _cache = table;
        _cachedAt = now;
        return table;
    }

    private string ResolveOwner(int pid)
    {
        try
        {
            using var process = new ManagementObject($"Win32_Process.Handle='{pid}'");
            using var result = process.InvokeMethod("GetOwner", null, null);

            if (result is null)
            {
                return "(unknown)";
            }

            var user = result["User"] as string;
            var domain = result["Domain"] as string;

            if (string.IsNullOrEmpty(user))
            {
                return "(unknown)";
            }

            return string.IsNullOrEmpty(domain) ? user : domain + "\\" + user;
        }
        catch (Exception ex) when (ex is ManagementException or UnauthorizedAccessException)
        {
            // System and protected processes refuse GetOwner; the rest of the record is
            // still worth reporting.
            return "(unavailable)";
        }
    }

    private static int? ToInt(object? value) => value is null ? null : Convert.ToInt32(value);

    private static DateTime? ToUtc(string? wmiDate)
    {
        if (string.IsNullOrWhiteSpace(wmiDate))
        {
            return null;
        }

        try
        {
            return ManagementDateTimeConverter.ToDateTime(wmiDate).ToUniversalTime();
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static string Fallback(string value) =>
        string.IsNullOrWhiteSpace(value) ? "(unavailable)" : value;

    private sealed record WmiProcess(
        int Pid,
        int ParentPid,
        string Name,
        string ExecutablePath,
        string CommandLine,
        int SessionId,
        DateTime? StartTimeUtc);
}
