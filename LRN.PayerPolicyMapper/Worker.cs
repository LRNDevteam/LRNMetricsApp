using LRN.PayerPolicyMapper.Core;
using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Extensions.Options;

namespace LRN.PayerPolicyMapper;

/// <summary>
/// Background re-evaluation of unmapped LabInsuranceMaster rows through the shared
/// LRN.PayerPolicyMapper.Core pipeline. Work happens in discrete, audited RUNS
/// (dbo.PayerMapperRun - surfaced on the dashboard's Payer Service Audit page):
///  - Scheduled: every ScheduledRunIntervalMinutes (default 60) all claimable rows
///    (LastEvaluatedOn IS NULL) are processed to completion in one run;
///  - Manual: the Payer Service Audit page queues a Status='Requested' run; the poll loop
///    (PollIntervalSeconds, default 30) claims it, resets LastEvaluatedOn for all unmapped
///    rows and re-evaluates everything - so a manual trigger is always a full pass;
///  - RulesChange: when the reference-data watermark moves, the Step 0 index is rebuilt
///    atomically and unmapped rows are re-evaluated in a dedicated run;
///  - NightlyRescan: at NightlyHourUtc, a full safety-net pass over all unmapped rows.
/// Every evaluation carries the RunId into dbo.PayerMatchAudit, so a run's detail view is
/// exactly the audit rows written under it. Claims use UPDATE TOP ... OUTPUT + READPAST,
/// so multiple instances never double-process a row or a requested run.
/// </summary>
public sealed class Worker : BackgroundService
{
    private readonly IPayerPolicyIndexProvider _indexProvider;
    private readonly ILabInsuranceRepository _labRepository;
    private readonly IAuditRepository _auditRepository;
    private readonly IPayerMapperRunRepository _runs;
    private readonly MatchingPipeline _pipeline;
    private readonly PayerMapperOptions _options;
    private readonly ILogger<Worker> _logger;

    private DateOnly _lastNightlyRunDateUtc = DateOnly.MinValue;
    private DateTime _lastScheduledRunUtc = DateTime.MinValue;

    public Worker(IPayerPolicyIndexProvider indexProvider, ILabInsuranceRepository labRepository,
        IAuditRepository auditRepository, IPayerMapperRunRepository runs, MatchingPipeline pipeline,
        IOptions<PayerMapperOptions> options, ILogger<Worker> logger)
    {
        _indexProvider = indexProvider;
        _labRepository = labRepository;
        _auditRepository = auditRepository;
        _runs = runs;
        _pipeline = pipeline;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation(
            "LRN Payer Policy Mapper starting: scheduled run every {Interval} min, trigger poll {Poll}s, batch {Batch}, nightly rescan {Hour:00}:00 UTC",
            _options.ScheduledRunIntervalMinutes, _options.PollIntervalSeconds, _options.BatchSize, _options.NightlyHourUtc);

        // A restart is not a nightly boundary: starting after the configured hour must NOT trigger
        // a full rescan, or every restart resets LastEvaluatedOn for all unmapped rows.
        if (DateTime.UtcNow.Hour >= _options.NightlyHourUtc)
            _lastNightlyRunDateUtc = DateOnly.FromDateTime(DateTime.UtcNow);

        // Baseline index build (its first-build result is not treated as a rules change).
        try { await _indexProvider.RefreshIfChangedAsync(stoppingToken); }
        catch (Exception ex) when (ex is not OperationCanceledException)
        { _logger.LogError(ex, "Initial reference index build failed; will retry on the next poll cycle"); }

        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(Math.Max(5, _options.PollIntervalSeconds)));
        do
        {
            try
            {
                await RunCycleAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Poll cycle failed; retrying on the next interval");
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private async Task RunCycleAsync(CancellationToken ct)
    {
        // 1. Rules-change detection + atomic index rebuild -> re-evaluate every unmapped row
        //    (includes No Match Found - a new policy/rule row can rescue them).
        var (_, rebuilt) = await _indexProvider.RefreshIfChangedAsync(ct);
        if (rebuilt)
        {
            var reset = await _labRepository.ResetEvaluationsAsync(RunScope.AllUnmapped, ct);
            _logger.LogInformation("Reference data changed - index rebuilt, {Count} unmapped row(s) queued", reset);
            await ExecuteRunAsync(null, "RulesChange", "Evaluate", RunScope.AllUnmapped, ct);
            return;
        }

        // 2. Manual trigger from the Payer Service Audit page (claimed atomically); its scope was
        //    chosen by the user - Entire data (All) or only Unmapped & Pending Review.
        var requested = await _runs.ClaimRequestedRunAsync(ct);
        if (requested is not null)
        {
            var reset = await _labRepository.ResetEvaluationsAsync(requested.Scope, ct);
            _logger.LogInformation("Manual run {RunId} claimed (scope {Scope}) - {Count} row(s) queued",
                requested.RunId, requested.Scope, reset);
            await ExecuteRunAsync(requested.RunId, "Manual", "Evaluate", requested.Scope, ct);
            return;
        }

        // 3. Nightly safety net: once per UTC day at (or after) the configured hour - all unmapped rows.
        var nowUtc = DateTime.UtcNow;
        if (nowUtc.Hour >= _options.NightlyHourUtc && DateOnly.FromDateTime(nowUtc) > _lastNightlyRunDateUtc)
        {
            _lastNightlyRunDateUtc = DateOnly.FromDateTime(nowUtc);
            var reset = await _labRepository.ResetEvaluationsAsync(RunScope.AllUnmapped, ct);
            _logger.LogInformation("Nightly rescan - {Count} unmapped row(s) queued", reset);
            await ExecuteRunAsync(null, "NightlyRescan", "NightlyRescan", RunScope.AllUnmapped, ct);
            return;
        }

        // 4. Scheduled run: every ScheduledRunIntervalMinutes, process only Unmapped /
        //    Unmapped - Pending Review rows not yet evaluated (never touches Mapped rows and
        //    never re-grinds No Match Found every hour). Logged even when there is nothing to
        //    do, so the audit page shows the hourly heartbeat.
        if (nowUtc - _lastScheduledRunUtc >= TimeSpan.FromMinutes(Math.Max(1, _options.ScheduledRunIntervalMinutes)))
        {
            _lastScheduledRunUtc = nowUtc;
            await ExecuteRunAsync(null, "Scheduled", "Evaluate", RunScope.UnmappedPending, ct);
        }
    }

    /// <summary>Processes every claimable row in the scope to completion under one audited run.</summary>
    private async Task ExecuteRunAsync(Guid? existingRunId, string triggerType, string actionType, RunScope scope, CancellationToken ct)
    {
        var runId = existingRunId ?? await _runs.CreateRunAsync(triggerType, scope, ct);
        int total = 0, autoMapped = 0, review = 0, noMatch = 0, failed = 0;
        try
        {
            var index = await _indexProvider.GetAsync(ct);
            while (!ct.IsCancellationRequested)
            {
                var batch = await _labRepository.ClaimUnmappedBatchAsync(_options.BatchSize, scope, ct);
                if (batch.Count == 0) break;

                foreach (var row in batch)
                {
                    ct.ThrowIfCancellationRequested();
                    total++;
                    try
                    {
                        MatchDecision decision;
                        if (row.GlobalPayerId is not null)
                        {
                            // Already mapped (full-scan scope only): REVALIDATE - re-score and audit
                            // what the engine would decide, but never overwrite or unmap a confirmed
                            // mapping automatically. Mismatches are visible in the run details.
                            var result = _pipeline.Evaluate(row, index);
                            await _auditRepository.WriteAsync(
                                MatchingPipeline.BuildAuditEntry(row, result, "Revalidate", MatchingPipeline.SystemAutoMatch, runId), ct);
                            await _labRepository.StampEvaluatedAsync(row.LabInsuranceMasterId, ct);
                            decision = result.Decision;
                        }
                        else
                        {
                            var result = await _pipeline.EvaluateAndPersistAsync(row, actionType, ct, runId);
                            decision = result.Decision;
                        }
                        switch (decision)
                        {
                            case MatchDecision.AutoMap: autoMapped++; break;
                            case MatchDecision.ManualReview: review++; break;
                            case MatchDecision.NoMatch: noMatch++; break;
                        }
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        // The row stays claimed (LastEvaluatedOn set) so a poison row cannot wedge
                        // the run; the next rules change / manual trigger / nightly rescan retries it.
                        failed++;
                        _logger.LogError(ex, "Run {RunId}: evaluation failed for LabInsuranceMasterId {Id} ('{Payer}')",
                            runId, row.LabInsuranceMasterId, row.PayerNameRaw);
                    }
                }
            }

            // A scheduled / nightly / rules-change heartbeat that found no work leaves no trace:
            // drop its run header so the Payer Service Audit page only lists runs that did something.
            // User-initiated (Manual) runs are always kept, even when they process nothing.
            if (existingRunId is null && triggerType != "Manual" && total == 0 && failed == 0)
            {
                await _runs.DeleteRunAsync(runId, ct);
                _logger.LogDebug("Run {RunId} ({Trigger}) had no work - run header discarded", runId, triggerType);
                return;
            }

            var status = total > 0 && failed == total ? "Fail" : "Success";
            await _runs.CompleteRunAsync(runId, status, total, autoMapped, review, noMatch, failed, null, ct);
            _logger.LogInformation("Run {RunId} ({Trigger}) {Status}: {Total} processed - {Auto} auto-mapped, {Review} pending review, {NoMatch} no match{Failed}",
                runId, triggerType, status, total, autoMapped, review, noMatch, failed > 0 ? $", {failed} failed" : string.Empty);
        }
        catch (OperationCanceledException)
        {
            // Service stopping mid-run: record what was done; the rows stay claimed and the next
            // scheduled run continues from where this one stopped.
            await CompleteBestEffortAsync(runId, "Fail", total, autoMapped, review, noMatch, failed, "Service stopped while the run was in progress.");
            throw;
        }
        catch (Exception ex)
        {
            await CompleteBestEffortAsync(runId, "Fail", total, autoMapped, review, noMatch, failed, ex.Message);
            _logger.LogError(ex, "Run {RunId} ({Trigger}) failed after {Total} row(s)", runId, triggerType, total);
        }
    }

    private async Task CompleteBestEffortAsync(Guid runId, string status, int total, int auto, int review, int noMatch, int failed, string error)
    {
        try { await _runs.CompleteRunAsync(runId, status, total, auto, review, noMatch, failed, error, CancellationToken.None); }
        catch (Exception ex) { _logger.LogError(ex, "Could not finalize run {RunId}", runId); }
    }
}
