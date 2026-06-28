using System.Collections.Concurrent;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

public interface IDenialWorkflowExportJobService
{
    ClaimExportStartResponse StartClaimsExport(DenialWorkflowFilter filter, string requestedBy);
    ClaimExportStatusResponse? GetStatus(string jobId, string requestedBy);
    ClaimExportFile? GetCompletedFile(string jobId, string requestedBy);
    ClaimExportStatusResponse? Cancel(string jobId, string requestedBy);
}

public sealed record ClaimExportFile(string FilePath, string FileName, string ContentType);

public sealed class DenialWorkflowExportJobService : IDenialWorkflowExportJobService
{
    private static readonly ConcurrentDictionary<string, ExportJobState> Jobs = new(StringComparer.OrdinalIgnoreCase);
    private static readonly TimeSpan MaxExportDuration = TimeSpan.FromMinutes(30);
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<DenialWorkflowExportJobService> _logger;
    private readonly string _exportRoot;

    public DenialWorkflowExportJobService(
        IServiceScopeFactory scopeFactory,
        IConfiguration configuration,
        ILogger<DenialWorkflowExportJobService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
        _exportRoot = configuration["DenialWorkflowFileStorage:DownloadRootPath"]
            ?? configuration["DenialWorkflowExports:RootPath"]
            ?? Path.Combine(AppContext.BaseDirectory, "ClaimExports");
        Directory.CreateDirectory(_exportRoot);
    }

    public ClaimExportStartResponse StartClaimsExport(DenialWorkflowFilter filter, string requestedBy)
    {
        var jobId = Guid.NewGuid().ToString("N");
        var safeUser = SafeFilePart(requestedBy);
        var fileName = filter.UploadTemplate
            ? $"Claim_Upload_Template_{filter.LabId}_{DateTime.UtcNow:yyyyMMdd_HHmmss}_{safeUser}.xlsx"
            : $"Claim_Detail_Export_{filter.LabId}_{DateTime.UtcNow:yyyyMMdd_HHmmss}_{safeUser}.csv";
        var filePath = Path.Combine(_exportRoot, $"{jobId}_{fileName}");
        var state = new ExportJobState
        {
            JobId = jobId,
            RequestedBy = requestedBy,
            FileName = fileName,
            FilePath = filePath,
            LabId = filter.LabId,
            ContentType = filter.UploadTemplate ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "text/csv",
            Status = "Queued",
            Message = "Export request received. File creation is running in the background.",
            CreatedOnUtc = DateTime.UtcNow,
            Cancellation = new CancellationTokenSource()
        };

        ExpireStaleJobs();

        var active = Jobs.Values
            .Where(x => string.Equals(x.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase)
                        && x.LabId == filter.LabId
                        && (string.Equals(x.Status, "Queued", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(x.Status, "Running", StringComparison.OrdinalIgnoreCase)))
            .OrderByDescending(x => x.CreatedOnUtc)
            .FirstOrDefault();
        if (active is not null)
        {
            return new ClaimExportStartResponse
            {
                JobId = active.JobId,
                Status = active.Status,
                Message = "A claim detail export is already in progress. Please wait until it completes before starting another one.",
                CreatedOnUtc = active.CreatedOnUtc
            };
        }

        Jobs[jobId] = state;
        _ = Task.Run(() => RunJobAsync(filter, state));

        return new ClaimExportStartResponse
        {
            JobId = jobId,
            Status = state.Status,
            Message = state.Message,
            CreatedOnUtc = state.CreatedOnUtc
        };
    }

    public ClaimExportStatusResponse? GetStatus(string jobId, string requestedBy)
    {
        ExpireStaleJobs();
        if (!Jobs.TryGetValue(jobId, out var state) || !CanAccess(state, requestedBy)) return null;
        return new ClaimExportStatusResponse
        {
            JobId = state.JobId,
            Status = state.Status,
            Message = state.Message,
            RowCount = state.RowCount,
            CreatedOnUtc = state.CreatedOnUtc,
            CompletedOnUtc = state.CompletedOnUtc,
            DownloadUrl = string.Equals(state.Status, "Completed", StringComparison.OrdinalIgnoreCase)
                ? $"/api/denialworkflow/claims/export/{state.JobId}/download"
                : null
        };
    }

    public ClaimExportFile? GetCompletedFile(string jobId, string requestedBy)
    {
        if (!Jobs.TryGetValue(jobId, out var state) || !CanAccess(state, requestedBy)) return null;
        if (!string.Equals(state.Status, "Completed", StringComparison.OrdinalIgnoreCase)) return null;
        if (!File.Exists(state.FilePath)) return null;
        return new ClaimExportFile(state.FilePath, state.FileName, state.ContentType);
    }

    public ClaimExportStatusResponse? Cancel(string jobId, string requestedBy)
    {
        if (!Jobs.TryGetValue(jobId, out var state) || !CanAccess(state, requestedBy)) return null;
        if (string.Equals(state.Status, "Queued", StringComparison.OrdinalIgnoreCase)
            || string.Equals(state.Status, "Running", StringComparison.OrdinalIgnoreCase))
        {
            state.Cancellation?.Cancel();
            state.Status = "Failed";
            state.Message = "Export was cancelled by the user.";
            state.CompletedOnUtc = DateTime.UtcNow;
            TryDelete(state.FilePath);
        }

        return GetStatus(jobId, requestedBy);
    }

    private async Task RunJobAsync(DenialWorkflowFilter filter, ExportJobState state)
    {
        try
        {
            state.Status = "Running";
            state.Message = filter.UploadTemplate
                ? "Building claim upload template. You can continue using the system."
                : "Building claim detail export. You can continue using the system.";

            await using var stream = File.Create(state.FilePath);
            using var scope = _scopeFactory.CreateScope();
            var service = scope.ServiceProvider.GetRequiredService<IDenialWorkflowService>();
            using var timeoutCts = new CancellationTokenSource(MaxExportDuration);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(timeoutCts.Token, state.Cancellation?.Token ?? CancellationToken.None);
            state.RowCount = await service.WriteClaimsExportAsync(filter, stream, linkedCts.Token);
            if (state.RowCount <= 0)
            {
                state.Status = "Failed";
                state.Message = "No claim rows were found for this export. Please check the selected lab and filters.";
                state.CompletedOnUtc = DateTime.UtcNow;
                TryDelete(state.FilePath);
                return;
            }

            state.Status = "Completed";
            state.Message = $"Export completed with {state.RowCount:N0} row(s).";
            state.CompletedOnUtc = DateTime.UtcNow;
        }
        catch (OperationCanceledException ex)
        {
            state.Status = "Failed";
            state.Message = state.Cancellation?.IsCancellationRequested == true
                ? "Export was cancelled by the user."
                : "Export timed out after 30 minutes. Please narrow the filters or try a tab download.";
            state.CompletedOnUtc = DateTime.UtcNow;
            _logger.LogWarning(ex, "Claim export job {JobId} stopped before completion.", state.JobId);
            TryDelete(state.FilePath);
        }
        catch (Exception ex)
        {
            state.Status = "Failed";
            state.Message = $"Export failed: {ShortError(ex)}";
            state.CompletedOnUtc = DateTime.UtcNow;
            _logger.LogError(ex, "Claim export job {JobId} failed.", state.JobId);
            TryDelete(state.FilePath);
        }
    }

    private static bool CanAccess(ExportJobState state, string requestedBy)
    {
        if (string.IsNullOrWhiteSpace(state.RequestedBy) || string.IsNullOrWhiteSpace(requestedBy)) return true;
        return string.Equals(state.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase)
            || string.Equals(SafeFilePart(state.RequestedBy), SafeFilePart(requestedBy), StringComparison.OrdinalIgnoreCase);
    }

    private static void ExpireStaleJobs()
    {
        var cutoff = DateTime.UtcNow - MaxExportDuration;
        foreach (var state in Jobs.Values)
        {
            if (state.CreatedOnUtc >= cutoff) continue;
            if (!string.Equals(state.Status, "Queued", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(state.Status, "Running", StringComparison.OrdinalIgnoreCase)) continue;

            state.Status = "Failed";
            state.Message = "Export timed out after 30 minutes. Please start a new export.";
            state.CompletedOnUtc = DateTime.UtcNow;
            state.Cancellation?.Cancel();
            TryDelete(state.FilePath);
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

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private sealed class ExportJobState
    {
        public string JobId { get; init; } = string.Empty;
        public string RequestedBy { get; init; } = string.Empty;
        public string FileName { get; init; } = string.Empty;
        public string FilePath { get; init; } = string.Empty;
        public int LabId { get; init; }
        public string ContentType { get; init; } = "text/csv";
        public string Status { get; set; } = string.Empty;
        public string Message { get; set; } = string.Empty;
        public int RowCount { get; set; }
        public DateTime CreatedOnUtc { get; init; }
        public DateTime? CompletedOnUtc { get; set; }
        public CancellationTokenSource? Cancellation { get; init; }
    }
}
