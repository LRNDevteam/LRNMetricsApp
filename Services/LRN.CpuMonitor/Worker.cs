using System.Text.Json;
using LRN.CpuMonitor.Models;
using LRN.CpuMonitor.Services;
using Microsoft.Extensions.Options;

namespace LRN.CpuMonitor;

public sealed class Worker : BackgroundService
{
    /// <summary>
    /// Log category for threshold breaches. Serilog surfaces this as SourceContext,
    /// which is what routes these events into their own file in addition to the main
    /// log. Referenced by the sink filter in Program.
    /// </summary>
    public const string BreachLoggerCategory = "CpuBreach";

    private readonly ILogger<Worker> _logger;

    /// <summary>
    /// Separate category so breaches land in a dedicated log rather than being mixed
    /// in with routine cycle output.
    /// </summary>
    private readonly ILogger _breachLogger;

    private readonly ICpuSampler _sampler;
    private readonly IProcessInspector _inspector;
    private readonly ISqlActivityProbe _sqlProbe;
    private readonly IOptionsMonitor<CpuMonitorSettings> _settings;
    private readonly TimeProvider _timeProvider;

    /// <summary>
    /// Breach state per PID. A process has to stay hot across several windows before it
    /// is reported, so the run of consecutive breaches has to be remembered between
    /// cycles rather than judged from a single reading.
    /// </summary>
    private readonly Dictionary<int, BreachState> _breachStates = [];

    /// <summary>
    /// Null until the first heartbeat is written, which makes the service log its
    /// observed usage once shortly after start rather than staying silent for a
    /// whole interval.
    /// </summary>
    private DateTimeOffset? _lastHeartbeat;
    private int _machineBreachSamples;
    private DateTimeOffset? _lastMachineAlertAt;

    public Worker(
        ILogger<Worker> logger,
        ILoggerFactory loggerFactory,
        ICpuSampler sampler,
        IProcessInspector inspector,
        ISqlActivityProbe sqlProbe,
        IOptionsMonitor<CpuMonitorSettings> settings,
        TimeProvider timeProvider)
    {
        _logger = logger;
        _breachLogger = loggerFactory.CreateLogger(BreachLoggerCategory);
        _sampler = sampler;
        _inspector = inspector;
        _sqlProbe = sqlProbe;
        _settings = settings;
        _timeProvider = timeProvider;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var startup = _settings.CurrentValue;

        // Emitted on the breach logger as well, so the breach log states the settings
        // it is filtering on. An empty breach log is otherwise indistinguishable from
        // a misconfigured threshold.
        foreach (var log in new[] { _logger, _breachLogger })
        {
            log.LogInformation(
                "CPU monitor started. Logging any process over {Threshold}% ({Scale}); "
                    + "machine-total alert at {MachineThreshold}%; sample window {WindowSeconds}s; "
                    + "poll interval {PollSeconds}s; alert after {ConsecutiveSamples} consecutive window(s); "
                    + "repeat cooldown {CooldownMinutes} min; {CoreCount} logical processor(s)",
                startup.CpuThresholdPercent,
                startup.NormalizeByCoreCount ? "whole machine, as Task Manager reports" : "per single core",
                startup.MachineCpuThresholdPercent,
                startup.SampleWindowSeconds,
                startup.PollIntervalSeconds,
                startup.ConsecutiveSamplesBeforeAlert,
                startup.AlertCooldownMinutes,
                Environment.ProcessorCount);
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            var settings = _settings.CurrentValue;

            try
            {
                if (settings.Enabled)
                {
                    await RunCycleAsync(settings, stoppingToken).ConfigureAwait(false);
                }
                else
                {
                    _logger.LogInformation("CPU monitoring is disabled by configuration");
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected CPU monitor cycle error");
            }

            try
            {
                await Task.Delay(PollInterval(settings), stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }

        _logger.LogInformation("CPU monitor stopping");
    }

    private async Task RunCycleAsync(CpuMonitorSettings settings, CancellationToken cancellationToken)
    {
        var snapshot = await _sampler
            .SampleAsync(SampleWindow(settings), settings.NormalizeByCoreCount, cancellationToken)
            .ConfigureAwait(false);

        var ignored = new HashSet<string>(settings.IgnoreProcessNames, StringComparer.OrdinalIgnoreCase);

        var hot = snapshot.Samples
            .Where(sample => sample.CpuPercent >= settings.CpuThresholdPercent)
            .Where(sample => !ignored.Contains(sample.ProcessName))
            .ToList();

        // Anything that cooled off or exited loses its run, so a later spike has to
        // build up a fresh streak before it alerts again.
        foreach (var pid in _breachStates.Keys.Except(hot.Select(sample => sample.Pid)).ToList())
        {
            _breachStates.Remove(pid);
        }

        _logger.LogDebug(
            "Sampled {ProcessCount} process(es) over {WindowMs}ms; machine CPU ~{MachineCpu:F1}%; {HotCount} over threshold",
            snapshot.Samples.Count,
            snapshot.Window.TotalMilliseconds,
            snapshot.MachineCpuPercent,
            hot.Count);

        var now = _timeProvider.GetUtcNow();

        WriteHeartbeatIfDue(settings, snapshot, now, hot.Count);
        EvaluateMachineLoad(settings, snapshot, now, hot.Count);

        foreach (var sample in hot)
        {
            if (!_breachStates.TryGetValue(sample.Pid, out var state))
            {
                state = new BreachState();
                _breachStates[sample.Pid] = state;
            }

            state.ConsecutiveSamples++;

            if (state.ConsecutiveSamples < Math.Max(1, settings.ConsecutiveSamplesBeforeAlert))
            {
                continue;
            }

            if (state.LastAlertedAt is { } lastAlert
                && now - lastAlert < TimeSpan.FromMinutes(Math.Max(0, settings.AlertCooldownMinutes)))
            {
                continue;
            }

            state.LastAlertedAt = now;

            await ReportBreachAsync(settings, sample, snapshot, state.ConsecutiveSamples, cancellationToken)
                .ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Records the top consumers periodically so the log distinguishes "watching, all
    /// quiet" from "service is wedged", and shows what the threshold is competing
    /// against on this machine.
    /// </summary>
    private void WriteHeartbeatIfDue(
        CpuMonitorSettings settings,
        CpuSnapshot snapshot,
        DateTimeOffset now,
        int breachingCount)
    {
        if (settings.HeartbeatMinutes <= 0)
        {
            return;
        }

        if (_lastHeartbeat is { } last && now - last < TimeSpan.FromMinutes(settings.HeartbeatMinutes))
        {
            return;
        }

        _lastHeartbeat = now;

        var top = snapshot.Samples.Take(3).ToList();
        var summary = top.Count == 0
            ? "nothing measurable"
            : string.Join(", ", top.Select(s => $"{s.ProcessName} (PID {s.Pid}) {s.CpuPercent:F1}%"));

        _logger.LogInformation(
            "Heartbeat: {ProcessCount} process(es) used CPU this window, machine CPU ~{MachineCpuPercent:F1}%, "
                + "threshold {Threshold}% ({Scale}), {BreachingCount} over threshold. Top consumers: {TopConsumers}",
            snapshot.Samples.Count,
            snapshot.MachineCpuPercent,
            settings.CpuThresholdPercent,
            settings.NormalizeByCoreCount ? "whole machine" : "per core",
            breachingCount,
            summary);
    }

    /// <summary>
    /// Catches the case a per-process threshold cannot: the machine is saturated but
    /// the load is split across many processes, so nothing individually looks guilty.
    /// Names the top consumers together so the aggregate has an owner.
    /// </summary>
    private void EvaluateMachineLoad(
        CpuMonitorSettings settings,
        CpuSnapshot snapshot,
        DateTimeOffset now,
        int breachingCount)
    {
        if (settings.MachineCpuThresholdPercent <= 0
            || snapshot.MachineCpuPercent < settings.MachineCpuThresholdPercent)
        {
            _machineBreachSamples = 0;
            return;
        }

        _machineBreachSamples++;

        if (_machineBreachSamples < Math.Max(1, settings.ConsecutiveSamplesBeforeAlert))
        {
            return;
        }

        if (_lastMachineAlertAt is { } last
            && now - last < TimeSpan.FromMinutes(Math.Max(0, settings.AlertCooldownMinutes)))
        {
            return;
        }

        _lastMachineAlertAt = now;

        var top = snapshot.Samples
            .Take(Math.Clamp(settings.MachineTopConsumers, 1, 20))
            .ToList();

        _breachLogger.LogWarning(
            "MACHINE HIGH CPU: total ~{MachineCpuPercent:F1}% for {ConsecutiveSamples} consecutive window(s), "
                + "threshold {MachineThreshold}%. {BreachingCount} process(es) individually over "
                + "{ProcessThreshold}%. Top {TopCount} consumer(s) follow.",
            snapshot.MachineCpuPercent,
            _machineBreachSamples,
            settings.MachineCpuThresholdPercent,
            breachingCount,
            settings.CpuThresholdPercent,
            top.Count);

        foreach (var sample in top)
        {
            var details = _inspector.Describe(sample.Pid);

            _breachLogger.LogWarning(
                "  Machine load contributor: {ProcessName} (PID {Pid}) at {CpuPercent:F1}%. "
                    + "Path: {ExecutablePath}. Owner: {Owner}. Launched by: {ParentChain}",
                sample.ProcessName,
                sample.Pid,
                sample.CpuPercent,
                details?.ExecutablePath ?? "(exited)",
                details?.Owner ?? "(exited)",
                details is null ? "(exited)" : FormatAncestry(details.Ancestry));
        }

        WriteMachineBreachRecord(settings, snapshot, top);
    }

    private async Task ReportBreachAsync(
        CpuMonitorSettings settings,
        ProcessCpuSample sample,
        CpuSnapshot snapshot,
        int consecutiveSamples,
        CancellationToken cancellationToken)
    {
        var details = _inspector.Describe(sample.Pid);

        if (details is null)
        {
            _breachLogger.LogWarning(
                "{ProcessName} (PID {Pid}) held {CpuPercent:F1}% CPU across {ConsecutiveSamples} window(s) "
                    + "but exited before it could be identified",
                sample.ProcessName,
                sample.Pid,
                sample.CpuPercent,
                consecutiveSamples);
            return;
        }

        _breachLogger.LogWarning(
            "HIGH CPU: {ProcessName} (PID {Pid}) at {CpuPercent:F1}%, over the configured {Threshold}% "
                + "({Scale}), for {ConsecutiveSamples} consecutive window(s). "
                + "Path: {ExecutablePath}. Owner: {Owner}. Session: {SessionId}. Started: {StartTimeUtc:u}. "
                + "Machine CPU ~{MachineCpuPercent:F1}%. Command line: {CommandLine}. Launched by: {ParentChain}",
            details.Name,
            details.Pid,
            sample.CpuPercent,
            settings.CpuThresholdPercent,
            settings.NormalizeByCoreCount ? "share of whole machine, as Task Manager shows" : "share of one core",
            consecutiveSamples,
            details.ExecutablePath,
            details.Owner,
            details.SessionId,
            details.StartTimeUtc,
            snapshot.MachineCpuPercent,
            details.CommandLine,
            FormatAncestry(details.Ancestry));

        var sqlRequests = IsMatch(settings.SqlProcessNames, sample.ProcessName)
            ? await ProbeSqlAsync(settings, cancellationToken).ConfigureAwait(false)
            : [];

        var officeOrigin = IsMatch(settings.OfficeProcessNames, sample.ProcessName)
            ? ReportOfficeOrigin(details)
            : null;

        WriteBreachRecord(settings, sample, snapshot, details, sqlRequests, officeOrigin);
    }

    /// <summary>
    /// SQL Server multiplexes every caller through one process, so the breach is
    /// attributed by asking the engine which request is burning the CPU.
    /// </summary>
    private async Task<IReadOnlyList<SqlRequestActivity>> ProbeSqlAsync(
        CpuMonitorSettings settings,
        CancellationToken cancellationToken)
    {
        var requests = await _sqlProbe
            .GetTopCpuRequestsAsync(settings.SqlConnectionString, settings.SqlTopSessions, cancellationToken)
            .ConfigureAwait(false);

        if (requests.Count == 0)
        {
            _breachLogger.LogInformation(
                "No in-flight user requests were returned, so the CPU may be background engine work");
            return requests;
        }

        foreach (var request in requests)
        {
            _breachLogger.LogWarning(
                "  SQL culprit: session {SessionId} has used {CpuTimeMs}ms CPU over {ElapsedMs}ms running {Command} "
                    + "on {DatabaseName}. Client app: {ProgramName} on {HostName} (client PID {HostProcessId}), "
                    + "login {LoginName} via {ClientInterface}. Waiting on: {WaitType}. Blocked by: {BlockingSessionId}. "
                    + "Reads {LogicalReads}, writes {Writes}. Statement: {StatementText}",
                request.SessionId,
                request.CpuTimeMs,
                request.ElapsedMs,
                request.Command,
                request.DatabaseName,
                string.IsNullOrWhiteSpace(request.ProgramName) ? "(not set by client)" : request.ProgramName,
                string.IsNullOrWhiteSpace(request.HostName) ? "(unknown)" : request.HostName,
                request.HostProcessId,
                request.LoginName,
                request.ClientInterface,
                string.IsNullOrWhiteSpace(request.WaitType) ? "(running)" : request.WaitType,
                request.BlockingSessionId,
                request.LogicalReads,
                request.Writes,
                request.StatementText);
        }

        return requests;
    }

    private OfficeLaunchOrigin ReportOfficeOrigin(ProcessDetails details)
    {
        var origin = _inspector.ExplainOfficeLaunch(details);

        _breachLogger.LogWarning("  Office launch origin: {Kind}. {Explanation}", origin.Kind, origin.Explanation);

        foreach (var candidate in origin.CandidateAutomationClients)
        {
            _breachLogger.LogInformation(
                "    Possible automation client: {Name} (PID {Pid}) started {StartTimeUtc:u} -- {ExecutablePath}",
                candidate.Name,
                candidate.Pid,
                candidate.StartTimeUtc,
                candidate.ExecutablePath);
        }

        return origin;
    }

    /// <summary>
    /// Appends the breach as one JSON object per line, which keeps the history greppable
    /// and loadable without parsing the human-readable log.
    /// </summary>
    private void WriteBreachRecord(
        CpuMonitorSettings settings,
        ProcessCpuSample sample,
        CpuSnapshot snapshot,
        ProcessDetails details,
        IReadOnlyList<SqlRequestActivity> sqlRequests,
        OfficeLaunchOrigin? officeOrigin)
    {
        if (string.IsNullOrWhiteSpace(settings.BreachLogPath))
        {
            return;
        }

        try
        {
            var path = PrepareBreachLogPath(settings.BreachLogPath);

            var record = new
            {
                kind = "process",
                detectedAtUtc = _timeProvider.GetUtcNow(),
                machine = Environment.MachineName,
                processName = details.Name,
                pid = details.Pid,
                executablePath = details.ExecutablePath,
                commandLine = details.CommandLine,
                owner = details.Owner,
                sessionId = details.SessionId,
                startTimeUtc = details.StartTimeUtc,
                cpuPercent = Math.Round(sample.CpuPercent, 2),
                machineCpuPercent = Math.Round(snapshot.MachineCpuPercent, 2),
                thresholdPercent = settings.CpuThresholdPercent,
                ancestry = details.Ancestry.Select(ancestor => new
                {
                    ancestor.Pid,
                    ancestor.Name,
                    ancestor.ExecutablePath,
                }),
                office = officeOrigin is null
                    ? null
                    : new
                    {
                        kind = officeOrigin.Kind.ToString(),
                        officeOrigin.Explanation,
                        candidates = officeOrigin.CandidateAutomationClients
                            .Select(candidate => new { candidate.Pid, candidate.Name }),
                    },
                sqlRequests,
            };

            File.AppendAllText(path, JsonSerializer.Serialize(record) + Environment.NewLine);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Losing the machine-readable copy must not stop monitoring; the warning
            // above is already in the normal log.
            _logger.LogWarning(ex, "Could not append to the breach log at {BreachLogPath}", settings.BreachLogPath);
        }
    }

    /// <summary>
    /// The machine-level equivalent of <see cref="WriteBreachRecord"/>: one record for
    /// the whole event, carrying every contributor rather than a single offender.
    /// </summary>
    private void WriteMachineBreachRecord(
        CpuMonitorSettings settings,
        CpuSnapshot snapshot,
        IReadOnlyList<ProcessCpuSample> top)
    {
        if (string.IsNullOrWhiteSpace(settings.BreachLogPath))
        {
            return;
        }

        try
        {
            var path = PrepareBreachLogPath(settings.BreachLogPath);

            var record = new
            {
                kind = "machine",
                detectedAtUtc = _timeProvider.GetUtcNow(),
                machine = Environment.MachineName,
                machineCpuPercent = Math.Round(snapshot.MachineCpuPercent, 2),
                machineThresholdPercent = settings.MachineCpuThresholdPercent,
                processThresholdPercent = settings.CpuThresholdPercent,
                consecutiveSamples = _machineBreachSamples,
                contributors = top.Select(sample =>
                {
                    var details = _inspector.Describe(sample.Pid);
                    return new
                    {
                        processName = sample.ProcessName,
                        pid = sample.Pid,
                        cpuPercent = Math.Round(sample.CpuPercent, 2),
                        executablePath = details?.ExecutablePath,
                        commandLine = details?.CommandLine,
                        owner = details?.Owner,
                        sessionId = details?.SessionId,
                    };
                }),
            };

            File.AppendAllText(path, JsonSerializer.Serialize(record) + Environment.NewLine);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _logger.LogWarning(ex, "Could not append to the breach log at {BreachLogPath}", settings.BreachLogPath);
        }
    }

    private static string PrepareBreachLogPath(string configuredPath)
    {
        var path = Path.IsPathRooted(configuredPath)
            ? configuredPath
            : Path.Combine(AppContext.BaseDirectory, configuredPath);

        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        return path;
    }

    private static string FormatAncestry(IReadOnlyList<ProcessAncestor> ancestry) =>
        ancestry.Count == 0
            ? "(parent already exited)"
            : string.Join(" <- ", ancestry.Select(ancestor => $"{ancestor.Name} (PID {ancestor.Pid})"));

    private static bool IsMatch(string[] configuredNames, string processName) =>
        configuredNames.Any(name => name.Equals(processName, StringComparison.OrdinalIgnoreCase));

    private static TimeSpan SampleWindow(CpuMonitorSettings settings) =>
        TimeSpan.FromSeconds(settings.SampleWindowSeconds > 0 ? settings.SampleWindowSeconds : 5);

    private static TimeSpan PollInterval(CpuMonitorSettings settings) =>
        TimeSpan.FromSeconds(settings.PollIntervalSeconds > 0 ? settings.PollIntervalSeconds : 10);

    private sealed class BreachState
    {
        public int ConsecutiveSamples { get; set; }

        public DateTimeOffset? LastAlertedAt { get; set; }
    }
}
