using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Hosted background service that:
///   1. Generates RCM JSON for all labs at application startup.
///   2. Watches each lab's <see cref="LabCsvConfig.ProductionMasterCsvPath"/> folder tree
///      for new or changed "Claim Level" CSV files and regenerates the lab's RCM JSON
///      automatically — no restart required.
/// One <see cref="FileSystemWatcher"/> is created per lab that has RCMJsonPath configured.
/// </summary>
internal sealed class RcmFileWatcherService : IHostedService, IDisposable
{
    // Debounce: ignore repeat events within this window (file copy/save fires multiple events)
    private static readonly TimeSpan DebounceDelay = TimeSpan.FromSeconds(5);

    private readonly LabSettings          _labSettings;
    private readonly RcmJsonWriterService _writer;
    private readonly ILogger<RcmFileWatcherService> _logger;

    // One watcher per lab; keyed by lab name
    private readonly List<FileSystemWatcher> _watchers = [];

    // Per-lab debounce timers; keyed by lab name
    private readonly Dictionary<string, Timer> _debounceTimers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock _timerLock = new();

    public RcmFileWatcherService(
        LabSettings          labSettings,
        RcmJsonWriterService writer,
        ILogger<RcmFileWatcherService> logger)
    {
        _labSettings = labSettings;
        _writer      = writer;
        _logger      = logger;
    }

    // ?? IHostedService ????????????????????????????????????????????????????????

    public Task StartAsync(CancellationToken cancellationToken)
    {
        // 1. Initial generation — run on a thread-pool thread so startup is not blocked
        _ = Task.Run(() =>
        {
            try
            {
                _logger.LogInformation("[RCM Watcher] Running startup GenerateAll…");
                _writer.GenerateAll();
                _logger.LogInformation("[RCM Watcher] Startup GenerateAll complete.");
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[RCM Watcher] Startup GenerateAll failed.");
            }
        }, cancellationToken);

        // 2. Set up watchers per lab
        foreach (var (labName, config) in _labSettings.Labs)
        {
            if (string.IsNullOrWhiteSpace(config.RCMJsonPath))
                continue;

            // Watch CSV source folder — react to new/changed Claim Level CSVs
            if (!string.IsNullOrWhiteSpace(config.ProductionMasterCsvPath) &&
                Directory.Exists(config.ProductionMasterCsvPath))
            {
                AddCsvWatcher(config.ProductionMasterCsvPath, labName, config);
            }

            // Watch RCMJsonPath — react to JSON deletions so the file is rebuilt immediately
            if (Directory.Exists(config.RCMJsonPath))
            {
                AddJsonDeletionWatcher(config.RCMJsonPath, labName, config);
            }
        }

        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        // Disable all watchers cleanly
        foreach (var w in _watchers)
            w.EnableRaisingEvents = false;

        _logger.LogInformation("[RCM Watcher] Stopped.");
        return Task.CompletedTask;
    }

    // ?? Watcher factories ?????????????????????????????????????????????????????

    /// <summary>Watches for new/changed Claim Level CSVs in the source folder.</summary>
    private void AddCsvWatcher(string folder, string labName, LabCsvConfig config)
    {
        var w = new FileSystemWatcher(folder, "*.csv")
        {
            IncludeSubdirectories = true,
            NotifyFilter          = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            EnableRaisingEvents   = true,
        };
        w.Created += (_, e) => OnCsvEvent(labName, config, e.FullPath);
        w.Changed += (_, e) => OnCsvEvent(labName, config, e.FullPath);
        w.Renamed += (_, e) => OnCsvEvent(labName, config, e.FullPath);
        w.Error   += (_, e) => _logger.LogError(
            "[RCM Watcher] CSV watcher error for '{Lab}': {Msg}", labName, e.GetException().Message);
        _watchers.Add(w);
        _logger.LogInformation("[RCM Watcher] '{Lab}' watching CSV source: {Folder}", labName, folder);
    }

    /// <summary>Watches the RCMJsonPath folder for JSON deletions and rebuilds immediately.</summary>
    private void AddJsonDeletionWatcher(string folder, string labName, LabCsvConfig config)
    {
        var w = new FileSystemWatcher(folder, "*_RCM*.json")
        {
            IncludeSubdirectories = false,
            NotifyFilter          = NotifyFilters.FileName,
            EnableRaisingEvents   = true,
        };
        w.Deleted += (_, e) => OnJsonDeleted(labName, config, e.FullPath);
        w.Error   += (_, e) => _logger.LogError(
            "[RCM Watcher] JSON watcher error for '{Lab}': {Msg}", labName, e.GetException().Message);
        _watchers.Add(w);
        _logger.LogInformation("[RCM Watcher] '{Lab}' watching JSON output: {Folder}", labName, folder);
    }

    // ?? Event handlers ????????????????????????????????????????????????????????

    private void OnCsvEvent(string labName, LabCsvConfig config, string fullPath)
    {
        if (!Path.GetFileName(fullPath).Contains("Claim Level", StringComparison.OrdinalIgnoreCase))
            return;

        _logger.LogInformation(
            "[RCM Watcher] '{Lab}' — Claim Level CSV event: {File}", labName, fullPath);
        ScheduleRegeneration(labName, config);
    }

    private void OnJsonDeleted(string labName, LabCsvConfig config, string fullPath)
    {
        _logger.LogInformation(
            "[RCM Watcher] '{Lab}' — RCM JSON deleted: {File} — scheduling rebuild.", labName, fullPath);
        ScheduleRegeneration(labName, config);
    }

    private void ScheduleRegeneration(string labName, LabCsvConfig config)
    {
        // Debounce: collapse rapid events into one regeneration after DebounceDelay of silence
        lock (_timerLock)
        {
            if (_debounceTimers.TryGetValue(labName, out var existing))
            {
                existing.Change(DebounceDelay, Timeout.InfiniteTimeSpan);
            }
            else
            {
                _debounceTimers[labName] = new Timer(
                    _ => RegenerateForLab(labName, config),
                    state: null, DebounceDelay, Timeout.InfiniteTimeSpan);
            }
        }
    }

    private void RegenerateForLab(string labName, LabCsvConfig config)
    {
        lock (_timerLock)
        {
            if (_debounceTimers.TryGetValue(labName, out var t))
            {
                t.Dispose();
                _debounceTimers.Remove(labName);
            }
        }

        _logger.LogInformation("[RCM Watcher] Regenerating RCM JSON for '{Lab}'…", labName);

        try   { _writer.Generate(labName, config); }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[RCM Watcher] Regeneration failed for '{Lab}'.", labName);
        }
    }

    // ?? IDisposable ???????????????????????????????????????????????????????????

    public void Dispose()
    {
        foreach (var w in _watchers)
            w.Dispose();

        lock (_timerLock)
        {
            foreach (var t in _debounceTimers.Values)
                t.Dispose();
            _debounceTimers.Clear();
        }
    }
}

