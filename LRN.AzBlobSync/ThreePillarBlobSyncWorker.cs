using System.Text.Json;
using LRN.AzBlobSync.Models;
using LRN.AzBlobSync.Services;

namespace LRN.AzBlobSync;

/// <summary>
/// One-shot run: if a week folder newer than the last completed sync exists
/// and has LIS/PMS/Cash, connect to Blob and upload. Otherwise log skip and exit.
/// When BlobSync:RefreshData is true, force re-upload the latest ready week and
/// regenerate insights.json even if that week was already processed.
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
                "[BlobSync] Start. Watch={Path} Container={Container} Prefix={Prefix} RefreshData={Refresh} Log={Log}",
                _options.WatchPath, _options.ContainerName, _options.BlobPrefix,
                _options.RefreshData, _options.LogPath);

            var uploadedWeeks = await RunOnceAsync(stoppingToken);
            if (uploadedWeeks.Count == 0)
            {
                _logger.LogInformation(
                    "[Foundry] No Beech_Tree_inputs uploaded this run. Skipping insight generation.");
            }
            else
            {
                foreach (var week in uploadedWeeks)
                {
                    try
                    {
                        await _insights.RunForWeekAsync(week, stoppingToken);
                    }
                    catch (Exception ex)
                    {
                        Environment.ExitCode = 1;
                        _logger.LogError(ex,
                            "[Foundry] Insight generation failed for '{Week}'. {Message}",
                            week, ex.Message);
                    }
                }
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

    /// <returns>Week folder names uploaded this run; empty when blob copy was skipped.</returns>
    private async Task<IReadOnlyList<string>> RunOnceAsync(CancellationToken ct)
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

        List<(DirectoryInfo Week, List<FileInfo> Files)> toUpload;

        if (_options.RefreshData)
        {
            _logger.LogInformation(
                "[BlobSync] RefreshData=true — force re-upload latest ready week and regenerate insights.json.");
            toUpload = ResolveRefreshUpload(weeks);
            if (toUpload.Count == 0)
            {
                _logger.LogInformation(
                    "[BlobSync] RefreshData=true but no ready week folder with LIS/PMS/Cash. Skipping.");
                return [];
            }
        }
        else
        {
            toUpload = ResolveNewUploads(weeks, lastCompleted);
            if (toUpload.Count == 0)
            {
                _logger.LogInformation(
                    "[BlobSync] No new folder since '{Last}'. Skipping blob. Exiting.",
                    string.IsNullOrWhiteSpace(lastCompleted) ? "(none)" : lastCompleted);
                return [];
            }
        }

        _logger.LogInformation(
            "[BlobSync] Folder(s) to upload{Mode}: {Folders}",
            _options.RefreshData ? " (refresh)" : "",
            string.Join(", ", toUpload.Select(x => x.Week.Name)));

        await _uploader.EnsureDestinationAsync(ct);

        foreach (var (week, jsonFiles) in toUpload)
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

        var newest = toUpload[^1].Week.Name;
        state.RecentFolderName = newest;
        state.UploadedUtc = DateTimeOffset.UtcNow;
        state.BlobPrefix = $"{_options.BlobPrefix.Trim('/')}/{newest}";
        state.FileCount = state.ProcessedFolders[newest].FileCount;
        _stateStore.Save(state);
        await _uploader.UploadLatestStateAsync(JsonSerializer.Serialize(state, JsonOpts), ct);

        _logger.LogInformation("[BlobSync] Last completed folder (this run): {Folder}", newest);
        _logger.LogInformation(
            "[BlobSync] Summary: folders={Count} uploaded={Uploaded} lastCompleted='{Recent}' refresh={Refresh}",
            toUpload.Count, toUpload.Count, newest, _options.RefreshData);

        return toUpload.Select(x => x.Week.Name).ToList();
    }

    private List<(DirectoryInfo Week, List<FileInfo> Files)> ResolveNewUploads(
        IReadOnlyList<DirectoryInfo> weeks, string lastCompleted)
    {
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

        return newReady
            .OrderBy(x => WeekFolderScanner.WeekSortKey(x.Week.Name))
            .ToList();
    }

    /// <summary>
    /// Refresh mode: re-upload the newest ready week (typically the last completed one),
    /// overwriting blob inputs and driving a new insights.json.
    /// </summary>
    private List<(DirectoryInfo Week, List<FileInfo> Files)> ResolveRefreshUpload(
        IReadOnlyList<DirectoryInfo> weeks)
    {
        // weeks are already newest-first from ListWeekFolders.
        foreach (var week in weeks)
        {
            if (!_scanner.TryGetReadyJsonFiles(week, out var jsonFiles, out var reason))
            {
                _logger.LogInformation(
                    "[BlobSync] Refresh candidate '{Week}' not ready — {Reason}.",
                    week.Name, reason);
                continue;
            }

            _logger.LogInformation(
                "[BlobSync] Refresh target week '{Week}' ({Count} JSON files).",
                week.Name, jsonFiles.Count);
            return [(week, jsonFiles)];
        }

        return [];
    }
}
