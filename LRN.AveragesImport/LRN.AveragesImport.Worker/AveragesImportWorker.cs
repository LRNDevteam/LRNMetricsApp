using System.Diagnostics;
using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Models;
using LRN.AveragesImport.Core.Services;
using Microsoft.Extensions.Options;

namespace LRN.AveragesImport.Worker;

public sealed class AveragesImportWorker : BackgroundService
{
    private readonly ILabRunProvider _labRunProvider;
    private readonly IFileLocator _fileLocator;
    private readonly ICsvReaderService _csvReader;
    private readonly IImportService _importService;
    private readonly IOptions<ImportSettings> _settings;
    private readonly ILogger<AveragesImportWorker> _logger;

    public AveragesImportWorker(
        ILabRunProvider labRunProvider,
        IFileLocator fileLocator,
        ICsvReaderService csvReader,
        IImportService importService,
        IOptions<ImportSettings> settings,
        ILogger<AveragesImportWorker> logger)
    {
        _labRunProvider = labRunProvider;
        _fileLocator = fileLocator;
        _csvReader = csvReader;
        _importService = importService;
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
            "Import cycle finished: {Imported} imported, {Skipped} already imported, {NotFound} files not found, {Failed} failed",
            results.Count(r => r.Status == ImportStatus.Imported),
            results.Count(r => r.Status == ImportStatus.SkippedAlreadyImported),
            results.Count(r => r.Status == ImportStatus.FileNotFound),
            results.Count(r => r.Status == ImportStatus.Failed));
    }

    private async Task<List<ImportResult>> ProcessLabAsync(LabRunInfo run, CancellationToken ct)
    {
        var results = new List<ImportResult>();

        foreach (var fileType in FileTypes.All)
        {
            if (await _importService.IsAlreadyImportedAsync(run.RunId, run.LabId, fileType, ct))
            {
                _logger.LogInformation("Already imported — skipping {FileType} for {LabName}, RunId {RunId}",
                    fileType, run.LabName, run.RunId);
                results.Add(NewResult(run, fileType, ImportStatus.SkippedAlreadyImported));
                continue;
            }

            var filePath = _fileLocator.FindFile(run.FolderName, run.RunId, fileType);
            if (filePath is null)
            {
                // A missing file type is a warning (already logged by the locator),
                // not a lab failure — the other file type still gets imported.
                results.Add(NewResult(run, fileType, ImportStatus.FileNotFound));
                continue;
            }

            try
            {
                results.Add(fileType == FileTypes.CptAverage
                    ? await ImportCptAsync(run, filePath, ct)
                    : await ImportPanelAsync(run, filePath, ct));
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Parsing failed for {FileType} file {File} (LabName {LabName}, RunId {RunId})",
                    fileType, filePath, run.LabName, run.RunId);
                await _importService.RecordFailureAsync(run, fileType, Path.GetFileName(filePath), ex.Message, ct);
                results.Add(NewResult(run, fileType, ImportStatus.Failed, Path.GetFileName(filePath), ex.Message));
            }
        }

        _logger.LogInformation(
            "Lab {LabName} (RunId {RunId}) summary: {Summary}",
            run.LabName, run.RunId,
            string.Join("; ", results.Select(r => $"{r.FileType}={r.Status}" +
                (r.Status == ImportStatus.Imported ? $" ({r.RowsImported} rows, {r.BadRows} bad)" : string.Empty))));

        return results;
    }

    private async Task<ImportResult> ImportCptAsync(LabRunInfo run, string filePath, CancellationToken ct)
    {
        var parsed = _csvReader.ReadCptAverages(filePath);
        return await _importService.ImportCptAveragesAsync(run, filePath, parsed.Records, parsed.BadRowCount, ct);
    }

    private async Task<ImportResult> ImportPanelAsync(LabRunInfo run, string filePath, CancellationToken ct)
    {
        var parsed = _csvReader.ReadPanelAverages(filePath);
        return await _importService.ImportPanelAveragesAsync(run, filePath, parsed.Records, parsed.BadRowCount, ct);
    }

    private static ImportResult NewResult(
        LabRunInfo run, string fileType, ImportStatus status, string? fileName = null, string? error = null)
        => new()
        {
            RunId = run.RunId,
            LabId = run.LabId,
            LabName = run.LabName,
            FileType = fileType,
            Status = status,
            FileName = fileName,
            Error = error
        };
}
