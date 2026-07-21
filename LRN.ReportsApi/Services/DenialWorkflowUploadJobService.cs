using System.Collections.Concurrent;
using System.Text;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Async bulk-upload job runner. Cloned from <see cref="DenialWorkflowExportJobService"/>:
/// the caller enqueues a parsed upload (returns a jobId immediately), the work runs on a
/// background task with its own DI scope, and the per-row <see cref="ClaimCsvUploadResult"/>
/// is kept in-memory for status polling / the detail popup, plus a CSV log written to disk
/// for download. Jobs are held for a retention window then expired (matches the export UX).
/// </summary>
public interface IDenialWorkflowUploadJobService
{
    ClaimUploadStartResponse StartUpload(
        int labId, string fileName, int totalRows, string requestedBy,
        Func<IServiceProvider, CancellationToken, Task<ClaimCsvUploadResult>> work);

    ClaimUploadStatusResponse? GetStatus(string jobId, string requestedBy);
    IReadOnlyList<ClaimUploadJobSummary> ListJobs(string requestedBy);
    ClaimUploadLogFile? GetLogFile(string jobId, string requestedBy);
    ClaimUploadStatusResponse? Cancel(string jobId, string requestedBy);
}

public sealed record ClaimUploadLogFile(string FilePath, string FileName, string ContentType);

public sealed class DenialWorkflowUploadJobService : IDenialWorkflowUploadJobService
{
    private static readonly ConcurrentDictionary<string, UploadJobState> Jobs = new(StringComparer.OrdinalIgnoreCase);
    private static readonly TimeSpan MaxUploadDuration = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan RetentionWindow = TimeSpan.FromDays(7);
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<DenialWorkflowUploadJobService> _logger;
    private readonly IDenialWorkflowJobHistoryStore _history;
    private readonly string _logRoot;

    public DenialWorkflowUploadJobService(
        IServiceScopeFactory scopeFactory,
        IConfiguration configuration,
        IDenialWorkflowJobHistoryStore history,
        ILogger<DenialWorkflowUploadJobService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
        _history = history;
        _logRoot = configuration["DenialWorkflowFileStorage:UploadLogRootPath"]
            ?? configuration["DenialWorkflowUploads:LogRootPath"]
            ?? Path.Combine(AppContext.BaseDirectory, "ClaimUploadLogs");
        Directory.CreateDirectory(_logRoot);
    }

    public ClaimUploadStartResponse StartUpload(
        int labId, string fileName, int totalRows, string requestedBy,
        Func<IServiceProvider, CancellationToken, Task<ClaimCsvUploadResult>> work)
    {
        ExpireStaleJobs();

        var jobId = Guid.NewGuid().ToString("N");
        var state = new UploadJobState
        {
            JobId = jobId,
            LabId = labId,
            RequestedBy = requestedBy,
            FileName = string.IsNullOrWhiteSpace(fileName) ? "upload" : fileName,
            TotalRows = totalRows,
            Status = "Queued",
            Message = "Upload received. Processing is running in the background — you can keep working.",
            CreatedOnUtc = DateTime.UtcNow,
            Cancellation = new CancellationTokenSource()
        };

        Jobs[jobId] = state;
        _history.Save(ToRecord(state));
        _ = Task.Run(() => RunJobAsync(state, work));

        return new ClaimUploadStartResponse
        {
            JobId = jobId,
            Status = state.Status,
            Message = state.Message,
            TotalRows = totalRows,
            CreatedOnUtc = state.CreatedOnUtc
        };
    }

    public ClaimUploadStatusResponse? GetStatus(string jobId, string requestedBy)
    {
        ExpireStaleJobs();
        if (!Jobs.TryGetValue(jobId, out var state) || !CanAccess(state, requestedBy)) return null;
        return ToStatus(state, includeResult: true);
    }

    public IReadOnlyList<ClaimUploadJobSummary> ListJobs(string requestedBy)
    {
        ExpireStaleJobs();
        var live = Jobs.Values
            .Where(x => CanAccess(x, requestedBy))
            .Select(x => new ClaimUploadJobSummary
            {
                JobId = x.JobId,
                FileName = x.FileName,
                Status = x.Status,
                TotalRows = x.TotalRows,
                SuccessCount = x.Result?.SuccessCount ?? 0,
                FailureCount = x.Result?.FailureCount ?? 0,
                CreatedOnUtc = x.CreatedOnUtc,
                CompletedOnUtc = x.CompletedOnUtc
            })
            .ToList();

        // Merge durable history so uploads from previous sessions still show after a restart.
        var liveIds = new HashSet<string>(live.Select(j => j.JobId), StringComparer.OrdinalIgnoreCase);
        foreach (var h in _history.List(requestedBy, "upload"))
        {
            if (liveIds.Contains(h.JobId)) continue;
            live.Add(new ClaimUploadJobSummary
            {
                JobId = h.JobId,
                FileName = h.FileName,
                Status = h.Status,
                TotalRows = h.RowCount ?? 0,
                SuccessCount = h.SuccessCount ?? 0,
                FailureCount = h.FailureCount ?? 0,
                CreatedOnUtc = h.CreatedOnUtc,
                CompletedOnUtc = h.CompletedOnUtc
            });
        }

        return live.OrderByDescending(x => x.CreatedOnUtc).Take(100).ToList();
    }

    public ClaimUploadLogFile? GetLogFile(string jobId, string requestedBy)
    {
        if (Jobs.TryGetValue(jobId, out var state) && CanAccess(state, requestedBy))
        {
            if (string.IsNullOrWhiteSpace(state.LogFilePath) || !File.Exists(state.LogFilePath)) return null;
            var downloadName = $"UploadLog_{SafeFilePart(Path.GetFileNameWithoutExtension(state.FileName))}_{state.CreatedOnUtc:yyyyMMdd_HHmmss}.csv";
            return new ClaimUploadLogFile(state.LogFilePath, downloadName, "text/csv");
        }

        // Not in memory (e.g. after a restart): serve the log from durable history while it survives.
        var h = _history.Get(jobId);
        if (h is null || !string.Equals(h.JobType, "upload", StringComparison.OrdinalIgnoreCase)) return null;
        if (!string.IsNullOrWhiteSpace(requestedBy) && !string.IsNullOrWhiteSpace(h.RequestedBy)
            && !string.Equals(h.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase)) return null;
        if (string.IsNullOrWhiteSpace(h.FilePath) || !File.Exists(h.FilePath)) return null;
        var name = $"UploadLog_{SafeFilePart(Path.GetFileNameWithoutExtension(h.FileName))}_{h.CreatedOnUtc:yyyyMMdd_HHmmss}.csv";
        return new ClaimUploadLogFile(h.FilePath, name, "text/csv");
    }

    public ClaimUploadStatusResponse? Cancel(string jobId, string requestedBy)
    {
        if (!Jobs.TryGetValue(jobId, out var state) || !CanAccess(state, requestedBy)) return null;
        if (IsActive(state.Status))
        {
            state.Cancellation?.Cancel();
            state.Status = "Failed";
            state.Message = "Upload was cancelled by the user.";
            state.CompletedOnUtc = DateTime.UtcNow;
            return ToStatus(state, includeResult: true);
        }

        // Finished job: DELETE removes it from the list (and deletes its log) — powers the
        // trash action in the Jobs Center.
        Jobs.TryRemove(jobId, out _);
        TryDelete(state.LogFilePath);
        return new ClaimUploadStatusResponse
        {
            JobId = state.JobId,
            FileName = state.FileName,
            Status = "Deleted",
            Message = "Upload record was removed.",
            CreatedOnUtc = state.CreatedOnUtc,
            CompletedOnUtc = state.CompletedOnUtc
        };
    }

    private async Task RunJobAsync(UploadJobState state, Func<IServiceProvider, CancellationToken, Task<ClaimCsvUploadResult>> work)
    {
        try
        {
            state.Status = "Running";
            state.Message = "Processing uploaded claims. You can continue using the system.";

            using var scope = _scopeFactory.CreateScope();
            using var timeoutCts = new CancellationTokenSource(MaxUploadDuration);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(
                timeoutCts.Token, state.Cancellation?.Token ?? CancellationToken.None);

            var result = await work(scope.ServiceProvider, linkedCts.Token);
            state.Result = result;
            state.LogFilePath = WriteLog(state, result);
            state.Status = "Completed";
            state.CompletedOnUtc = DateTime.UtcNow;
            state.Message = result.Message;
        }
        catch (OperationCanceledException ex)
        {
            state.Status = "Failed";
            state.Message = state.Cancellation?.IsCancellationRequested == true
                ? "Upload was cancelled by the user."
                : "Upload timed out after 30 minutes. Please split the file and try again.";
            state.CompletedOnUtc = DateTime.UtcNow;
            _logger.LogWarning(ex, "Claim upload job {JobId} stopped before completion.", state.JobId);
        }
        catch (Exception ex)
        {
            state.Status = "Failed";
            state.Message = $"Upload failed: {ShortError(ex)}";
            state.CompletedOnUtc = DateTime.UtcNow;
            _logger.LogError(ex, "Claim upload job {JobId} failed.", state.JobId);
        }
        finally
        {
            _history.Save(ToRecord(state));
        }
    }

    // Durable history projection of the current upload state (best-effort).
    private JobHistoryRecord ToRecord(UploadJobState s) => new(
        s.JobId, "upload", s.RequestedBy, s.LabId, s.FileName, s.Status, s.Message,
        s.TotalRows, s.Result?.SuccessCount ?? 0, s.Result?.FailureCount ?? 0,
        s.LogFilePath, "text/csv", s.CreatedOnUtc, s.CompletedOnUtc);

    private string? WriteLog(UploadJobState state, ClaimCsvUploadResult result)
    {
        try
        {
            var path = Path.Combine(_logRoot, $"{state.JobId}_uploadlog.csv");
            var sb = new StringBuilder();
            sb.AppendLine("Row,ClaimId,TaskId,Result,Action,OldStatus,NewStatus,Note,FailureReason");
            foreach (var r in result.Results)
                sb.Append(Csv(r.RowNumber.ToString())).Append(',')
                  .Append(Csv(r.ClaimId)).Append(',')
                  .Append(Csv(r.TaskId)).Append(',')
                  .Append(Csv(r.Status)).Append(',')
                  .Append(Csv(r.Action)).Append(',')
                  .Append(Csv(r.OldStatus)).Append(',')
                  .Append(Csv(r.NewStatus)).Append(',')
                  .Append(Csv(r.Note)).Append(',')
                  .Append(Csv(r.FailureReason)).Append('\n');
            File.WriteAllText(path, sb.ToString(), Encoding.UTF8);
            return path;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Claim upload job {JobId}: could not write log file.", state.JobId);
            return null;
        }
    }

    private static string Csv(string? value)
    {
        var v = value ?? string.Empty;
        return v.Contains(',') || v.Contains('"') || v.Contains('\n')
            ? $"\"{v.Replace("\"", "\"\"")}\""
            : v;
    }

    private ClaimUploadStatusResponse ToStatus(UploadJobState state, bool includeResult) => new()
    {
        JobId = state.JobId,
        FileName = state.FileName,
        Status = state.Status,
        Message = state.Message,
        TotalRows = state.TotalRows,
        SuccessCount = state.Result?.SuccessCount ?? 0,
        FailureCount = state.Result?.FailureCount ?? 0,
        CreatedOnUtc = state.CreatedOnUtc,
        CompletedOnUtc = state.CompletedOnUtc,
        DownloadUrl = string.Equals(state.Status, "Completed", StringComparison.OrdinalIgnoreCase) && state.LogFilePath is not null
            ? $"/api/denialworkflow/claims/upload/{state.JobId}/log"
            : null,
        Result = includeResult ? state.Result : null
    };

    private static bool IsActive(string status) =>
        string.Equals(status, "Queued", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(status, "Running", StringComparison.OrdinalIgnoreCase);

    private static bool CanAccess(UploadJobState state, string requestedBy)
    {
        if (string.IsNullOrWhiteSpace(state.RequestedBy) || string.IsNullOrWhiteSpace(requestedBy)) return true;
        return string.Equals(state.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase)
            || string.Equals(SafeFilePart(state.RequestedBy), SafeFilePart(requestedBy), StringComparison.OrdinalIgnoreCase);
    }

    private void ExpireStaleJobs()
    {
        var now = DateTime.UtcNow;
        foreach (var kvp in Jobs)
        {
            var state = kvp.Value;
            // Time out jobs stuck active past the max duration.
            if (IsActive(state.Status) && now - state.CreatedOnUtc > MaxUploadDuration)
            {
                state.Status = "Failed";
                state.Message = "Upload timed out after 30 minutes. Please split the file and try again.";
                state.CompletedOnUtc = now;
                state.Cancellation?.Cancel();
            }
            // Drop finished jobs past the retention window (also removes their log file).
            if (!IsActive(state.Status) && state.CompletedOnUtc is { } done && now - done > RetentionWindow)
            {
                if (Jobs.TryRemove(kvp.Key, out var removed)) TryDelete(removed.LogFilePath);
            }
        }
    }

    private static string SafeFilePart(string value)
    {
        var chars = (value ?? "user").Select(ch => char.IsLetterOrDigit(ch) ? ch : '_').ToArray();
        var safe = new string(chars).Trim('_');
        return string.IsNullOrWhiteSpace(safe) ? "user" : safe[..Math.Min(safe.Length, 48)];
    }

    private static string ShortError(Exception ex)
    {
        var message = string.IsNullOrWhiteSpace(ex.Message) ? ex.GetType().Name : ex.Message.Trim();
        message = message.Replace(Environment.NewLine, " ");
        return message.Length <= 240 ? message : message[..240] + "...";
    }

    private static void TryDelete(string? path)
    {
        try { if (!string.IsNullOrWhiteSpace(path) && File.Exists(path)) File.Delete(path); } catch { }
    }

    private sealed class UploadJobState
    {
        public string JobId { get; init; } = string.Empty;
        public int LabId { get; init; }
        public string RequestedBy { get; init; } = string.Empty;
        public string FileName { get; init; } = string.Empty;
        public int TotalRows { get; init; }
        public string Status { get; set; } = string.Empty;
        public string Message { get; set; } = string.Empty;
        public ClaimCsvUploadResult? Result { get; set; }
        public string? LogFilePath { get; set; }
        public DateTime CreatedOnUtc { get; init; }
        public DateTime? CompletedOnUtc { get; set; }
        public CancellationTokenSource? Cancellation { get; init; }
    }
}
