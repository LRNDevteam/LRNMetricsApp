using System.Security.Cryptography;
using System.Text.RegularExpressions;
using LabMetricsDashboard.Models;
using LRN.MasterFileProcessorWorker.Snapshots;
using LRN.ProductionReports.Services;
using LRN.ReportWorker.Generators;
using Microsoft.Extensions.Options;

namespace LRN.SnapshotGenerator;

public enum ReportSnapshotOutcome { Captured, AlreadyCurrent, Settling, Superseded, NotAvailable, Failed }

/// <summary>
/// Captures each enabled lab's page reports per RunId, in the run's folder next to the master data files:
/// <list type="bullet">
///   <item>one Parquet file per section of the page's unfiltered view model -
///         <c>&lt;container&gt;/&lt;Lab&gt;/&lt;RunId&gt;_&lt;Week&gt;_&lt;REPORTCODE&gt;_&lt;Section&gt;.parquet</c>, for querying;</item>
///   <item>the view model itself as a display copy - <c>..._&lt;REPORTCODE&gt;_PageModel.json.gz</c> - so LRN Metrics
///         can show the week through the page's own views, with the report logic it was produced by.</item>
/// </list>
/// Indexed in LRNMaster.dbo.ReportSnapshotFile (ReportCode = EXECSUMMARY / ..., ResultSetName = section).
/// <para>
/// Triggers: a generated report when it turns Success in ReportsWorkflowTracker; the Executive Summary's
/// highlight tabs (other reports of the same run) with it; the client-uploaded Denial Insight tab when
/// LabMetricsDashboard requests it (dbo.ReportSnapshotRequest) after an upload or edit.
/// </para>
/// <para>
/// A page always reads the lab's CURRENT tables, so a report is captured only while its RunId is still
/// the run loaded in the lab database. Once the next week has loaded, an older RunId can no longer be
/// captured truthfully and is skipped as Superseded.
/// </para>
/// </summary>
public sealed partial class ReportSnapshotService
{
    private readonly IReadOnlyDictionary<string, IReportSnapshotSource> _sources;
    private readonly LabSettings _labSettings;
    private readonly IProductionReportRepository _runInfo;
    private readonly ReportSnapshotIndex _index;
    private readonly ReportSnapshotRepository _repository;
    private readonly SnapshotStoreFactory _storeFactory;
    private readonly MasterDataSnapshotOptions _storage;
    private readonly ReportSnapshotOptions _options;
    private readonly SnapshotWorkflowTracker _tracker;
    private readonly ILogger<ReportSnapshotService> _logger;
    // RunIds already reported as superseded, so the warning is logged once, not every poll.
    private readonly HashSet<string> _reportedSuperseded = new(StringComparer.OrdinalIgnoreCase);

    public ReportSnapshotService(
        IEnumerable<IReportSnapshotSource> sources,
        LabSettings labSettings,
        IProductionReportRepository runInfo,
        ReportSnapshotIndex index,
        ReportSnapshotRepository repository,
        SnapshotStoreFactory storeFactory,
        IOptions<MasterDataSnapshotOptions> storage,
        IOptions<ReportSnapshotOptions> options,
        SnapshotWorkflowTracker tracker,
        ILogger<ReportSnapshotService> logger)
    {
        _tracker = tracker;
        _sources = sources.ToDictionary(s => s.SnapshotReportCode, StringComparer.OrdinalIgnoreCase);
        _labSettings = labSettings;
        _runInfo = runInfo;
        _index = index;
        _repository = repository;
        _storeFactory = storeFactory;
        _storage = storage.Value;
        _options = options.Value;
        _logger = logger;
    }

    /// <summary>--once: the tracker poll, then every pending request without waiting for it to settle.</summary>
    public async Task RunOnceAsync(CancellationToken ct)
    {
        await PollTrackerAsync(ct, ignoreSettle: true);
        await ProcessRequestsAsync(ignoreSettle: true, ct);
    }

    // When this service first saw each tracker Success (lab, run, report, stamp), by its own clock: the
    // settle wait is timed from here, so it does not depend on the tracker column's time zone.
    private readonly Dictionary<string, DateTime> _firstSeenUtc = new(StringComparer.OrdinalIgnoreCase);

    private bool Settled(LabSnapshotConfig lab, TrackerSuccess success)
    {
        var key = $"{lab.LabId}|{success.RunId}|{success.ReportName}|{success.StampText}";
        var now = DateTime.UtcNow;
        if (!_firstSeenUtc.TryGetValue(key, out var seen))
            _firstSeenUtc[key] = seen = now;
        if (_firstSeenUtc.Count > 5000)   // a long-running service: forget the oldest sightings
            foreach (var old in _firstSeenUtc.OrderBy(kv => kv.Value).Take(1000).Select(kv => kv.Key).ToList())
                _firstSeenUtc.Remove(old);
        return now - seen >= TimeSpan.FromMinutes(Math.Max(0, _options.SettleMinutes));
    }

    private string LabsFolder =>
        Path.IsPathRooted(_options.LabsFolder) ? _options.LabsFolder : Path.Combine(AppContext.BaseDirectory, _options.LabsFolder);

    private List<LabSnapshotConfig> LoadLabs()
    {
        var (labs, errors) = LabSnapshotConfig.LoadAll(LabsFolder);
        foreach (var error in errors)
            _logger.LogWarning("Report snapshot lab config: {Error}", error);
        return labs;
    }

    // ── generated reports: ReportsWorkflowTracker ─────────────────────────────

    public async Task PollTrackerAsync(CancellationToken ct, bool ignoreSettle = false)
    {
        var enabled = LoadLabs().Where(l => l.Enabled).ToList();
        if (enabled.Count == 0)
        {
            _logger.LogInformation("Report snapshots: no lab is enabled in {Folder}.", LabsFolder);
            return;
        }

        // Which tracker report names to look for, per lab. On-request reports (Denial Insight) have none.
        var wanted = enabled.SelectMany(lab => SnapshotReports.All
                .Where(def => !def.OnRequest)
                .Select(def => (Lab: lab, Def: def, Cfg: lab.Reports.GetValueOrDefault(def.Key)))
                .Where(x => x.Cfg?.Enabled ?? false)
                .Select(x => (x.Lab, x.Def, TrackerName: string.IsNullOrWhiteSpace(x.Cfg!.TrackerReportName) ? x.Def.DefaultTrackerReportName! : x.Cfg.TrackerReportName)))
            .ToList();
        if (wanted.Count == 0) return;

        var successes = await _index.GetTrackerSuccessesAsync(
            wanted.Select(w => w.Lab.LabId).Distinct().ToList(),
            wanted.Select(w => w.TrackerName).Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
            _options.LookbackDays, ct);
        _logger.LogInformation("Report snapshots: tracker poll - {Labs} lab(s) enabled ({LabKeys}), {Rows} Success row(s) in the last {Days} day(s) (tracker time column: {Column}).",
            enabled.Count, string.Join(", ", enabled.Select(l => $"{l.LabKey}#{l.LabId}")), successes.Count, _options.LookbackDays,
            await _index.GetTrackerStampColumnAsync(ct) ?? "none");

        // Newest first: per lab + report only the most recent Success matters (older runs are superseded anyway).
        var touchedLabs = new HashSet<int>();
        var outcomes = new List<string>();
        foreach (var (lab, def, trackerName) in wanted)
        {
            var latest = successes.FirstOrDefault(s => s.LabId == lab.LabId
                && string.Equals(s.ReportName, trackerName, StringComparison.OrdinalIgnoreCase));
            if (latest is null)
            {
                outcomes.Add($"{lab.LabKey} {def.ReportCode}: no '{trackerName}' Success");
                continue;
            }

            var outcome = await SnapshotReportAsync(lab, def, latest, ignoreSettle, ct);
            outcomes.Add($"{lab.LabKey} {def.ReportCode} {latest.RunId}: {outcome}");
            if (outcome == ReportSnapshotOutcome.Captured) touchedLabs.Add(lab.LabId);
        }
        _logger.LogInformation("Report snapshots: tracker poll done - {Outcomes}.", string.Join("; ", outcomes));

        foreach (var labId in touchedLabs)
            await ApplyRetentionAsync(labId, ct);
    }

    private async Task<ReportSnapshotOutcome> SnapshotReportAsync(LabSnapshotConfig lab, SnapshotReports.Definition def, TrackerSuccess success,
        bool ignoreSettle, CancellationToken ct)
    {
        var tag = $"{lab.LabKey} {def.ReportCode} {success.RunId}";
        try
        {
            // Already captured for this Success: same run and the same tracker stamp. A re-run of the report
            // writes a new stamp and is captured again; a capture without a stored stamp counts as current.
            var (captured, stamp) = await _index.GetCaptureAsync(lab.LabId, success.RunId, def.ReportCode, ct);
            if (captured && (stamp is null || success.StampText is null || stamp == success.StampText))
                return ReportSnapshotOutcome.AlreadyCurrent;

            // A Success just written may still be followed by the report's last writes: wait SettleMinutes.
            if (!ignoreSettle && !Settled(lab, success))
                return ReportSnapshotOutcome.Settling;

            return await CaptureAsync(lab, def, success, $"{success.ReportName} Success", ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogError(ex, "Report snapshot {Tag} failed; it is retried on the next poll.", tag);
            await TrackAsync(lab, success.RunId, success.LabName, success.WeekFolder, failed: true,
                $"{def.ReportCode} failed: {ex.Message}", ct);
            return ReportSnapshotOutcome.Failed;
        }
    }

    /// <summary>The run's "Report Snapshot" row in ReportsWorkflowTracker, with what the run holds now.</summary>
    private async Task TrackAsync(LabSnapshotConfig lab, string runId, string? labName, string? weekFolder, bool failed, string lastEvent, CancellationToken ct)
    {
        try
        {
            var (codes, files) = await _index.GetRunReportsAsync(lab.LabId, runId, ct);
            await _tracker.WriteAsync(runId, lab.LabId, string.IsNullOrWhiteSpace(labName) ? lab.LabKey : labName!,
                weekFolder, failed, files, codes, lastEvent, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogWarning(ex, "Report snapshot tracker row for {Lab} run {RunId} could not be written.", lab.LabKey, runId);
        }
    }

    // ── uploaded reports: dbo.ReportSnapshotRequest ───────────────────────────

    /// <summary>
    /// Captures each lab + report with Pending requests once the newest of them is <c>RequestSettleSeconds</c>
    /// old, under the run the lab database holds now - the week the client uploaded for.
    /// </summary>
    public async Task ProcessRequestsAsync(bool ignoreSettle, CancellationToken ct)
    {
        var pending = await _index.GetPendingRequestsAsync(ct);
        if (pending.Count == 0) return;

        var labs = LoadLabs();
        // LabMetricsDashboard names the lab by its key, the master file processor (a re-run) by LabId.
        LabSnapshotConfig? LabOf(SnapshotRequest r) => !string.IsNullOrWhiteSpace(r.LabKey)
            ? labs.FirstOrDefault(l => string.Equals(l.LabKey, r.LabKey.Trim(), StringComparison.OrdinalIgnoreCase))
            : labs.FirstOrDefault(l => l.LabId == r.LabId);
        string LabName(SnapshotRequest r) => r.LabKey?.Trim() is { Length: > 0 } key ? key : $"LabId {r.LabId}";

        var settledBefore = DateTime.UtcNow.AddSeconds(-Math.Max(0, _options.RequestSettleSeconds));
        foreach (var group in pending.GroupBy(p => (Lab: LabOf(p)?.LabKey.ToUpperInvariant() ?? LabName(p), Code: p.ReportCode.Trim().ToUpperInvariant())))
        {
            var requests = group.ToList();
            if (!ignoreSettle && requests.Max(r => r.RequestedOnUtc) > settledBefore) continue;

            var first = requests[0];
            var def = SnapshotReports.ByCode(first.ReportCode);
            var lab = LabOf(first);
            var skip = def is null || !def.OnRequest ? $"{first.ReportCode} is not captured on request."
                : lab is null ? $"No lab file for {LabName(first)} in {LabsFolder}."
                : !lab.Enabled ? $"Snapshots are off for the lab (Enabled = false in {lab.SourceFile})."
                : !(lab.Reports.GetValueOrDefault(def.Key)?.Enabled ?? false) ? $"{def.Key} is off in {lab.SourceFile}."
                : null;
            if (skip is not null)
            {
                _logger.LogInformation("Snapshot request {Code} for {Lab} skipped: {Reason}", first.ReportCode, first.LabKey, skip);
                foreach (var r in requests) await _index.CloseRequestAsync(r, "Skipped", null, skip, ct);
                continue;
            }

            string? runId = null;
            try
            {
                if (!_labSettings.Labs.TryGetValue(lab!.LabKey, out var labConfig) || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
                    throw new InvalidOperationException($"Lab key '{lab.LabKey}' is not in ReportWorker:Labs or has no database connection.");

                var (weekFolder, loadedRunId) = await _runInfo.GetRunInfoAsync(labConfig.DbConnectionString, ct);
                runId = loadedRunId?.Trim();
                if (string.IsNullOrWhiteSpace(runId))
                    throw new InvalidOperationException("The lab database has no run loaded, so the upload has no run to be filed under.");

                var latest = requests.MaxBy(r => r.RequestedOnUtc)!;
                var trigger = $"{latest.Reason ?? "Upload"} ({latest.RequestedBy})";
                var outcome = await CaptureAsync(lab, def!,
                    new TrackerSuccess(runId, lab.LabId, null, weekFolder, def!.Key, latest.RequestedOnUtc), trigger, ct);

                var (status, message) = outcome == ReportSnapshotOutcome.Captured
                    ? ("Done", (string?)null)
                    : ("Skipped", $"Not captured: {outcome}.");
                foreach (var r in requests) await _index.CloseRequestAsync(r, status, runId, message, ct);
                if (outcome == ReportSnapshotOutcome.Captured) await ApplyRetentionAsync(lab.LabId, ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                _logger.LogError(ex, "Snapshot request {Code} for {Lab} failed.", first.ReportCode, LabName(first));
                if (!string.IsNullOrWhiteSpace(runId))
                    await TrackAsync(lab!, runId, null, null, failed: true, $"{first.ReportCode} (upload) failed: {ex.Message}", ct);
                foreach (var r in requests)
                {
                    if (r.Attempts + 1 >= Math.Max(1, _options.RequestMaxAttempts))
                        await _index.CloseRequestAsync(r, "Failed", runId, ex.Message, ct);
                    else
                        await _index.RecordRequestFailureAsync(r, ex.Message, ct);
                }
            }
        }
    }

    // ── one capture ───────────────────────────────────────────────────────────

    /// <summary>Loads, fingerprints and writes one report for one run. Throws on failure; the caller decides about retries.</summary>
    private async Task<ReportSnapshotOutcome> CaptureAsync(
        LabSnapshotConfig lab, SnapshotReports.Definition def, TrackerSuccess success, string trigger, CancellationToken ct)
    {
        var tag = $"{lab.LabKey} {def.ReportCode} {success.RunId}";
        if (!_sources.TryGetValue(def.ReportCode, out var source))
            throw new InvalidOperationException($"No snapshot source registered for {def.ReportCode}.");
        if (!_labSettings.Labs.TryGetValue(lab.LabKey, out var labConfig) || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
        {
            _logger.LogWarning("Report snapshot {Tag}: lab key '{LabKey}' ({File}) is not in ReportWorker:Labs or has no database connection.",
                tag, lab.LabKey, lab.SourceFile);
            return ReportSnapshotOutcome.NotAvailable;
        }

        // The page reads the lab's current tables: only snapshot while this RunId is what they hold.
        var (_, loadedRunId) = await _runInfo.GetRunInfoAsync(labConfig.DbConnectionString, ct);
        if (!string.IsNullOrWhiteSpace(loadedRunId) && !string.Equals(loadedRunId.Trim(), success.RunId, StringComparison.OrdinalIgnoreCase))
        {
            if (_reportedSuperseded.Add(tag))
                _logger.LogWarning("Report snapshot {Tag} skipped: the lab database now holds run {Loaded}, so this run's page can no longer be captured.",
                    tag, loadedRunId);
            return ReportSnapshotOutcome.Superseded;
        }

        // Load through the page's own code, recording what it runs in the lab database.
        object? model;
        IReadOnlyList<RecordedSqlCommand> commands;
        using (var recording = SqlCommandRecorder.Start())
        {
            model = await source.LoadUnfilteredAsync(lab.LabKey, ct);
            commands = recording.Commands;
        }
        if (model is null)
        {
            _logger.LogInformation("Report snapshot {Tag}: the report is not available for this lab (not configured in LRN Metrics). Disable it in {File}.",
                tag, lab.SourceFile);
            return ReportSnapshotOutcome.NotAvailable;
        }

        var logic = await CaptureLogicAsync(labConfig.DbConnectionString, commands, tag, ct);
        var previous = await _index.GetPreviousPageModelAsync(lab.LabId, success.RunId, def.ReportCode, ct);
        var page = new ReportPageSnapshot
        {
            ReportCode = def.ReportCode,
            LabKey = lab.LabKey,
            LabName = string.IsNullOrWhiteSpace(success.LabName) ? lab.LabKey : success.LabName!,
            RunId = success.RunId,
            WeekFolder = success.WeekFolder ?? "",
            CapturedOnUtc = DateTime.UtcNow,
            Trigger = trigger,
            TrackerStamp = success.StampText,
            ModelType = model.GetType().FullName ?? model.GetType().Name,
            Logic = logic,
            LogicChanges = logic.ChangesSince(previous?.Logic),
            HighlightTabs = def.ReportCode == ReportSnapshotCodes.ExecutiveSummary
                ? SnapshotReports.ExecutiveSummaryHighlights(lab.LabKey)
                : [],
            Model = model
        };

        var sections = ViewModelSections.Extract(model);
        var written = await WriteSectionsAsync(lab, def, success, sections, page, ct);
        _logger.LogInformation("Report snapshot {Tag}: {Files} file(s), {Rows:N0} row(s), {Objects} report object(s) fingerprinted.",
            tag, written.Files, written.Rows, logic.Objects.Count);
        if (page.LogicChanges.Count > 0)
            _logger.LogWarning("Report snapshot {Tag}: the report logic changed since the previous week's snapshot: {Changes}. " +
                "Earlier snapshots keep the logic they were captured with.", tag, string.Join("; ", page.LogicChanges));
        await TrackAsync(lab, success.RunId, page.LabName, page.WeekFolder, failed: false,
            $"{def.ReportCode} captured ({trigger}): {written.Files} file(s), {written.Rows:N0} row(s)"
            + (page.LogicChanges.Count > 0 ? $"; report logic changed: {string.Join("; ", page.LogicChanges)}" : ""), ct);

        if (page.HighlightTabs.Count > 0)
            await CaptureHighlightReportsAsync(lab, success, page.HighlightTabs, ct);
        return ReportSnapshotOutcome.Captured;
    }

    /// <summary>
    /// The Executive Summary's highlight tabs are the Production / Collection / LIS / Denial pages of the same
    /// run: each is captured now unless it already is for this run, so an Executive Summary snapshot is
    /// never missing a tab. The report's own tracker Success later recaptures it as usual.
    /// </summary>
    private async Task CaptureHighlightReportsAsync(LabSnapshotConfig lab, TrackerSuccess success, List<SnapshotHighlightTab> tabs, CancellationToken ct)
    {
        foreach (var code in tabs.Select(t => t.ReportCode).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var def = SnapshotReports.ByCode(code);
            if (def is null) continue;
            try
            {
                if (await _index.GetLastSnapshotAsync(lab.LabId, success.RunId, code, ct) is not null) continue;
                await CaptureAsync(lab, def, success, "Executive Summary highlight tab", ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                _logger.LogError(ex, "Report snapshot {Lab} {Code} {RunId} (Executive Summary highlight tab) failed; it is captured on its own Success.",
                    lab.LabKey, code, success.RunId);
            }
        }
    }

    /// <summary>The objects the report ran, as defined now. A failure here never blocks the snapshot itself.</summary>
    private async Task<ReportLogicVersion> CaptureLogicAsync(string labConnectionString, IReadOnlyList<RecordedSqlCommand> commands, string tag, CancellationToken ct)
    {
        try
        {
            return await ReportLogicFingerprint.CaptureAsync(labConnectionString, commands, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogWarning(ex, "Report snapshot {Tag}: the report logic could not be fingerprinted; the snapshot is written without it.", tag);
            return new ReportLogicVersion { AppVersion = ReportLogicVersion.CurrentAppVersion() };
        }
    }

    private async Task<(int Files, long Rows)> WriteSectionsAsync(
        LabSnapshotConfig lab, SnapshotReports.Definition def, TrackerSuccess success, List<SnapshotSection> sections,
        ReportPageSnapshot page, CancellationToken ct)
    {
        var weekFolder = success.WeekFolder ?? "";
        var labName = string.IsNullOrWhiteSpace(success.LabName) ? lab.LabKey : success.LabName!;
        var prefix = SnapshotPaths.RunPrefix(labName.Replace(' ', '_'), weekFolder, success.RunId);
        var snapshotDate = SnapshotWeek.AsOfDate(weekFolder) ?? DateTime.UtcNow.Date;

        // Join the run's row (the master data files may already be in it, under its prefix) or start one.
        var run = await _index.EnsureRunAsync(lab.LabId, labName, success.RunId, weekFolder, snapshotDate, prefix, ct);
        prefix = string.IsNullOrWhiteSpace(run.BlobPrefix) ? prefix : run.BlobPrefix!;

        var store = _storeFactory.Store;
        var work = string.IsNullOrWhiteSpace(_storage.WorkFolder)
            ? Path.Combine(Path.GetTempPath(), "LRN-ReportSnapshots")
            : _storage.WorkFolder;
        Directory.CreateDirectory(work);
        var compression = ParquetSnapshotWriter.ParseCompression(_storage.Compression);

        await _index.DeleteReportFilesAsync(run.SnapshotRunId, def.ReportCode, ct);

        int files = 0;
        long rows = 0;
        // PageModel is the display copy's index name; a section of that name is numbered instead.
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ReportPageSnapshot.ResultSetName };
        foreach (var section in sections)
        {
            var name = UniqueName(SafeName(section.Name), usedNames);
            var local = Path.Combine(work, $"{Guid.NewGuid():N}.parquet");
            try
            {
                ParquetWriteResult result;
                using (var reader = section.Table.CreateDataReader())
                    result = await ParquetSnapshotWriter.WriteAsync(reader, local, Math.Max(1, _storage.RowGroupSize), compression, ct);

                var footerRows = await ParquetSnapshotWriter.ReadRowCountAsync(local, ct);
                if (footerRows != section.Table.Rows.Count)
                    throw new InvalidOperationException($"{def.ReportCode}/{name}: Parquet footer has {footerRows} rows, the page section had {section.Table.Rows.Count}.");

                var (sha, size) = await HashAsync(local, ct);
                var path = SnapshotPaths.FilePath(prefix, $"{def.ReportCode}_{name}");
                await store.UploadAsync(local, path, sha, ct);
                await _repository.AddFileAsync(run.SnapshotRunId,
                    new SnapshotFileInfo(def.ReportCode, name, path, result.RowCount, size, sha, result.SchemaJson, _storage.SchemaVersion), ct);

                files++;
                rows += result.RowCount;
            }
            finally
            {
                try { File.Delete(local); } catch { /* temp file; the folder is cleaned on the next run */ }
            }
        }

        if (await WritePageModelAsync(page, prefix, run.SnapshotRunId, store, work, ct))
            files++;

        await _index.MarkAvailableAsync(run.SnapshotRunId, run.Created, ct);
        return (files, rows);
    }

    /// <summary>
    /// The display copy. A view model that cannot be written as JSON is logged, not fatal: its Parquet
    /// sections are already stored, and a retry would fail the same way.
    /// </summary>
    private async Task<bool> WritePageModelAsync(ReportPageSnapshot page, string prefix, long snapshotRunId, ISnapshotStore store, string work, CancellationToken ct)
    {
        var local = Path.Combine(work, $"{Guid.NewGuid():N}.json.gz");
        try
        {
            try
            {
                await page.WriteAsync(local, ct);
            }
            catch (Exception ex) when (ex is NotSupportedException or System.Text.Json.JsonException or InvalidOperationException)
            {
                _logger.LogError(ex, "Report snapshot {Lab} {Code} {RunId}: the page model ({Type}) could not be written as JSON, so this week has no display copy. Its Parquet sections are stored.",
                    page.LabKey, page.ReportCode, page.RunId, page.ModelType);
                return false;
            }

            var (sha, size) = await HashAsync(local, ct);
            var path = $"{prefix}{page.ReportCode}_{ReportPageSnapshot.ResultSetName}.json.gz";
            await store.UploadAsync(local, path, sha, ct, SnapshotContentTypes.GzipJson);
            await _repository.AddFileAsync(snapshotRunId,
                new SnapshotFileInfo(page.ReportCode, ReportPageSnapshot.ResultSetName, path, 1, size, sha, page.IndexJson(),
                    ReportPageSnapshot.CurrentFormatVersion), ct);
            return true;
        }
        finally
        {
            try { File.Delete(local); } catch { /* temp file */ }
        }
    }

    private static async Task<(string Sha256, long Size)> HashAsync(string path, CancellationToken ct)
    {
        string sha;
        await using (var fs = File.OpenRead(path))
            sha = Convert.ToHexString(await SHA256.HashDataAsync(fs, ct)).ToLowerInvariant();
        return (sha, new FileInfo(path).Length);
    }

    /// <summary>
    /// The same retention as the master file processor (MasterDataSnapshot:KeepWeeks / KeepMonthEnd), so
    /// a lab with report snapshots but no master data snapshot is still pruned. Files first, then rows.
    /// </summary>
    private async Task ApplyRetentionAsync(int labId, CancellationToken ct)
    {
        try
        {
            var runs = await _repository.ListRunsAsync(labId, ct);
            var expired = SnapshotRetention.SelectExpired(runs, _storage.KeepWeeks, _storage.KeepMonthEnd, currentSnapshotRunId: 0, DateTime.UtcNow);
            var expiredIds = expired.Select(r => r.SnapshotRunId).ToHashSet();
            var keptWeeks = runs.Where(r => !expiredIds.Contains(r.SnapshotRunId))
                .Select(r => r.WeekFolder.Trim()).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var run in expired)
            {
                // Replaced by a re-run of the same week: its uploaded snapshots (Denial Insight) are requested
                // again for the new run before they go, as the master file processor does.
                if (keptWeeks.Contains(run.WeekFolder.Trim()))
                    await _repository.RequestRecaptureOfUploadedReportsAsync(run.SnapshotRunId, labId,
                        $"Re-run of {run.WeekFolder.Trim()}: replaces run {run.RunId}", ct);

                if (!string.IsNullOrWhiteSpace(run.BlobPrefix))
                    await _storeFactory.Store.DeletePrefixAsync(run.BlobPrefix!, ct);
                await _repository.DeleteRunAsync(run.SnapshotRunId, ct);
                _logger.LogInformation("Report snapshot retention: lab {LabId} run {RunId} ({Week}) deleted.", labId, run.RunId, run.WeekFolder);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Report snapshot retention failed for lab {LabId}; it is retried after the next capture.", labId);
        }
    }

    /// <summary>A section name as one path segment: letters, digits, '.', '-' and '_' only, at most 100 characters.</summary>
    internal static string SafeName(string name)
    {
        var safe = UnsafeChars().Replace(name, "_").Trim('_', '.');
        if (safe.Length == 0) safe = "Section";
        return safe.Length > 100 ? safe[..100] : safe;
    }

    private static string UniqueName(string name, HashSet<string> used)
    {
        var candidate = name;
        for (int i = 2; !used.Add(candidate); i++)
            candidate = $"{(name.Length > 96 ? name[..96] : name)}_{i}";
        return candidate;
    }

    [GeneratedRegex(@"[^A-Za-z0-9._-]+")]
    private static partial Regex UnsafeChars();
}
