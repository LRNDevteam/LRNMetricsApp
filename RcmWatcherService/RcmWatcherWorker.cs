using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using RcmWatcherService.Models;
using RcmWatcherService.Services;

namespace RcmWatcherService;

/// <summary>
/// Windows Service worker that:
///   1. Generates RCM JSON for all labs on startup (fills any gaps).
///   2. Watches each lab's CSV source folder for new/changed Claim Level CSVs.
///   3. Watches each lab's RCMJsonPath for JSON deletions.
/// Reacts automatically without any restart.
/// </summary>
internal sealed class RcmWatcherWorker : BackgroundService
{
    private static readonly TimeSpan DebounceDelay = TimeSpan.FromSeconds(5);

    private readonly LabSettings              _labSettings;
    private readonly RcmJsonWriterService     _writer;
    private readonly ILogger<RcmWatcherWorker> _logger;

    private readonly List<FileSystemWatcher>        _watchers       = [];
    private readonly Dictionary<string, Timer>      _debounceTimers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock                           _timerLock      = new();

    public RcmWatcherWorker(
        LabSettings              labSettings,
        RcmJsonWriterService     writer,
        ILogger<RcmWatcherWorker> logger)
    {
        _labSettings = labSettings;
        _writer      = writer;
        _logger      = logger;
    }

    // ?? BackgroundService ?????????????????????????????????????????????????????

    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // 1. Generate missing/stale JSON on startup
        _logger.LogInformation("[RCM Worker] Running startup GenerateAll…");
        try   { _writer.GenerateAll(); }
        catch (Exception ex) { _logger.LogError(ex, "[RCM Worker] Startup GenerateAll failed."); }
        _logger.LogInformation("[RCM Worker] Startup GenerateAll complete.");

        // 2. Set up file watchers for every configured lab
        foreach (var (labName, config) in _labSettings.Labs)
        {
            if (string.IsNullOrWhiteSpace(config.RCMJsonPath))
                continue;

            if (!string.IsNullOrWhiteSpace(config.ProductionMasterCsvPath) &&
                Directory.Exists(config.ProductionMasterCsvPath))
            {
                AddCsvWatcher(config.ProductionMasterCsvPath, labName, config);
            }
            else
            {
                _logger.LogWarning(
                    "[RCM Worker] '{Lab}' CSV source folder missing: {Path}",
                    labName, config.ProductionMasterCsvPath);
            }

            if (Directory.Exists(config.RCMJsonPath))
                AddJsonDeletionWatcher(config.RCMJsonPath, labName, config);
        }

        // Keep the worker alive until cancellation
        return Task.Delay(Timeout.Infinite, stoppingToken);
    }

    public override Task StopAsync(CancellationToken cancellationToken)
    {
        foreach (var w in _watchers)
            w.EnableRaisingEvents = false;

        lock (_timerLock)
        {
            foreach (var t in _debounceTimers.Values)
                t.Dispose();
            _debounceTimers.Clear();
        }

        _logger.LogInformation("[RCM Worker] Stopped ({Count} watchers disposed).", _watchers.Count);
        return base.StopAsync(cancellationToken);
    }

    // ?? Watcher factories ?????????????????????????????????????????????????????

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
            "[RCM Worker] CSV watcher error '{Lab}': {Msg}", labName, e.GetException().Message);
        _watchers.Add(w);
        _logger.LogInformation("[RCM Worker] '{Lab}' watching CSV source: {Folder}", labName, folder);
    }

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
            "[RCM Worker] JSON watcher error '{Lab}': {Msg}", labName, e.GetException().Message);
        _watchers.Add(w);
        _logger.LogInformation("[RCM Worker] '{Lab}' watching JSON output: {Folder}", labName, folder);
    }

    // ?? Event handlers ????????????????????????????????????????????????????????

    private void OnCsvEvent(string labName, LabCsvConfig config, string fullPath)
    {
        if (!Path.GetFileName(fullPath).Contains("Claim Level", StringComparison.OrdinalIgnoreCase))
            return;

        _logger.LogInformation(
            "[RCM Worker] '{Lab}' — Claim Level CSV event: {File}", labName, fullPath);
        ScheduleRegeneration(labName, config);
    }

    private void OnJsonDeleted(string labName, LabCsvConfig config, string fullPath)
    {
        _logger.LogInformation(
            "[RCM Worker] '{Lab}' — RCM JSON deleted: {File} — scheduling rebuild.", labName, fullPath);
        ScheduleRegeneration(labName, config);
    }

    private void ScheduleRegeneration(string labName, LabCsvConfig config)
    {
        lock (_timerLock)
        {
            if (_debounceTimers.TryGetValue(labName, out var existing))
                existing.Change(DebounceDelay, Timeout.InfiniteTimeSpan);
            else
                _debounceTimers[labName] = new Timer(
                    _ => RegenerateForLab(labName, config),
                    state: null, DebounceDelay, Timeout.InfiniteTimeSpan);
        }
    }

    private void RegenerateForLab(string labName, LabCsvConfig config)
    {
        lock (_timerLock)
        {
            if (_debounceTimers.TryGetValue(labName, out var t))
            { t.Dispose(); _debounceTimers.Remove(labName); }
        }

        _logger.LogInformation("[RCM Worker] Regenerating RCM JSON for '{Lab}'…", labName);
        try   { _writer.Generate(labName, config); }
        catch (Exception ex)
        { _logger.LogError(ex, "[RCM Worker] Regeneration failed for '{Lab}'.", labName); }
    }
}
