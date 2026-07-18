using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.ReportWorker;

/// <summary>
/// Daily cleanup (default 02:00 local):
///   1. usp_ExpireUserReqReports  — Completed/Downloaded past ExpiryDate → Expired,
///      returns file paths; physical files deleted here (missing file = log + skip);
///   2. usp_PurgeUserReqReports   — hard-deletes old terminal rows, trims audit;
///   3. prunes empty user/month folders under the storage root.
/// Files deleted immediately by user Delete are handled in the web app; this
/// sweep is the safety net that guarantees the one-week retention policy.
/// </summary>
public sealed class ReportCleanupWorker : BackgroundService
{
    private readonly IReportRequestRepository _repo;
    private readonly ReportStorageOptions _storage;
    private readonly ReportWorkerOptions _options;
    private readonly ILogger<ReportCleanupWorker> _logger;

    public ReportCleanupWorker(
        IReportRequestRepository repo,
        IOptions<ReportStorageOptions> storage,
        IOptions<ReportWorkerOptions> options,
        ILogger<ReportCleanupWorker> logger)
    {
        _repo    = repo;
        _storage = storage.Value;
        _options = options.Value;
        _logger  = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            var delay = DelayUntilNextRun();
            _logger.LogInformation("Next report cleanup in {Delay:hh\\:mm\\:ss}.", delay);

            try { await Task.Delay(delay, stoppingToken); }
            catch (OperationCanceledException) { break; }

            await RunCleanupAsync(stoppingToken);
        }
    }

    private TimeSpan DelayUntilNextRun()
    {
        if (!TimeSpan.TryParse(_options.CleanupTime, out var timeOfDay))
            timeOfDay = new TimeSpan(2, 0, 0);

        var now = DateTime.Now;
        var next = now.Date + timeOfDay;
        if (next <= now) next = next.AddDays(1);
        return next - now;
    }

    internal async Task RunCleanupAsync(CancellationToken ct)
    {
        var labs = LabDbConfigLoader.LoadAll(_options.LabConfigFolder, _options.Labs);
        var totalExpired = 0;
        var totalDeleted = 0;
        var totalMissing = 0;

        foreach (var lab in labs)
        {
            if (ct.IsCancellationRequested) break;
            try
            {
                var expired = await _repo.ExpireAsync(lab.DbConnectionString!, ReportJobProcessor.WorkerName, ct);
                totalExpired += expired.Count;

                foreach (var file in expired)
                {
                    if (string.IsNullOrWhiteSpace(file.FilePath)) continue;
                    try
                    {
                        if (File.Exists(file.FilePath))
                        {
                            File.Delete(file.FilePath);
                            totalDeleted++;
                        }
                        else
                        {
                            totalMissing++;
                            _logger.LogWarning(
                                "Expired report {ReportId}: file already missing ({Path}) — status updated, continuing.",
                                file.ReportId, file.FilePath);
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger.LogWarning(ex,
                            "Could not delete expired file for report {ReportId} ({Path}); will retry next sweep via purge window.",
                            file.ReportId, file.FilePath);
                    }
                }

                await _repo.PurgeAsync(lab.DbConnectionString!, _options.PurgeAfterDays, _options.AuditRetentionDays, ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Cleanup failed for lab {Lab}; other labs continue.", lab.LabName);
            }
        }

        PruneEmptyFolders();

        _logger.LogInformation(
            "Cleanup done: {Expired} expired, {Deleted} files deleted, {Missing} already missing.",
            totalExpired, totalDeleted, totalMissing);
    }

    private void PruneEmptyFolders()
    {
        try
        {
            if (!Directory.Exists(_storage.RootPath)) return;
            foreach (var dir in Directory.EnumerateDirectories(_storage.RootPath, "*", SearchOption.AllDirectories)
                                         .OrderByDescending(d => d.Length)) // deepest first
            {
                if (!Directory.EnumerateFileSystemEntries(dir).Any())
                    Directory.Delete(dir);
            }
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Empty-folder prune skipped.");
        }
    }
}
