using System.Text.Json;
using LRN.AzBlobSync.Models;
using LRN.AzBlobSync.Services;

namespace LRN.AzBlobSync;

/// <summary>
/// One-shot run: if a week folder newer than the last completed sync exists
/// and has LIS/PMS/Cash, connect to Blob and upload. Otherwise log skip and exit.
/// Errors are logged and the process exits with code 1.
/// </summary>
public sealed class ThreePillarBlobSyncWorker : BackgroundService
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly BlobSyncOptions _options;
    private readonly WeekFolderScanner _scanner;
    private readonly AzureBlobUploader _uploader;
    private readonly LatestFolderStateStore _stateStore;
    private readonly ThreePillarInsightGenerator _insights;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly ILogger<ThreePillarBlobSyncWorker> _logger;

    public ThreePillarBlobSyncWorker(
        BlobSyncOptions options,
        WeekFolderScanner scanner,
        AzureBlobUploader uploader,
        LatestFolderStateStore stateStore,
        ThreePillarInsightGenerator insights,
        IHostApplicationLifetime lifetime,
        ILogger<ThreePillarBlobSyncWorker> logger)
    {
        _options = options;
        _scanner = scanner;
        _uploader = uploader;
        _stateStore = stateStore;
        _insights = insights;
        _lifetime = lifetime;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            _logger.LogInformation(
                "[BlobSync] Start. Watch={Path} Container={Container} Prefix={Prefix} Log={Log}",
                _options.WatchPath, _options.ContainerName, _options.BlobPrefix, _options.LogPath);

            await RunOnceAsync(stoppingToken);
            try
            {
                await _insights.RunForLatestWeekAsync(stoppingToken);
            }
            catch (Exception ex)
            {
                Environment.ExitCode = 1;
                _logger.LogError(ex, "[Foundry] Insight generation failed. {Message}", ex.Message);
            }

            if (Environment.ExitCode == 0)
                _logger.LogInformation("[BlobSync] Completed successfully. Exiting.");
            else
                _logger.LogWarning("[BlobSync] Finished with errors. Exit code {Code}.", Environment.ExitCode);
        }
        catch (Exception ex)
        {
            Environment.ExitCode = 1;
            _logger.LogError(ex, "[BlobSync] FAILED. {Message}", ex.Message);
        }
        finally
        {
            _lifetime.StopApplication();
        }
    }

    private async Task RunOnceAsync(CancellationToken ct)
    {
        var watch = _options.WatchPath;
        if (string.IsNullOrWhiteSpace(watch))
            throw new InvalidOperationException("BlobSync:WatchPath is empty.");

        if (!Directory.Exists(watch))
            throw new DirectoryNotFoundException($"Watch path does not exist: {watch}");

        var state = _stateStore.Load();
        var lastCompleted = state.RecentFolderName?.Trim() ?? string.Empty;
        _logger.LogInformation(
            "[BlobSync] Last completed folder: {Folder}",
            string.IsNullOrWhiteSpace(lastCompleted) ? "(none — first run)" : lastCompleted);

        var weeks = _scanner.ListWeekFolders();
        _logger.LogInformation("[BlobSync] Scan: {Count} week folder(s) under {Path}", weeks.Count, watch);

        var lastKey = string.IsNullOrWhiteSpace(lastCompleted)
            ? DateTime.MinValue
            : WeekFolderScanner.WeekSortKey(lastCompleted);

        var newReady = new List<(DirectoryInfo Week, List<FileInfo> Files)>();
        foreach (var week in weeks)
        {
            var isNew = string.IsNullOrWhiteSpace(lastCompleted)
                || WeekFolderScanner.WeekSortKey(week.Name) > lastKey;

            if (!isNew)
                continue;

            if (!_scanner.TryGetReadyJsonFiles(week, out var jsonFiles, out var reason))
            {
                _logger.LogInformation(
                    "[BlobSync] New folder '{Week}' is not ready — {Reason}. Will retry next run.",
                    week.Name, reason);
                continue;
            }

            newReady.Add((week, jsonFiles));
        }

        newReady = newReady
            .OrderBy(x => WeekFolderScanner.WeekSortKey(x.Week.Name))
            .ToList();

        if (newReady.Count == 0)
        {
            _logger.LogInformation(
                "[BlobSync] No new folder since '{Last}'. Skipping blob. Exiting.",
                string.IsNullOrWhiteSpace(lastCompleted) ? "(none)" : lastCompleted);
            return;
        }

        _logger.LogInformation(
            "[BlobSync] New folder(s) to upload: {Folders}",
            string.Join(", ", newReady.Select(x => x.Week.Name)));

        await _uploader.EnsureDestinationAsync(ct);

        foreach (var (week, jsonFiles) in newReady)
        {
            ct.ThrowIfCancellationRequested();

            _logger.LogInformation(
                "[BlobSync] Copying week folder '{Week}' ({Count} JSON files) to {Container}/{Prefix}/{Week}",
                week.Name, jsonFiles.Count, _options.ContainerName, _options.BlobPrefix, week.Name);

            var uploaded = await _uploader.UploadWeekFolderAsync(week, jsonFiles, ct);

            state.ProcessedFolders[week.Name] = new FolderUploadRecord
            {
                UploadedUtc = DateTimeOffset.UtcNow,
                Fingerprint = WeekFolderScanner.Fingerprint(jsonFiles),
                FileCount = uploaded,
            };

            _logger.LogInformation("[BlobSync] Done '{Week}' — {Count} file(s).", week.Name, uploaded);
        }

        var newest = newReady[^1].Week.Name;
        state.RecentFolderName = newest;
        state.UploadedUtc = DateTimeOffset.UtcNow;
        state.BlobPrefix = $"{_options.BlobPrefix.Trim('/')}/{newest}";
        state.FileCount = state.ProcessedFolders[newest].FileCount;
        _stateStore.Save(state);
        await _uploader.UploadLatestStateAsync(JsonSerializer.Serialize(state, JsonOpts), ct);

        _logger.LogInformation("[BlobSync] Last completed folder (this run): {Folder}", newest);
        _logger.LogInformation(
            "[BlobSync] Summary: newFolders={New} uploaded={Uploaded} lastCompleted='{Recent}'",
            newReady.Count, newReady.Count, newest);
    }
}
