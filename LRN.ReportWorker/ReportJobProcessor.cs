using LRN.ReportQueue.Shared;
using LRN.ReportWorker.Generators;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.ReportWorker;

/// <summary>
/// Runs one claimed report end-to-end:
///   Processing → Generating Excel → Saving File → Updating Database → Completed/Failed.
/// Failure classification decides auto-retry:
///   transient  (SQL timeout/deadlock/connection, IO sharing violation) → re-queued up to MaxRetries;
///   permanent  (bad filters, unknown report type, disk full)           → Failed immediately.
/// User Cancel sets status Cancelled; Complete/Fail only apply while still Processing.
/// </summary>
public sealed class ReportJobProcessor
{
    private readonly IReportRequestRepository _repo;
    private readonly ReportGeneratorFactory _generators;
    private readonly ReportStorageOptions _storage;
    private readonly ReportWorkerOptions _options;
    private readonly ILogger<ReportJobProcessor> _logger;

    public static readonly string WorkerName = $"{Environment.MachineName}\\LRN.ReportWorker";

    public ReportJobProcessor(
        IReportRequestRepository repo,
        ReportGeneratorFactory generators,
        IOptions<ReportStorageOptions> storage,
        IOptions<ReportWorkerOptions> options,
        ILogger<ReportJobProcessor> logger)
    {
        _repo       = repo;
        _generators = generators;
        _storage    = storage.Value;
        _options    = options.Value;
        _logger     = logger;
    }

    public async Task ProcessAsync(LabDbConfig lab, ClaimedReport job, CancellationToken ct)
    {
        _logger.LogInformation(
            "Processing report {ReportId} ({Type}) for {User} on {Lab} (attempt {Attempt}).",
            job.ReportId, job.ReportType, job.RequestedBy, lab.LabName, job.RetryCount + 1);

        string? tempPath = null;
        try
        {
            var generator = _generators.Resolve(job.ReportType)
                ?? throw new NotSupportedException($"No generator registered for report type '{job.ReportType}'.");

            var (fileName, fullPath) = ReportFilePathBuilder.Build(
                _storage.RootPath, job.ReportType, job.LabName, job.RequestedBy, DateTime.Now);
            tempPath = fullPath + ".tmp";

            // Throttled progress writer: at most one UPDATE per 1 s / changed percent.
            var lastPct = -1;
            var lastAt = DateTime.MinValue;
            async Task OnProgress(byte pct)
            {
                if (pct == lastPct || (DateTime.Now - lastAt).TotalSeconds < 1) return;
                lastPct = pct;
                lastAt = DateTime.Now;
                try
                {
                    var stillActive = await _repo.UpdateProgressAsync(
                        lab.DbConnectionString!, job.ReportId, pct, CancellationToken.None);
                    if (!stillActive)
                        throw new ReportCancelledException(job.ReportId);
                }
                catch (ReportCancelledException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    _logger.LogDebug(ex, "Progress update skipped for report {ReportId}.", job.ReportId);
                }
            }

            // Publish an initial value immediately. Long COUNT/setup queries can otherwise
            // leave Processing with a null percentage until the first data batch is written.
            await OnProgress(1);
            var result = await generator.GenerateAsync(lab, job, fileName, fullPath, OnProgress, ct);

            if (!await _repo.IsStillProcessingAsync(lab.DbConnectionString!, job.ReportId, CancellationToken.None))
            {
                TryDelete(result.FilePath);
                TryDelete(tempPath);
                _logger.LogWarning(
                    "Report {ReportId} was cancelled before completion; output discarded.", job.ReportId);
                return;
            }

            await _repo.CompleteAsync(
                lab.DbConnectionString!, job.ReportId, result,
                _storage.RetentionDays, WorkerName, CancellationToken.None);

            _logger.LogInformation("Report {ReportId} completed: {File}", job.ReportId, result.FileName);
        }
        catch (ReportCancelledException)
        {
            TryDelete(tempPath);
            _logger.LogWarning("Report {ReportId} cancelled by user while generating.", job.ReportId);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // A clean service restart should not leave the UI at Processing for the
            // full stuck-job timeout. Return this worker-owned row to Queued now.
            try
            {
                await _repo.RequeueInterruptedAsync(
                    lab.DbConnectionString!, job.ReportId, WorkerName, CancellationToken.None);
                _logger.LogWarning(
                    "Report {ReportId} interrupted by shutdown and immediately requeued.", job.ReportId);
            }
            catch (Exception requeueEx)
            {
                // Abrupt DB failure still falls back to startup/stuck-row recovery.
                _logger.LogError(
                    requeueEx, "Report {ReportId} interrupted; immediate requeue failed.", job.ReportId);
            }
            throw;
        }
        catch (Exception ex)
        {
            var transient = IsTransient(ex);
            _logger.LogError(ex,
                "Report {ReportId} failed ({Kind}).", job.ReportId, transient ? "transient" : "permanent");

            try
            {
                await _repo.FailAsync(
                    lab.DbConnectionString!, job.ReportId, ex.Message,
                    transient, _options.MaxRetries, WorkerName, CancellationToken.None);
            }
            catch (Exception dbEx)
            {
                // DB unreachable while reporting the failure — the row stays in
                // Processing and the stuck-row sweep recovers it later.
                _logger.LogError(dbEx, "Could not record failure for report {ReportId}.", job.ReportId);
            }
        }
    }

    private static void TryDelete(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }

    private static bool IsTransient(Exception ex) => ex switch
    {
        SqlException sql => sql.Number is -2       // timeout
                                       or 1205     // deadlock victim
                                       or 4060     // cannot open database
                                       or 10928 or 10929 or 40197 or 40501 or 40613 // azure transient
                            || sql.InnerException is System.ComponentModel.Win32Exception,
        IOException io   => !IsDiskFull(io),       // sharing violations etc. — retryable
        TimeoutException => true,
        _                => false,
    };

    /// <summary>HR 0x70 = ERROR_DISK_FULL, 0x27 = ERROR_HANDLE_DISK_FULL — never retried.</summary>
    private static bool IsDiskFull(IOException ex) =>
        (ex.HResult & 0xFFFF) is 0x70 or 0x27;
}

/// <summary>Thrown when the user cancels a report mid-generation.</summary>
public sealed class ReportCancelledException : Exception
{
    public ReportCancelledException(long reportId)
        : base($"Report {reportId} was cancelled.")
    {
    }
}
