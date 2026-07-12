using LRN.PayerPolicyMapper.Core;
using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Extensions.Options;

namespace LRN.PayerPolicyMapper;

/// <summary>
/// Background re-evaluation of unmapped LabInsuranceMaster rows through the shared
/// LRN.PayerPolicyMapper.Core pipeline:
///  - poll loop: claims up to BatchSize rows (GlobalPayerID IS NULL AND LastEvaluatedOn IS NULL)
///    with UPDATE TOP ... OUTPUT + READPAST, so multiple instances never double-process;
///  - rules-change detection: each cycle the reference-data version (MAX CreatedOn/ModifiedOn +
///    row counts across the policy master, the rules tables and PayerAlias) is compared to the
///    last snapshot - on change the Step 0 index is rebuilt atomically and LastEvaluatedOn is
///    cleared for every unmapped row, so a new StateBrandMapping row or Payer Policy record can
///    rescue previous NoMatch rows within one poll cycle;
///  - nightly safety net: at NightlyHourUtc ALL unmapped rows are re-evaluated regardless of
///    watermark (ActionType = 'NightlyRescan' in the audit).
/// A PeriodicTimer drives everything - the solution uses no scheduling framework and one nightly
/// job does not justify adding one.
/// </summary>
public sealed class Worker : BackgroundService
{
    private readonly IPayerPolicyIndexProvider _indexProvider;
    private readonly ILabInsuranceRepository _labRepository;
    private readonly MatchingPipeline _pipeline;
    private readonly PayerMapperOptions _options;
    private readonly ILogger<Worker> _logger;

    private DateOnly _lastNightlyRunDateUtc = DateOnly.MinValue;
    // True from the nightly reset until a cycle claims nothing - the rescan backlog usually spans
    // several batches and every one of them must carry ActionType 'NightlyRescan' in the audit.
    private bool _nightlyInProgress;

    public Worker(IPayerPolicyIndexProvider indexProvider, ILabInsuranceRepository labRepository,
        MatchingPipeline pipeline, IOptions<PayerMapperOptions> options, ILogger<Worker> logger)
    {
        _indexProvider = indexProvider;
        _labRepository = labRepository;
        _pipeline = pipeline;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("LRN Payer Policy Mapper starting: poll {Poll}s, batch {Batch}, nightly rescan {Hour:00}:00 UTC",
            _options.PollIntervalSeconds, _options.BatchSize, _options.NightlyHourUtc);

        // A restart is not a nightly boundary: starting after the configured hour must NOT trigger
        // a full rescan, or every restart resets LastEvaluatedOn for all unmapped rows and the
        // worker keeps re-processing the head of the queue instead of advancing through it.
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
        // 1. Rules-change detection + atomic index rebuild.
        var (_, rebuilt) = await _indexProvider.RefreshIfChangedAsync(ct);
        if (rebuilt)
        {
            var reset = await _labRepository.ResetUnmappedEvaluationsAsync(ct);
            _logger.LogInformation("Reference data changed - index rebuilt, {Count} unmapped row(s) queued for re-evaluation", reset);
        }

        // 2. Nightly safety net: once per UTC day at (or after) the configured hour.
        var nowUtc = DateTime.UtcNow;
        if (nowUtc.Hour >= _options.NightlyHourUtc && DateOnly.FromDateTime(nowUtc) > _lastNightlyRunDateUtc)
        {
            _lastNightlyRunDateUtc = DateOnly.FromDateTime(nowUtc);
            var reset = await _labRepository.ResetUnmappedEvaluationsAsync(ct);
            _nightlyInProgress = true;
            _logger.LogInformation("Nightly rescan: {Count} unmapped row(s) queued for full re-evaluation", reset);
        }
        var actionType = _nightlyInProgress ? "NightlyRescan" : "Evaluate";

        // 3. Claim and process one batch (the claim itself stamps LastEvaluatedOn - see the repository).
        var batch = await _labRepository.ClaimUnmappedBatchAsync(_options.BatchSize, ct);
        if (batch.Count == 0)
        {
            _nightlyInProgress = false; // rescan backlog drained
            return;
        }

        int autoMapped = 0, review = 0, noMatch = 0, failed = 0;
        foreach (var row in batch)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var result = await _pipeline.EvaluateAndPersistAsync(row, actionType, ct);
                switch (result.Decision)
                {
                    case MatchDecision.AutoMap: autoMapped++; break;
                    case MatchDecision.ManualReview: review++; break;
                    case MatchDecision.NoMatch: noMatch++; break;
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // The row stays claimed (LastEvaluatedOn set) so a poison row cannot wedge the loop;
                // the next rules change or nightly rescan retries it.
                failed++;
                _logger.LogError(ex, "Evaluation failed for LabInsuranceMasterId {Id} ('{Payer}')", row.LabInsuranceMasterId, row.PayerNameRaw);
            }
        }
        _logger.LogInformation("Processed {Count} row(s): {Auto} auto-mapped, {Review} pending review, {NoMatch} no match{Failed}",
            batch.Count, autoMapped, review, noMatch, failed > 0 ? $", {failed} failed" : string.Empty);
    }
}
