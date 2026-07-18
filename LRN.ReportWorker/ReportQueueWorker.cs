using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.ReportWorker;

/// <summary>
/// Main polling loop.
///
///   every PollIntervalSeconds:
///     for each configured lab DB (round-robin):
///       usp_ClaimNextUserReqReport  (UPDLOCK/READPAST — multi-instance safe)
///       → dispatch to ReportJobProcessor on the shared semaphore
///          (MaxConcurrentReports across ALL labs)
///
/// Startup: usp_ResetStuckUserReqReports re-queues rows orphaned in Processing
/// by a crash or service restart.
/// </summary>
public sealed class ReportQueueWorker : BackgroundService
{
    private readonly ReportJobProcessor _processor;
    private readonly IReportRequestRepository _repo;
    private readonly ReportWorkerOptions _options;
    private readonly ILogger<ReportQueueWorker> _logger;
    private readonly SemaphoreSlim _concurrency;

    public ReportQueueWorker(
        ReportJobProcessor processor,
        IReportRequestRepository repo,
        IOptions<ReportWorkerOptions> options,
        ILogger<ReportQueueWorker> logger)
    {
        _processor   = processor;
        _repo        = repo;
        _options     = options.Value;
        _logger      = logger;
        _concurrency = new SemaphoreSlim(Math.Max(1, _options.MaxConcurrentReports));
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var labs = LabDbConfigLoader.LoadAll(_options.LabConfigFolder, _options.Labs);
        if (labs.Count == 0)
        {
            _logger.LogError(
                "No DB-enabled labs resolved from {Folder} — worker is idle. Check ReportWorker:Labs / LabConfigFolder.",
                _options.LabConfigFolder);
            return;
        }

        _logger.LogInformation(
            "ReportQueueWorker started as {Worker}: {LabCount} labs, poll {Poll}s, max {Max} concurrent.",
            ReportJobProcessor.WorkerName, labs.Count, _options.PollIntervalSeconds, _options.MaxConcurrentReports);

        await RecoverStuckAsync(labs, stoppingToken);

        var inFlight = new List<Task>();
        var poll = TimeSpan.FromSeconds(Math.Max(1, _options.PollIntervalSeconds));

        while (!stoppingToken.IsCancellationRequested)
        {
            var claimedAny = false;

            foreach (var lab in labs)
            {
                if (stoppingToken.IsCancellationRequested) break;

                // Don't claim work we can't start — the row would sit in Processing.
                if (_concurrency.CurrentCount == 0) break;

                ClaimedReport? job = null;
                try
                {
                    job = await _repo.ClaimNextAsync(lab.DbConnectionString!, ReportJobProcessor.WorkerName, stoppingToken);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // One lab DB down must not stop the others.
                    _logger.LogWarning(ex, "Queue poll failed for lab {Lab}; skipping this cycle.", lab.LabName);
                }

                if (job is null) continue;

                claimedAny = true;
                await _concurrency.WaitAsync(stoppingToken);
                inFlight.Add(RunJobAsync(lab, job, stoppingToken));
            }

            inFlight.RemoveAll(t => t.IsCompleted);

            if (!claimedAny)
            {
                try { await Task.Delay(poll, stoppingToken); }
                catch (OperationCanceledException) { break; }
            }
        }

        _logger.LogInformation("Shutdown requested — waiting for {Count} in-flight report(s)…", inFlight.Count);
        try { await Task.WhenAll(inFlight); } catch { /* individual jobs already logged */ }
        _logger.LogInformation("ReportQueueWorker stopped.");
    }

    private async Task RunJobAsync(LabDbConfig lab, ClaimedReport job, CancellationToken ct)
    {
        try
        {
            await _processor.ProcessAsync(lab, job, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Unhandled error running report {ReportId}.", job.ReportId);
        }
        finally
        {
            _concurrency.Release();
        }
    }

    private async Task RecoverStuckAsync(IEnumerable<LabDbConfig> labs, CancellationToken ct)
    {
        foreach (var lab in labs)
        {
            try
            {
                var recovered = await _repo.ResetStuckAsync(
                    lab.DbConnectionString!, _options.StuckAfterMinutes, _options.MaxRetries,
                    ReportJobProcessor.WorkerName, ct);
                if (recovered > 0)
                    _logger.LogWarning("Recovered {Count} stuck report(s) on {Lab}.", recovered, lab.LabName);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogWarning(ex, "Stuck-report recovery failed for lab {Lab}.", lab.LabName);
            }
        }
    }
}
