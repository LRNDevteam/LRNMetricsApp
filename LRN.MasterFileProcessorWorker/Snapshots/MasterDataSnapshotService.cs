using System.Data;
using System.Diagnostics;
using System.Security.Cryptography;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.Snapshots;

/// <summary>One table to snapshot. <paramref name="ExpectedRows"/> is what this run loaded into it, when known.</summary>
public sealed record SnapshotDataset(string ReportCode, string ConnectionString, string TableName, long? ExpectedRows);

public sealed record MasterDataSnapshotRequest(
    int LabId,
    string LabName,
    string LabCode,
    string RunId,
    string WeekFolder,
    IReadOnlyList<SnapshotDataset> Datasets);

public enum MasterDataSnapshotStatus { Skipped, Succeeded, Failed }

public sealed record MasterDataSnapshotOutcome(
    MasterDataSnapshotStatus Status,
    string Message,
    long? SnapshotRunId = null,
    int Files = 0,
    long Rows = 0,
    int ExpiredRuns = 0);

/// <summary>
/// Step 88: writes this week's Line Level, Claim Level and LIMS tables of one lab to Parquet,
/// uploads each file, records it in LRNMaster, then deletes the runs that fall outside retention.
/// <para>
/// Per dataset: SELECT * streamed into a local file -> footer row count must equal rows read ->
/// SHA-256 -> upload to <c>{LabName}/{RunId}_{WeekRange}_{code}.parquet</c> ->
/// dbo.ReportSnapshotFile row. All datasets succeed or the run is marked Failed; retention only
/// runs after a successful snapshot, so a failing week never costs an older one.
/// </para>
/// <para>
/// Never throws (bar cancellation): the tables are already loaded when this runs, so a snapshot
/// failure is an outcome for the caller to log, not a reason to fail the weekly load.
/// </para>
/// </summary>
public sealed class MasterDataSnapshotService
{
    private readonly MasterDataSnapshotOptions _options;
    private readonly SnapshotStoreFactory _stores;
    private readonly ReportSnapshotRepository _index;
    private readonly ILogger<MasterDataSnapshotService> _logger;

    public MasterDataSnapshotService(
        IOptions<MasterDataSnapshotOptions> options,
        SnapshotStoreFactory stores,
        ReportSnapshotRepository index,
        ILogger<MasterDataSnapshotService> logger)
    {
        _options = options.Value;
        _stores = stores;
        _index = index;
        _logger = logger;
    }

    public MasterDataSnapshotOptions Options => _options;

    /// <summary>The worker-wide switch. Whether a given lab takes part is its own MasterDataSnapshotEnabled flag, checked by the worker.</summary>
    public bool IsEnabled => _options.Enabled;

    public async Task<MasterDataSnapshotOutcome> SnapshotLabAsync(MasterDataSnapshotRequest request, CancellationToken ct)
    {
        if (!_options.Enabled)
            return new(MasterDataSnapshotStatus.Skipped, "MasterDataSnapshot:Enabled is false.");
        if (request.Datasets.Count == 0)
            return new(MasterDataSnapshotStatus.Skipped, "No master table loaded in this run, so there is nothing to snapshot.");

        var snapshotDate = SnapshotWeek.AsOfDate(request.WeekFolder) ?? DateTime.Today;
        var prefix = SnapshotPaths.RunPrefix(request.LabCode, request.WeekFolder, request.RunId);
        var workFolder = Path.Combine(
            string.IsNullOrWhiteSpace(_options.WorkFolder) ? Path.Combine(Path.GetTempPath(), "LRN-Snapshots") : _options.WorkFolder,
            $"{request.LabId}_{SnapshotPaths.Segment(request.RunId)}");

        long snapshotRunId;
        ISnapshotStore store;

        try
        {
            store = _stores.Store;
            string? previousPrefix;
            (snapshotRunId, previousPrefix) = await _index.StartRunAsync(request.LabId, request.LabName, request.RunId,
                request.WeekFolder, snapshotDate, prefix, ct).ConfigureAwait(false);

            // The same RunId again: its index rows are gone, so remove every file it had (master data and
            // the report snapshots filed under it) before writing the new ones - none is left behind
            // unindexed. A re-run with a new RunId replaces the week through retention instead, below.
            if (!string.IsNullOrWhiteSpace(previousPrefix))
            {
                var removed = await store.DeletePrefixAsync(previousPrefix, ct).ConfigureAwait(false);
                _logger.LogInformation("Lab {LabId}: run {RunId} snapshotted again - {Removed} earlier file(s) under {Prefix} deleted first.",
                    request.LabId, request.RunId, removed, previousPrefix);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogError(ex, "Lab {LabId}: snapshot could not start for run {RunId}.", request.LabId, request.RunId);
            return new(MasterDataSnapshotStatus.Failed, $"Snapshot could not start: {ex.Message}");
        }

        var notes = new List<string>();
        int files = 0;
        long rows = 0;
        var stopwatch = Stopwatch.StartNew();

        try
        {
            Directory.CreateDirectory(workFolder);

            foreach (var dataset in request.Datasets)
            {
                ct.ThrowIfCancellationRequested();

                var file = await SnapshotTableAsync(dataset, prefix, workFolder, store, ct).ConfigureAwait(false);
                await _index.AddFileAsync(snapshotRunId, file, ct).ConfigureAwait(false);

                files++;
                rows += file.RowCount;

                if (dataset.ExpectedRows is long expected && expected != file.RowCount)
                    notes.Add($"{dataset.ReportCode}: snapshot has {file.RowCount:N0} rows but this run loaded {expected:N0}.");

                _logger.LogInformation("Lab {LabId}: {Code} snapshot {Rows} rows, {Bytes} bytes -> {Path}",
                    request.LabId, dataset.ReportCode, file.RowCount, file.SizeBytes, file.BlobPath);
            }

            await _index.CompleteRunAsync(snapshotRunId, SnapshotRunStatus.Success, null, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogError(ex, "Lab {LabId}: snapshot failed for run {RunId}.", request.LabId, request.RunId);

            try
            {
                await _index.CompleteRunAsync(snapshotRunId, SnapshotRunStatus.Failed, ex.Message, ct).ConfigureAwait(false);
            }
            catch (Exception markEx)
            {
                _logger.LogWarning(markEx, "Lab {LabId}: could not mark snapshot run {SnapshotRunId} Failed.", request.LabId, snapshotRunId);
            }

            return new(MasterDataSnapshotStatus.Failed, $"Snapshot failed after {files} of {request.Datasets.Count} file(s): {ex.Message}",
                snapshotRunId, files, rows);
        }
        finally
        {
            TryDeleteDirectory(workFolder);
        }

        var expired = await ApplyRetentionAsync(request.LabId, snapshotRunId, store, notes, ct).ConfigureAwait(false);

        var message = $"Snapshot #{snapshotRunId}: {files} file(s), {rows:N0} rows -> {store.Location}/{prefix}*.parquet " +
                      $"in {stopwatch.Elapsed.TotalSeconds:N0}s. Retention (keep {Math.Max(1, _options.KeepWeeks)} week(s)" +
                      (_options.KeepMonthEnd > 0 ? $" + {_options.KeepMonthEnd} month-end(s)" : "") +
                      $") removed {expired} older run(s)." +
                      (notes.Count > 0 ? " " + string.Join(" ", notes) : "");

        return new(MasterDataSnapshotStatus.Succeeded, message, snapshotRunId, files, rows, expired);
    }

    private async Task<SnapshotFileInfo> SnapshotTableAsync(
        SnapshotDataset dataset, string prefix, string workFolder, ISnapshotStore store, CancellationToken ct)
    {
        var localPath = Path.Combine(workFolder, $"{dataset.ReportCode}.parquet");
        var table = Database.LabDatabaseMasterReader.QuoteTableName(dataset.TableName);

        ParquetWriteResult result;

        await using (var conn = new SqlConnection(dataset.ConnectionString))
        {
            await conn.OpenAsync(ct).ConfigureAwait(false);

            await using var cmd = new SqlCommand($"SELECT * FROM {table};", conn)
            {
                CommandTimeout = Math.Max(60, _options.CommandTimeoutSeconds)
            };

            await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct).ConfigureAwait(false);

            result = await ParquetSnapshotWriter.WriteAsync(reader, localPath, _options.RowGroupSize,
                ParquetSnapshotWriter.ParseCompression(_options.Compression), ct).ConfigureAwait(false);
        }

        var inFile = await ParquetSnapshotWriter.ReadRowCountAsync(localPath, ct).ConfigureAwait(false);
        if (inFile != result.RowCount)
            throw new InvalidOperationException($"{dataset.ReportCode}: row count mismatch, {result.RowCount} read from {table} but {inFile} in the file.");

        string sha;
        await using (var fs = File.OpenRead(localPath))
            sha = Convert.ToHexString(await SHA256.HashDataAsync(fs, ct).ConfigureAwait(false));

        var size = new FileInfo(localPath).Length;
        var path = SnapshotPaths.FilePath(prefix, dataset.ReportCode);

        await store.UploadAsync(localPath, path, sha, ct).ConfigureAwait(false);
        TryDeleteFile(localPath);

        return new SnapshotFileInfo(dataset.ReportCode, MasterDataReportCodes.ResultSetName, path,
            result.RowCount, size, sha, result.SchemaJson, _options.SchemaVersion);
    }

    /// <summary>Files first, then the index row, so an interrupted delete leaves a row pointing at nothing rather than orphaned PHI.</summary>
    private async Task<int> ApplyRetentionAsync(int labId, long currentSnapshotRunId, ISnapshotStore store, List<string> notes, CancellationToken ct)
    {
        int removed = 0;

        try
        {
            var runs = await _index.ListRunsAsync(labId, ct).ConfigureAwait(false);
            var expired = SnapshotRetention.SelectExpired(runs, _options.KeepWeeks, _options.KeepMonthEnd, currentSnapshotRunId, DateTime.UtcNow);
            var currentWeek = runs.FirstOrDefault(r => r.SnapshotRunId == currentSnapshotRunId)?.WeekFolder.Trim();

            foreach (var run in expired)
            {
                ct.ThrowIfCancellationRequested();

                // A re-run of this week replaces the earlier run. Its generated report snapshots are taken
                // again for the new run when those reports finish; an uploaded one (Denial Insight) is
                // not regenerated, so it is requested again before its files go.
                if (currentWeek is not null && string.Equals(run.WeekFolder.Trim(), currentWeek, StringComparison.OrdinalIgnoreCase))
                {
                    var requested = await _index.RequestRecaptureOfUploadedReportsAsync(run.SnapshotRunId, labId,
                        $"Re-run of {currentWeek}: replaces run {run.RunId}", ct).ConfigureAwait(false);
                    if (requested > 0)
                        _logger.LogInformation("Lab {LabId}: {Count} uploaded report snapshot(s) of run {RunId} requested again for the re-run.",
                            labId, requested, run.RunId);
                }

                if (!string.IsNullOrWhiteSpace(run.BlobPrefix))
                    await store.DeletePrefixAsync(run.BlobPrefix, ct).ConfigureAwait(false);

                await _index.DeleteRunAsync(run.SnapshotRunId, ct).ConfigureAwait(false);
                removed++;

                _logger.LogInformation("Lab {LabId}: snapshot run {SnapshotRunId} ({WeekFolder}, {RunId}, {Status}) removed by retention.",
                    labId, run.SnapshotRunId, run.WeekFolder, run.RunId, run.Status);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            // The new snapshot is complete; an old one surviving another week is harmless and is
            // picked up again by the next run's retention pass.
            _logger.LogWarning(ex, "Lab {LabId}: snapshot retention failed after removing {Removed} run(s).", labId, removed);
            notes.Add($"Retention stopped after {removed} run(s): {ex.Message}");
        }

        return removed;
    }

    private static void TryDeleteFile(string path)
    {
        try { File.Delete(path); } catch { /* the work folder is removed at the end anyway */ }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); } catch { /* best effort */ }
    }
}
