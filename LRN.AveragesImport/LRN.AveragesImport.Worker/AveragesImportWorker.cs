using System.Diagnostics;
using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Models;
using LRN.AveragesImport.Core.Services;
using LRN.AveragesImport.Core.Services.ReportLogging;
using Microsoft.Extensions.Options;

namespace LRN.AveragesImport.Worker;

public sealed class AveragesImportWorker : BackgroundService
{
    private readonly ILabRunProvider _labRunProvider;
    private readonly IAverageAggregateReader _aggregateReader;
    private readonly IImportService _importService;
    private readonly IOptions<ImportSettings> _settings;
    private readonly ILogger<AveragesImportWorker> _logger;

    // Run logging + workflow tracker (LRNMaster). These are what the report dashboard reads.
    private readonly ReportRunIdInfoLogger _infoLogger;
    private readonly ReportsWorkflowTrackerRepository _workflowTracker;

    public AveragesImportWorker(
        ILabRunProvider labRunProvider,
        IAverageAggregateReader aggregateReader,
        IImportService importService,
        ReportRunIdInfoLogger infoLogger,
        ReportsWorkflowTrackerRepository workflowTracker,
        IOptions<ImportSettings> settings,
        ILogger<AveragesImportWorker> logger)
    {
        _labRunProvider = labRunProvider;
        _aggregateReader = aggregateReader;
        _importService = importService;
        _infoLogger = infoLogger;
        _workflowTracker = workflowTracker;
        _settings = settings;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = TimeSpan.FromMinutes(Math.Max(1, _settings.Value.IntervalMinutes));
        _logger.LogInformation("LRN Averages Import Service started; interval {Interval}", interval);

        // First cycle immediately, then on the timer. Cycles run sequentially on this
        // loop, so a cycle still executing simply absorbs the missed tick (no overlap).
        await RunCycleSafeAsync(interval, stoppingToken);

        using var timer = new PeriodicTimer(interval);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
                await RunCycleSafeAsync(interval, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }

        _logger.LogInformation("LRN Averages Import Service stopping");
    }

    private async Task RunCycleSafeAsync(TimeSpan interval, CancellationToken ct)
    {
        var stopwatch = Stopwatch.StartNew();
        try
        {
            await RunCycleAsync(ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Import cycle failed unexpectedly");
        }
        finally
        {
            stopwatch.Stop();
            if (stopwatch.Elapsed > interval)
                _logger.LogWarning(
                    "Cycle took {Elapsed} — longer than the {Interval} interval; intervening timer tick(s) were skipped",
                    stopwatch.Elapsed, interval);
        }
    }

    private async Task RunCycleAsync(CancellationToken ct)
    {
        _logger.LogInformation("Import cycle starting");

        var runs = await _labRunProvider.GetSuccessRunsAsync(ct);
        _logger.LogInformation("SP returned {Count} mapped SUCCESS run(s) to evaluate", runs.Count);

        var results = new List<ImportResult>();

        foreach (var run in runs)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                results.AddRange(await ProcessLabAsync(run, ct));
            }
            catch (Exception ex)
            {
                // One lab failing must never stop the others.
                _logger.LogError(ex, "Unhandled failure while processing lab {LabName} (RunId {RunId}); continuing with next lab",
                    run.LabName, run.RunId);
            }
        }

        _logger.LogInformation(
            "Import cycle finished: {Imported} imported, {Skipped} already imported, {NoData} with no source data, {Failed} failed",
            results.Count(r => r.Status == ImportStatus.Imported),
            results.Count(r => r.Status == ImportStatus.SkippedAlreadyImported),
            results.Count(r => r.Status == ImportStatus.NoSourceData),
            results.Count(r => r.Status == ImportStatus.Failed));
    }

    private async Task<List<ImportResult>> ProcessLabAsync(LabRunInfo run, CancellationToken ct)
    {
        var results = new List<ImportResult>();

        foreach (var fileType in FileTypes.All)
        {
            var source = _aggregateReader.DescribeSource(run, fileType);
            var reportName = WorkflowReportNames.For(fileType);

            // Step 2 — do not repeat work already done for this RunId. Only a Success row
            // stops us; a previous Failed or Skipped run is exactly the one to retry.
            // Two guards on purpose: the tracker is what the dashboard reads, while
            // AverageImportLog and the RunId stamped on the average tables are what prove
            // the data itself landed. Either being satisfied means there is nothing to do.
            if (await _workflowTracker.IsAlreadySuccessfulAsync(run.RunId, reportName, ct)
                || await _importService.IsAlreadyImportedAsync(run.RunId, run.LabId, fileType, ct))
            {
                _logger.LogInformation("Already generated — skipping {FileType} for {LabName}, RunId {RunId}",
                    fileType, run.LabName, run.RunId);
                results.Add(NewResult(run, fileType, ImportStatus.SkippedAlreadyImported, source));
                continue;
            }

            // Step 3 — open the trail and mark the tracker InProgress before any work starts.
            var startedOn = DateTime.Now;
            await _infoLogger.StartAsync(run.RunId, reportName, run.LabName,
                $"{reportName} started for {run.LabName} (LabId={run.LabId}); source {source}.", source, ct);
            await _workflowTracker.UpsertAsync(run.RunId, reportName, WorkflowStatus.InProgress,
                startedOn: startedOn, ct: ct);

            ImportResult result;

            // The full exception text belongs in the info log; the tracker only carries a
            // short remark. ImportService returns a Failed result instead of throwing, so it
            // has no exception to offer — the two failure paths converge here and the info
            // log gets whatever detail each one actually has.
            string? fullError = null;

            try
            {
                result = fileType == FileTypes.CptAverage
                    ? await ImportCptAsync(run, source, reportName, ct)
                    : await ImportPanelAsync(run, source, reportName, ct);
            }
            catch (Exception ex)
            {
                // Aggregation failed (unreachable lab DB, missing LineLevelData, timeout).
                // One aggregate failing must not stop the other, or the next lab.
                _logger.LogError(ex, "Aggregation failed for {FileType} from {Source} (LabName {LabName}, RunId {RunId})",
                    fileType, source, run.LabName, run.RunId);
                await _importService.RecordFailureAsync(run, fileType, source, ex.Message, ct);
                fullError = ex.ToString();
                result = NewResult(run, fileType, ImportStatus.Failed, source, ex.Message);
            }

            // Step 4 — record the outcome, then close the trail. Every path writes a row:
            // an absent one is indistinguishable from a crashed process.
            await RecordOutcomeAsync(run, reportName, source, result, startedOn, fullError, ct);
            results.Add(result);
        }

        _logger.LogInformation(
            "Lab {LabName} (RunId {RunId}) summary: {Summary}",
            run.LabName, run.RunId,
            string.Join("; ", results.Select(r => $"{r.FileType}={r.Status}" +
                (r.Status == ImportStatus.Imported ? $" ({r.RowsImported} rows)" : string.Empty))));

        return results;
    }

    private async Task<ImportResult> ImportCptAsync(LabRunInfo run, string source, string reportName, CancellationToken ct)
    {
        var records = await _aggregateReader.ReadCptAveragesAsync(run, ct);
        if (records.Count == 0)
        {
            // An empty aggregate is not a failure, but overwriting good rows with
            // nothing would be — leave the existing CPTAverage rows in place.
            _logger.LogWarning("No CptAverage rows aggregated from {Source} for {LabName} (RunId {RunId}) — nothing written",
                source, run.LabName, run.RunId);
            return NewResult(run, FileTypes.CptAverage, ImportStatus.NoSourceData, source);
        }

        await _infoLogger.InfoAsync(run.RunId, reportName, run.LabName,
            $"Aggregated {records.Count} CPTAverage row(s) from {source}.", source, ct);

        return await _importService.ImportCptAveragesAsync(run, source, records, ct);
    }

    private async Task<ImportResult> ImportPanelAsync(LabRunInfo run, string source, string reportName, CancellationToken ct)
    {
        var records = await _aggregateReader.ReadPanelAveragesAsync(run, ct);
        if (records.Count == 0)
        {
            _logger.LogWarning("No PanelAverage rows aggregated from {Source} for {LabName} (RunId {RunId}) — nothing written",
                source, run.LabName, run.RunId);
            return NewResult(run, FileTypes.PanelAverage, ImportStatus.NoSourceData, source);
        }

        await _infoLogger.InfoAsync(run.RunId, reportName, run.LabName,
            $"Aggregated {records.Count} PanelAverage row(s) from {source}.", source, ct);

        return await _importService.ImportPanelAveragesAsync(run, source, records, ct);
    }

    /// <summary>
    /// Step 4 for every terminal state. NoSourceData maps to Skipped rather than Failed:
    /// the lab database simply has not been loaded with this run yet, which is a legitimate
    /// no-op the worker retries next cycle — but it still needs a row and a reason.
    /// </summary>
    private async Task RecordOutcomeAsync(
        LabRunInfo run, string reportName, string source, ImportResult result,
        DateTime startedOn, string? fullError, CancellationToken ct)
    {
        var completedOn = DateTime.Now;

        switch (result.Status)
        {
            case ImportStatus.Imported:
                await _infoLogger.InfoAsync(run.RunId, reportName, run.LabName,
                    $"{reportName} completed. Rows={result.RowsImported}.", source, ct);
                await _workflowTracker.UpsertAsync(run.RunId, reportName, WorkflowStatus.Success,
                    rowCount: result.RowsImported, startedOn: startedOn, completedOn: completedOn, ct: ct);
                break;

            case ImportStatus.NoSourceData:
                await _infoLogger.WarningAsync(run.RunId, reportName, run.LabName,
                    $"{source} holds no rows for run {run.RunId}; nothing written.", source, ct);
                await _workflowTracker.UpsertAsync(run.RunId, reportName, WorkflowStatus.Skipped,
                    startedOn: startedOn, completedOn: completedOn,
                    remarks: $"No rows in {source} for this RunId — awaiting capture.", ct: ct);
                break;

            default:
                await _infoLogger.WriteErrorAsync(run.RunId, reportName, run.LabName,
                    fullError ?? result.Error ?? $"{reportName} failed for {run.LabName} with no error detail.", source, ct);
                await _workflowTracker.UpsertAsync(run.RunId, reportName, WorkflowStatus.Failed,
                    startedOn: startedOn, completedOn: completedOn, remarks: result.Error, ct: ct);
                break;
        }

        await _infoLogger.EndAsync(run.RunId, reportName, run.LabName,
            $"{reportName} processing ended ({result.Status}).", source, ct);
    }

    private static ImportResult NewResult(
        LabRunInfo run, string fileType, ImportStatus status, string? source = null, string? error = null)
        => new()
        {
            RunId = run.RunId,
            LabId = run.LabId,
            LabName = run.LabName,
            FileType = fileType,
            Status = status,
            Source = source,
            Error = error
        };
}
