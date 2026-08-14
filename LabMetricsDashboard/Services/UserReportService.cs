using LabMetricsDashboard.Models;
using LRN.ReportQueue.Shared;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Web-side facade over the per-lab UserReqReports queues.
/// Queue/download/delete/retry hit ONE lab DB; the badge/panel summary fans out
/// across every DB-enabled lab in parallel (queue tables live per lab DB).
/// A lab DB being down degrades that lab's rows only — never the whole panel.
/// </summary>
public sealed class UserReportService
{
    private readonly LabSettings _labSettings;
    private readonly IReportRequestRepository _repo;
    private readonly ILogger<UserReportService> _logger;

    public UserReportService(
        LabSettings labSettings,
        IReportRequestRepository repo,
        ILogger<UserReportService> logger,
        IConfiguration configuration)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;

        // The shared queue lab is loaded from its own {LabConfigFolder}\<name>.json and kept OUT
        // of LabSettings.Labs on purpose: controllers build their lab pickers from Labs.Keys, so
        // listing it there would offer "LRNMaster" as a selectable lab on every dashboard.
        var shared = configuration["Analytics:SharedReportLab"];
        if (string.IsNullOrWhiteSpace(shared)) shared = ReportQueueLabs.Master;

        var folder = configuration["LabConfig:LabConfigFolder"];
        var cfg = string.IsNullOrWhiteSpace(folder) ? null : LabDbConfigLoader.Load(folder, shared);
        if (cfg is { DbEnabled: true } && !string.IsNullOrWhiteSpace(cfg.DbConnectionString))
        {
            SharedReportLab = shared;
            _sharedConnectionString = cfg.DbConnectionString;
        }
        else
        {
            _logger.LogWarning(
                "Shared report lab '{Lab}' not found or not DB-enabled under '{Folder}' — cross-lab queued "
                + "reports (CPT & Panel Lookup) will fall back to the synchronous download.", shared, folder);
        }
    }

    /// <summary>
    /// Lab entry the cross-lab reports queue against — CPT &amp; Panel Lookup reads LRNMaster and
    /// has no owning lab, but the queue table lives in a lab DB. Null when it is not configured,
    /// which callers treat as "background export unavailable" rather than an error.
    /// </summary>
    public string? SharedReportLab { get; }

    private readonly string? _sharedConnectionString;

    /// <summary>
    /// Every lab whose UserReqReports queue this service reads or writes: the DB-enabled labs
    /// plus the shared cross-lab entry. Queue-only — not a list of labs to show a user.
    /// </summary>
    private IEnumerable<KeyValuePair<string, string>> QueueLabs()
    {
        foreach (var kv in _labSettings.Labs.Where(kv => IsReportQueueLab(kv.Value)))
            yield return new(kv.Key, kv.Value.DbConnectionString!);
        if (SharedReportLab is not null && _sharedConnectionString is not null)
            yield return new(SharedReportLab, _sharedConnectionString);
    }

    /// <summary>
    /// True when the lab has a SQL connection usable for the report queue
    /// (Prediction DB and/or Claim/Line Collection DB).
    /// </summary>
    private static bool IsReportQueueLab(LabCsvConfig cfg) =>
        !string.IsNullOrWhiteSpace(cfg.DbConnectionString)
        && (cfg.DBEnabled || cfg.LineClaimEnable);

    /// <summary>Connection string for a lab, or null when the lab isn't DB-enabled.</summary>
    public string? ResolveConnectionString(string labName)
    {
        if (_labSettings.Labs.TryGetValue(labName, out var cfg) && IsReportQueueLab(cfg))
            return cfg.DbConnectionString;
        // The shared cross-lab queue is deliberately absent from LabSettings.Labs.
        return SharedReportLab is not null
               && labName.Equals(SharedReportLab, StringComparison.OrdinalIgnoreCase)
            ? _sharedConnectionString
            : null;
    }

    public async Task<long> QueueAsync(
        string labName, string reportType, string userName, int? userId,
        string? filterJson, CancellationToken ct)
    {
        var connStr = ResolveConnectionString(labName)
            ?? throw new InvalidOperationException($"Lab '{labName}' is not database-enabled.");

        userName = (userName ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(userName))
            throw new InvalidOperationException("Cannot queue a report: signed-in user name is empty.");

        return await _repo.QueueAsync(connStr, new NewReportRequest(
            ReportType: reportType,
            LabName: labName,
            RequestedBy: userName,
            RequestedByUserId: userId,
            FilterDetailsJson: filterJson), ct);
    }

    /// <summary>
    /// Recent requests for one user across every report-queue lab.
    /// <paramref name="newestFirst"/> = true sorts purely by request time (navbar panel).
    /// Default keeps active (Queued/Processing) rows first for badge completeness.
    /// </summary>
    public async Task<List<UserReportRow>> GetMyReportsAsync(
        string userName, CancellationToken ct, int perLabTop = 20, int totalTake = 30,
        bool newestFirst = false)
    {
        userName = (userName ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(userName))
            return [];

        // Includes the shared cross-lab queue, otherwise a queued CPT/Panel Lookup export would
        // never appear in the user's Reports badge or panel.
        var labs = QueueLabs().ToList();

        // Fail fast on labs missing UserReqReports so the panel isn't blocked by long timeouts.
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(8));
        var queryCt = timeoutCts.Token;

        var tasks = labs.Select(async kv =>
        {
            try
            {
                return await _repo.GetUserReportsAsync(kv.Value, userName, perLabTop, queryCt);
            }
            catch (Exception ex) when (ex is not OperationCanceledException || ct.IsCancellationRequested)
            {
                if (ct.IsCancellationRequested) throw;
                _logger.LogWarning(ex,
                    "Reports summary: lab {Lab} unreachable or UserReqReports query failed — skipped. {Message}",
                    kv.Key, ex.Message);
                return new List<UserReportRow>();
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                _logger.LogWarning("Reports summary: lab {Lab} timed out — skipped.", kv.Key);
                return new List<UserReportRow>();
            }
        });

        var perLab = await Task.WhenAll(tasks);
        var merged = perLab.SelectMany(x => x);
        var ordered = newestFirst
            ? merged.OrderByDescending(r => r.RequestedDate).ThenByDescending(r => r.ReportId)
            : merged.OrderBy(r => r.Status.IsActive() ? 0 : 1)
                    .ThenByDescending(r => r.RequestedDate)
                    .ThenByDescending(r => r.ReportId);

        return ordered.Take(totalTake).ToList();
    }

    public Task<UserReportRow?> GetForDownloadAsync(string labName, long reportId, string userName, Guid token, CancellationToken ct)
    {
        var connStr = ResolveConnectionString(labName);
        return connStr is null
            ? Task.FromResult<UserReportRow?>(null)
            : _repo.GetForDownloadAsync(connStr, reportId, userName, token, ct);
    }

    public Task<string?> GetFilePathAsync(string labName, long reportId, string userName, Guid token, CancellationToken ct)
    {
        var connStr = ResolveConnectionString(labName);
        return connStr is null
            ? Task.FromResult<string?>(null)
            : _repo.GetFilePathAsync(connStr, reportId, userName, token, ct);
    }

    public Task MarkDownloadedAsync(string labName, long reportId, CancellationToken ct)
    {
        var connStr = ResolveConnectionString(labName);
        return connStr is null ? Task.CompletedTask : _repo.MarkDownloadedAsync(connStr, reportId, ct);
    }

    /// <summary>Marks Deleted and removes the physical file immediately (best effort).</summary>
    public async Task<bool> DeleteAsync(string labName, long reportId, string userName, CancellationToken ct)
    {
        var connStr = ResolveConnectionString(labName);
        if (connStr is null) return false;

        var deleted = await _repo.MarkDeletedAsync(connStr, reportId, userName, ct);
        if (deleted is null) return false; // not found / not owned

        if (!string.IsNullOrWhiteSpace(deleted.FilePath))
        {
            try
            {
                if (File.Exists(deleted.FilePath)) File.Delete(deleted.FilePath);
            }
            catch (Exception ex)
            {
                // Row already marked Deleted; nightly cleanup handles the orphan.
                _logger.LogWarning(ex, "Could not delete file for report {ReportId}: {Path}", reportId, deleted.FilePath);
            }
        }
        return true;
    }

    public async Task<bool> RetryAsync(string labName, long reportId, string userName, CancellationToken ct)
    {
        var connStr = ResolveConnectionString(labName);
        return connStr is not null && await _repo.RetryAsync(connStr, reportId, userName, ct);
    }

    /// <summary>Cancels a Queued or Processing report owned by the user.</summary>
    public async Task<bool> CancelAsync(string labName, long reportId, string userName, CancellationToken ct)
    {
        var connStr = ResolveConnectionString(labName);
        return connStr is not null && await _repo.CancelAsync(connStr, reportId, userName, ct);
    }
}
