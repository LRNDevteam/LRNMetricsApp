using System.Collections.Concurrent;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>What a background export produced: the file bytes and the number of data rows in it.</summary>
public sealed record ArWorkbenchExportOutput(byte[] Content, int RowCount);

/// <summary>
/// Builds one export inside its own DI scope (the request that queued it is long gone by then), so
/// it must resolve every service it needs from <paramref name="services"/>.
/// </summary>
public delegate Task<ArWorkbenchExportOutput> ArWorkbenchExportBuilder(IServiceProvider services, CancellationToken ct);

/// <param name="Kind">claims | audit | report - groups the duplicate check.</param>
/// <param name="Scope">What the user asked for, shown in the Downloads list (e.g. "Work Queue - Filtered").</param>
public sealed record ArWorkbenchExportRequest(string Kind, string Scope, int LabId, string RequestedBy, string FileName);

public sealed class ArWorkbenchExportJob
{
    public string JobId { get; set; } = string.Empty;
    public string Kind { get; set; } = string.Empty;
    public string Scope { get; set; } = string.Empty;
    public int LabId { get; set; }
    public string FileName { get; set; } = string.Empty;
    /// <summary>Queued | Running | Completed | Downloaded | Failed | Cancelled | Deleted</summary>
    public string Status { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
    public int RowCount { get; set; }
    public DateTime CreatedOnUtc { get; set; }
    public DateTime? CompletedOnUtc { get; set; }
    public bool CanDownload { get; set; }
    /// <summary>True when Start returned a job that was already running instead of a new one.</summary>
    public bool AlreadyRunning { get; set; }
}

public sealed record ArWorkbenchExportFile(string FilePath, string FileName, string ContentType);

public interface IArWorkbenchExportJobService
{
    ArWorkbenchExportJob Start(ArWorkbenchExportRequest request, ArWorkbenchExportBuilder build);
    ArWorkbenchExportJob? Get(string jobId, string requestedBy);
    IReadOnlyList<ArWorkbenchExportJob> List(string requestedBy);
    ArWorkbenchExportFile? GetFile(string jobId, string requestedBy);
    /// <summary>Cancels a running job, or removes a finished one (and its file) from the list.</summary>
    ArWorkbenchExportJob? CancelOrRemove(string jobId, string requestedBy);
}

/// <summary>
/// AR Workbench "Export" buttons as background jobs - the Denial Workflow's Overall Download pattern
/// (DenialWorkflowExportJobService). Building 100,000 claims plus their assignment / follow-up / QA
/// detail does not fit in one HTTP request: the browser or IIS gave up first and the user saw a
/// timeout. Now the request only queues the job; the file is written to disk in the background, the
/// page polls its status and downloads it when it is ready.
///
/// Live state is in memory; every state change is also written to dbo.DenialWorkflowJobHistory
/// (JobType 'arwb-download') so the Downloads list survives a restart and a finished file can still be
/// downloaded while it is on disk. Files older than <see cref="FileRetention"/> are deleted.
/// </summary>
public sealed class ArWorkbenchExportJobService : IArWorkbenchExportJobService
{
    public const string HistoryJobType = "arwb-download";
    private const string XlsxContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    private const int MaxActivePerUser = 3;
    private static readonly TimeSpan MaxExportDuration = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan FileRetention = TimeSpan.FromDays(7);

    private readonly ConcurrentDictionary<string, JobState> _jobs = new(StringComparer.OrdinalIgnoreCase);
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IDenialWorkflowJobHistoryStore _history;
    private readonly ILogger<ArWorkbenchExportJobService> _logger;
    private readonly string _exportRoot;
    private DateTime _lastPurgeUtc = DateTime.MinValue;

    public ArWorkbenchExportJobService(IServiceScopeFactory scopeFactory, IConfiguration configuration,
        IDenialWorkflowJobHistoryStore history, ILogger<ArWorkbenchExportJobService> logger)
    {
        _scopeFactory = scopeFactory;
        _history = history;
        _logger = logger;
        var configured = configuration["ArWorkbenchExports:RootPath"];
        var denialRoot = configuration["DenialWorkflowFileStorage:DownloadRootPath"];
        _exportRoot = !string.IsNullOrWhiteSpace(configured) ? configured
            : !string.IsNullOrWhiteSpace(denialRoot) ? Path.Combine(denialRoot, "ARWorkbench")
            : Path.Combine(AppContext.BaseDirectory, "ArWorkbenchExports");
        Directory.CreateDirectory(_exportRoot);
    }

    public ArWorkbenchExportJob Start(ArWorkbenchExportRequest request, ArWorkbenchExportBuilder build)
    {
        ExpireStaleJobs();
        PurgeOldFiles();

        var active = _jobs.Values.Where(j => SameUser(j.RequestedBy, request.RequestedBy) && j.IsActive).ToList();
        // The same export already running (same lab, kind and scope): hand that one back, as the
        // Denial Workflow does, rather than building the file twice.
        var same = active.FirstOrDefault(j => j.LabId == request.LabId
            && string.Equals(j.Kind, request.Kind, StringComparison.OrdinalIgnoreCase)
            && string.Equals(j.Scope, request.Scope, StringComparison.OrdinalIgnoreCase));
        if (same is not null)
        {
            var existing = ToDto(same);
            existing.AlreadyRunning = true;
            existing.Message = $"{same.Scope} export is already in progress. It will download when it is ready.";
            return existing;
        }
        if (active.Count >= MaxActivePerUser)
            throw new InvalidOperationException($"You already have {active.Count} exports in progress. Please wait for one to finish before starting another.");

        var jobId = Guid.NewGuid().ToString("N");
        var state = new JobState
        {
            JobId = jobId,
            Kind = request.Kind,
            Scope = request.Scope,
            LabId = request.LabId,
            RequestedBy = request.RequestedBy,
            FileName = request.FileName,
            FilePath = Path.Combine(_exportRoot, $"{jobId}_{request.FileName}"),
            Status = "Queued",
            Message = "Export request received. The file is being created in the background - you can keep working.",
            CreatedOnUtc = DateTime.UtcNow
        };
        _jobs[jobId] = state;
        _history.Save(ToRecord(state));
        _ = Task.Run(() => RunAsync(state, build));
        return ToDto(state);
    }

    public ArWorkbenchExportJob? Get(string jobId, string requestedBy)
    {
        ExpireStaleJobs();
        if (_jobs.TryGetValue(jobId, out var state))
            return SameUser(state.RequestedBy, requestedBy) ? ToDto(state) : null;
        var h = History(jobId, requestedBy);
        return h is null ? null : FromHistory(h);
    }

    public IReadOnlyList<ArWorkbenchExportJob> List(string requestedBy)
    {
        ExpireStaleJobs();
        var live = _jobs.Values.Where(j => SameUser(j.RequestedBy, requestedBy)).Select(ToDto).ToList();
        var liveIds = new HashSet<string>(live.Select(j => j.JobId), StringComparer.OrdinalIgnoreCase);
        // Jobs from before the last restart come from durable history.
        live.AddRange(_history.List(requestedBy, HistoryJobType).Where(h => !liveIds.Contains(h.JobId)).Select(FromHistory));
        return live.OrderByDescending(j => j.CreatedOnUtc).Take(100).ToList();
    }

    public ArWorkbenchExportFile? GetFile(string jobId, string requestedBy)
    {
        if (_jobs.TryGetValue(jobId, out var state))
        {
            if (!SameUser(state.RequestedBy, requestedBy) || state.Status != "Completed" || !File.Exists(state.FilePath)) return null;
            state.DownloadedOnUtc ??= DateTime.UtcNow;
            _history.Save(ToRecord(state));
            return new ArWorkbenchExportFile(state.FilePath, state.FileName, XlsxContentType);
        }

        var h = History(jobId, requestedBy);
        if (h is null || !IsFinishedOk(h.Status) || string.IsNullOrWhiteSpace(h.FilePath) || !File.Exists(h.FilePath)) return null;
        if (h.Status != "Downloaded") _history.Save(h with { Status = "Downloaded" });
        return new ArWorkbenchExportFile(h.FilePath, h.FileName, h.ContentType ?? XlsxContentType);
    }

    public ArWorkbenchExportJob? CancelOrRemove(string jobId, string requestedBy)
    {
        if (_jobs.TryGetValue(jobId, out var state))
        {
            if (!SameUser(state.RequestedBy, requestedBy)) return null;
            if (state.IsActive)
            {
                state.Cancellation.Cancel();
                state.Status = "Cancelled";
                state.Message = "Export was cancelled.";
                state.CompletedOnUtc = DateTime.UtcNow;
                TryDelete(state.FilePath);
                _history.Save(ToRecord(state));
                return ToDto(state);
            }
            _jobs.TryRemove(jobId, out _);
            _history.Delete(jobId);
            TryDelete(state.FilePath);
            var removed = ToDto(state);
            removed.Status = "Deleted";
            removed.CanDownload = false;
            return removed;
        }

        var h = History(jobId, requestedBy);
        if (h is null) return null;
        _history.Delete(jobId);
        TryDelete(h.FilePath);
        var dto = FromHistory(h);
        dto.Status = "Deleted";
        dto.CanDownload = false;
        return dto;
    }

    private async Task RunAsync(JobState state, ArWorkbenchExportBuilder build)
    {
        try
        {
            state.Status = "Running";
            state.Message = $"Building {state.Scope} export. You can continue using the AR Workbench.";
            _history.Save(ToRecord(state));

            using var timeout = new CancellationTokenSource(MaxExportDuration);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token, state.Cancellation.Token);
            using var scope = _scopeFactory.CreateScope();
            var output = await build(scope.ServiceProvider, linked.Token);
            linked.Token.ThrowIfCancellationRequested();

            await File.WriteAllBytesAsync(state.FilePath, output.Content, linked.Token);
            linked.Token.ThrowIfCancellationRequested();   // cancelled while the file was being written
            state.RowCount = output.RowCount;
            state.Status = "Completed";
            state.Message = output.RowCount > 0
                ? $"Export completed with {output.RowCount:N0} row(s)."
                : "Export completed. No rows matched the filters, so the file has headers only.";
            state.CompletedOnUtc = DateTime.UtcNow;
            _logger.LogInformation("AR Workbench export {JobId} ({Scope}) for lab {LabId} by {User}: {Rows} rows in {Seconds:N0}s",
                state.JobId, state.Scope, state.LabId, state.RequestedBy, output.RowCount, (state.CompletedOnUtc.Value - state.CreatedOnUtc).TotalSeconds);
        }
        catch (OperationCanceledException ex)
        {
            if (state.Status != "Cancelled")
            {
                state.Status = state.Cancellation.IsCancellationRequested ? "Cancelled" : "Failed";
                state.Message = state.Cancellation.IsCancellationRequested
                    ? "Export was cancelled."
                    : "Export timed out after 30 minutes. Please narrow the filters and try again.";
            }
            state.CompletedOnUtc ??= DateTime.UtcNow;
            _logger.LogWarning(ex, "AR Workbench export {JobId} stopped before completion.", state.JobId);
            TryDelete(state.FilePath);
        }
        catch (Exception ex)
        {
            state.Status = "Failed";
            state.Message = ex is InvalidOperationException ? ex.Message : "Export failed. Please try again or contact admin support.";
            state.CompletedOnUtc = DateTime.UtcNow;
            _logger.LogError(ex, "AR Workbench export {JobId} ({Scope}) failed for lab {LabId}.", state.JobId, state.Scope, state.LabId);
            TryDelete(state.FilePath);
        }
        finally
        {
            _history.Save(ToRecord(state));
        }
    }

    private JobHistoryRecord? History(string jobId, string requestedBy)
    {
        var h = _history.Get(jobId);
        if (h is null || !string.Equals(h.JobType, HistoryJobType, StringComparison.OrdinalIgnoreCase)) return null;
        return SameUser(h.RequestedBy, requestedBy) ? h : null;
    }

    private void ExpireStaleJobs()
    {
        var cutoff = DateTime.UtcNow - MaxExportDuration - TimeSpan.FromMinutes(1);
        foreach (var state in _jobs.Values.Where(j => j.IsActive && j.CreatedOnUtc < cutoff))
        {
            state.Cancellation.Cancel();
            state.Status = "Failed";
            state.Message = "Export timed out after 30 minutes. Please narrow the filters and try again.";
            state.CompletedOnUtc = DateTime.UtcNow;
            TryDelete(state.FilePath);
        }
        // Finished jobs leave memory after a day; history still lists them.
        foreach (var state in _jobs.Values.Where(j => !j.IsActive && j.CreatedOnUtc < DateTime.UtcNow.AddDays(-1)).ToList())
            _jobs.TryRemove(state.JobId, out _);
    }

    private void PurgeOldFiles()
    {
        if (DateTime.UtcNow - _lastPurgeUtc < TimeSpan.FromHours(1)) return;
        _lastPurgeUtc = DateTime.UtcNow;
        try
        {
            var cutoff = DateTime.UtcNow - FileRetention;
            foreach (var file in Directory.EnumerateFiles(_exportRoot, "*.xlsx"))
                if (File.GetLastWriteTimeUtc(file) < cutoff) TryDelete(file);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not purge old AR Workbench export files in {Root}.", _exportRoot);
        }
    }

    private static bool IsFinishedOk(string? status) => status is "Completed" or "Downloaded";

    private static bool SameUser(string? a, string? b) => string.Equals(a?.Trim(), b?.Trim(), StringComparison.OrdinalIgnoreCase);

    private static ArWorkbenchExportJob ToDto(JobState s) => new()
    {
        JobId = s.JobId,
        Kind = s.Kind,
        Scope = s.Scope,
        LabId = s.LabId,
        FileName = s.FileName,
        Status = s.Status == "Completed" && s.DownloadedOnUtc is not null ? "Downloaded" : s.Status,
        Message = s.Message,
        RowCount = s.RowCount,
        CreatedOnUtc = s.CreatedOnUtc,
        CompletedOnUtc = s.CompletedOnUtc,
        CanDownload = s.Status == "Completed" && File.Exists(s.FilePath)
    };

    private static ArWorkbenchExportJob FromHistory(JobHistoryRecord h)
    {
        // A job that was Queued / Running when the API restarted never finished.
        var status = h.Status is "Queued" or "Running" ? "Failed" : h.Status;
        return new ArWorkbenchExportJob
        {
            JobId = h.JobId,
            Kind = "history",
            Scope = h.FileName,
            LabId = h.LabId,
            FileName = h.FileName,
            Status = status,
            Message = status != h.Status ? "Export stopped because the server restarted. Please start it again." : h.Message,
            RowCount = h.RowCount ?? 0,
            CreatedOnUtc = h.CreatedOnUtc,
            CompletedOnUtc = h.CompletedOnUtc,
            CanDownload = IsFinishedOk(h.Status) && !string.IsNullOrWhiteSpace(h.FilePath) && File.Exists(h.FilePath)
        };
    }

    private static JobHistoryRecord ToRecord(JobState s) => new(
        s.JobId, HistoryJobType, s.RequestedBy, s.LabId, s.FileName,
        s.Status == "Completed" && s.DownloadedOnUtc is not null ? "Downloaded" : s.Status,
        s.Message, s.RowCount, null, null, s.FilePath, XlsxContentType, s.CreatedOnUtc, s.CompletedOnUtc);

    private static void TryDelete(string? path)
    {
        try { if (!string.IsNullOrWhiteSpace(path) && File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }

    private sealed class JobState
    {
        public string JobId { get; init; } = string.Empty;
        public string Kind { get; init; } = string.Empty;
        public string Scope { get; init; } = string.Empty;
        public int LabId { get; init; }
        public string RequestedBy { get; init; } = string.Empty;
        public string FileName { get; init; } = string.Empty;
        public string FilePath { get; init; } = string.Empty;
        public string Status { get; set; } = string.Empty;
        public string Message { get; set; } = string.Empty;
        public int RowCount { get; set; }
        public DateTime CreatedOnUtc { get; init; }
        public DateTime? CompletedOnUtc { get; set; }
        public DateTime? DownloadedOnUtc { get; set; }
        public CancellationTokenSource Cancellation { get; } = new();
        public bool IsActive => Status is "Queued" or "Running";
    }
}
