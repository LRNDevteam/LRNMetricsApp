using System.Diagnostics;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>Everything the import needs about the file being loaded, from the worker's run context.</summary>
/// <param name="SourceFullPath">Where the data came from: a SharePoint path, or the upstream
/// RunID and table for a lab sourced from its own database.</param>
/// <param name="LineLevelSource">
/// What to call the line-level input in the logs, when it differs from <paramref name="SourceFileName"/>.
/// A lab can take one level from its tables and the other from the workbook, so the two levels carry
/// their own labels rather than sharing the run's one. Null falls back to <paramref name="SourceFileName"/>.
/// </param>
/// <param name="ClaimLevelSource">The same, for claim level.</param>
public sealed record LineClaimImportRequest(
    string RunId,
    string? WeekFolder,
    string? SourceFullPath,
    string? SourceFileName,
    DateTime? FileCreatedDateTime,
    string LineLevelCsvPath,
    string ClaimLevelCsvPath,
    string? LineLevelSource = null,
    string? ClaimLevelSource = null)
{
    /// <summary>
    /// This level's own source label, or null when the level has none and the run's file name and
    /// path apply. Null rather than a fallback because the two callers fall back differently: one
    /// wants the file NAME, the other the full PATH, and collapsing them here would quietly replace
    /// a SharePoint path with a bare file name for every lab that is not database-sourced.
    /// </summary>
    public string? SourceOverrideFor(string fileType)
    {
        var perLevel = string.Equals(fileType, FileTypes.LineLevel, StringComparison.OrdinalIgnoreCase)
            ? LineLevelSource
            : string.Equals(fileType, FileTypes.ClaimLevel, StringComparison.OrdinalIgnoreCase)
                ? ClaimLevelSource
                : null;

        return string.IsNullOrWhiteSpace(perLevel) ? null : perLevel;
    }
}

public sealed record LineClaimImportOutcome(string FileType, bool Succeeded, bool Skipped, long RowsCopied, string? Message);

/// <summary>
/// Per-lab, per-level import: file log -> bulk load -> verify -> run info log -> workflow tracker.
/// <para>
/// One lab's failure never aborts another: <see cref="ImportAllLabsAsync"/> isolates each lab, and
/// within a lab each level is isolated too. Failures are logged everywhere and the loop continues.
/// </para>
/// <para>
/// This service is purely additive. It does not touch LRN_Run_Log / LRN_Step_Log / LRN_Error_Log,
/// which the worker keeps writing exactly as before.
/// </para>
/// </summary>
public sealed class LineClaimImportService
{
    private readonly LineClaimBulkLoader _loader;
    private readonly LineClaimFileLogRepository _fileLog;
    private readonly ReportRunIdInfoLogger _runInfo;
    private readonly ReportsWorkflowTrackerRepository _tracker;
    private readonly LineClaimImportOptions _options;
    private readonly ILogger<LineClaimImportService> _logger;

    public LineClaimImportService(
        LineClaimBulkLoader loader,
        LineClaimFileLogRepository fileLog,
        ReportRunIdInfoLogger runInfo,
        ReportsWorkflowTrackerRepository tracker,
        IOptions<LineClaimImportOptions> options,
        ILogger<LineClaimImportService> logger)
    {
        _loader = loader;
        _fileLog = fileLog;
        _runInfo = runInfo;
        _tracker = tracker;
        _options = options.Value ?? new LineClaimImportOptions();
        _logger = logger;
    }

    /// <summary>Imports both levels for every resolved lab. Never throws for a single lab's failure.</summary>
    public async Task<IReadOnlyList<LineClaimImportOutcome>> ImportAllLabsAsync(
        IReadOnlyList<ResolvedLab> labs,
        Func<ResolvedLab, LineClaimImportRequest?> requestFactory,
        CancellationToken ct)
    {
        var outcomes = new List<LineClaimImportOutcome>();

        foreach (var lab in labs)
        {
            ct.ThrowIfCancellationRequested();

            LineClaimImportRequest? request;

            try
            {
                request = requestFactory(lab);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Lab {LabId}: could not build the import request. Skipping this lab.", lab.LabId);
                continue;
            }

            if (request is null)
                continue;

            outcomes.AddRange(await ImportLabAsync(lab, request, ct).ConfigureAwait(false));
        }

        return outcomes;
    }

    public async Task<IReadOnlyList<LineClaimImportOutcome>> ImportLabAsync(
        ResolvedLab lab,
        LineClaimImportRequest request,
        CancellationToken ct)
    {
        var results = new List<LineClaimImportOutcome>(2);

        results.Add(await ImportLevelAsync(lab, request, FileTypes.LineLevel, lab.Mapping.LineLevel,
            request.LineLevelCsvPath, WorkflowReportNames.LineLevelMaster, ct).ConfigureAwait(false));

        results.Add(await ImportLevelAsync(lab, request, FileTypes.ClaimLevel, lab.Mapping.ClaimLevel,
            request.ClaimLevelCsvPath, WorkflowReportNames.ClaimLevelMaster, ct).ConfigureAwait(false));

        await MarkDerivedReportsAsync(lab, request, results, ct).ConfigureAwait(false);

        return results;
    }

    /// <summary>How derived rows label themselves in the log and tracker.</summary>
    private const string DerivedReportType = "Derived";

    /// <summary>
    /// Marks the reports that are built FROM the line-level and claim-level data - Clinic Summary,
    /// Sales Rep Summary - as Success once both of those have loaded, against the same RunId.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Both levels must have genuinely loaded. A skipped level reports Succeeded = true (a skip is
    /// not a failure of the run), so "no exception" is not the test - <c>Skipped</c> has to be
    /// checked as well, or a lab with the load switched off would show a green Clinic Summary built
    /// on data that never arrived.
    /// </para>
    /// <para>
    /// Nothing is written when the base did not load. The absence is logged instead, because
    /// inventing a Failed row here would blame these reports for something that happened upstream.
    /// </para>
    /// <para>
    /// RowCount is deliberately left NULL. These rows are an assertion that the source data is in
    /// place, not a count of anything this worker produced.
    /// </para>
    /// </remarks>
    private async Task MarkDerivedReportsAsync(
        ResolvedLab lab,
        LineClaimImportRequest request,
        IReadOnlyList<LineClaimImportOutcome> results,
        CancellationToken ct)
    {
        var configured = _options.DerivedReports
            .Where(d => d.Enabled && !string.IsNullOrWhiteSpace(d.ReportName))
            .ToList();

        if (configured.Count == 0)
            return;

        var notLoaded = results.Where(r => !r.Succeeded || r.Skipped).Select(r => r.FileType).ToList();

        if (notLoaded.Count > 0)
        {
            var reason = $"Derived reports not marked for lab {lab.LabName} ({lab.LabId}): "
                       + $"{string.Join(" and ", notLoaded)} did not load.";

            _logger.LogInformation("Lab {LabId}: {Reason}", lab.LabId, reason);
            await _runInfo.InfoAsync(request.RunId, DerivedReportType, lab.LabName, reason, ct)
                          .ConfigureAwait(false);
            return;
        }

        var completedOn = ReportRunIdInfoLogger.IstNow();

        foreach (var derived in configured)
        {
            if (!derived.AppliesTo(lab.LabId))
            {
                _logger.LogDebug("Lab {LabId}: '{Report}' is not produced by this lab.", lab.LabId, derived.ReportName);
                continue;
            }

            try
            {
                await _tracker.UpsertAsync(request.RunId, lab.LabId, lab.LabName, request.WeekFolder,
                    derived.ReportName, DerivedReportType, WorkflowStatus.Success, null, null,
                    completedOn, "Derived from Line Level Master and Claim Level Master.", ct)
                    .ConfigureAwait(false);

                _logger.LogInformation("Lab {LabId}: '{Report}' marked Success for run {RunId}.",
                    lab.LabId, derived.ReportName, request.RunId);
            }
            catch (Exception ex)
            {
                // A dashboard row is never worth failing a completed load over. The data is already
                // committed at this point; losing the marker is a reporting gap, not a data problem.
                _logger.LogWarning(ex, "Lab {LabId}: could not mark '{Report}'.", lab.LabId, derived.ReportName);

                await _runInfo.WarningAsync(request.RunId, DerivedReportType, lab.LabName,
                    $"Could not mark '{derived.ReportName}' for lab {lab.LabName}: {ex.Message}", ct)
                    .ConfigureAwait(false);
            }
        }
    }

    private async Task<LineClaimImportOutcome> ImportLevelAsync(
        ResolvedLab lab,
        LineClaimImportRequest request,
        string fileType,
        LevelMapping? level,
        string csvPath,
        string reportName,
        CancellationToken ct)
    {
        var startedOn = ReportRunIdInfoLogger.IstNow();
        var sourceSystem = lab.LabName;
        var stopwatch = Stopwatch.StartNew();

        // Where this level's rows actually originated. Null for a workbook-sourced lab, in which
        // case every log below keeps the values it has always carried.
        var sourceOverride = request.SourceOverrideFor(fileType);

        // ReportRunIdInfoLog.SourceFileName has always held the standardized CSV that was copied in.
        // For a database-sourced level that CSV is an intermediate this worker wrote seconds earlier,
        // so it names nothing a reader can trace back; the upstream RunID and table do.
        var logSourceName = sourceOverride ?? Path.GetFileName(csvPath);

        // Same substitution for LineClaimFileLogs.SourceFullPath and the SourceFullPath stamped on
        // every loaded row.
        var sourceFullPath = sourceOverride ?? request.SourceFullPath;

        // ReportsWorkflowTracker has no source column - Remarks is the only field that can carry it.
        var sourceRemark = sourceOverride is null ? null : $"Source: {sourceOverride}";

        static string? WithSource(string? remark, string? sourceRemark) =>
            string.IsNullOrWhiteSpace(sourceRemark) ? remark
            : string.IsNullOrWhiteSpace(remark) ? sourceRemark
            : $"{remark} {sourceRemark}";

        // ---- skip paths. Every one is logged; none is silent. ----
        var skipReason = ResolveSkipReason(level);

        if (skipReason is not null)
        {
            _logger.LogInformation("Lab {LabId} [{FileType}]: skipped - {Reason}", lab.LabId, fileType, skipReason);

            await _runInfo.InfoAsync(request.RunId, fileType, sourceSystem,
                $"{fileType} skipped for lab {lab.LabName} ({lab.LabId}): {skipReason}", ct, logSourceName).ConfigureAwait(false);

            await _tracker.UpsertAsync(request.RunId, lab.LabId, lab.LabName, request.WeekFolder,
                reportName, fileType, WorkflowStatus.Skipped, null, startedOn,
                ReportRunIdInfoLogger.IstNow(), WithSource(skipReason, sourceRemark), ct).ConfigureAwait(false);

            return new LineClaimImportOutcome(fileType, Succeeded: true, Skipped: true, 0, skipReason);
        }

        long fileLogId = 0;

        try
        {
            await _runInfo.StartAsync(request.RunId, fileType, sourceSystem,
                $"{fileType} bulk copy started for lab {lab.LabName} ({lab.LabId}). Source: {sourceOverride ?? request.SourceFileName}", ct, logSourceName)
                .ConfigureAwait(false);

            await _tracker.UpsertAsync(request.RunId, lab.LabId, lab.LabName, request.WeekFolder,
                reportName, fileType, WorkflowStatus.InProgress, null, startedOn, null, sourceRemark, ct).ConfigureAwait(false);

            // 1. file log row -> FileLogId, which is stamped onto every data row.
            fileLogId = await _fileLog.InsertAsync(
                lab.ConnectionString, request.RunId, request.WeekFolder, lab.LabName,
                sourceFullPath, Path.GetFileName(csvPath), fileType,
                request.FileCreatedDateTime, ct).ConfigureAwait(false);

            await _runInfo.InfoAsync(request.RunId, fileType, sourceSystem,
                $"LineClaimFileLogs row {fileLogId} created. Truncate + load into {level!.SqlTableName} starting.", ct, logSourceName)
                .ConfigureAwait(false);

            var audit = new AuditColumns.AuditValues(
                FileLogId: fileLogId,
                RunId: request.RunId,
                WeekFolder: request.WeekFolder,
                SourceFullPath: sourceFullPath,
                FileName: Path.GetFileName(csvPath),
                FileType: fileType,
                LabId: lab.LabId,
                LabName: lab.LabName);

            // 2. stage -> verify -> swap -> verify
            var result = await _loader.LoadAsync(lab, level!, fileType, csvPath, audit, ct).ConfigureAwait(false);

            stopwatch.Stop();

            if (result.Skipped)
            {
                await _fileLog.TryCompleteAsync(lab.ConnectionString, fileLogId,
                    WorkflowStatus.Skipped, 0, result.SkipReason, ct).ConfigureAwait(false);

                await _runInfo.WarningAsync(request.RunId, fileType, sourceSystem,
                    $"{fileType} produced no load: {result.SkipReason}", ct, logSourceName).ConfigureAwait(false);

                await _tracker.UpsertAsync(request.RunId, lab.LabId, lab.LabName, request.WeekFolder,
                    reportName, fileType, WorkflowStatus.Skipped, 0, startedOn,
                    ReportRunIdInfoLogger.IstNow(), WithSource(result.SkipReason, sourceRemark), ct).ConfigureAwait(false);

                return new LineClaimImportOutcome(fileType, true, true, 0, result.SkipReason);
            }

            await _fileLog.TryCompleteAsync(lab.ConnectionString, fileLogId,
                WorkflowStatus.Success, result.RowsInTable, null, ct).ConfigureAwait(false);

            await _runInfo.InfoAsync(request.RunId, fileType, sourceSystem,
                $"{fileType} bulk copy completed. Rows={result.RowsInTable}, Table={level!.SqlTableName}, Duration={stopwatch.ElapsedMilliseconds} ms.", ct, logSourceName)
                .ConfigureAwait(false);

            if (result.MissingCsvHeaders.Count > 0 || result.UnmappedCsvHeaders.Count > 0)
            {
                await _runInfo.WarningAsync(request.RunId, fileType, sourceSystem,
                    $"Mapping gaps. Mapped-but-absent-in-CSV: [{string.Join("; ", result.MissingCsvHeaders)}]. " +
                    $"In-CSV-but-unmapped: [{string.Join("; ", result.UnmappedCsvHeaders)}].", ct, logSourceName).ConfigureAwait(false);
            }

            await _tracker.UpsertAsync(request.RunId, lab.LabId, lab.LabName, request.WeekFolder,
                reportName, fileType, WorkflowStatus.Success, result.RowsInTable, startedOn,
                ReportRunIdInfoLogger.IstNow(), sourceRemark, ct).ConfigureAwait(false);

            await _runInfo.EndAsync(request.RunId, fileType, sourceSystem,
                $"{fileType} processing ended for lab {lab.LabName} ({lab.LabId}).", ct, logSourceName).ConfigureAwait(false);

            return new LineClaimImportOutcome(fileType, true, false, result.RowsInTable, null);
        }
        catch (Exception ex)
        {
            stopwatch.Stop();
            _logger.LogError(ex, "Lab {LabId} [{FileType}]: bulk copy failed.", lab.LabId, fileType);

            if (fileLogId > 0)
            {
                await _fileLog.TryCompleteAsync(lab.ConnectionString, fileLogId,
                    WorkflowStatus.Failed, null, ex.Message, ct).ConfigureAwait(false);
            }

            await _runInfo.ErrorAsync(request.RunId, fileType, sourceSystem, ex, ct, logSourceName).ConfigureAwait(false);

            await _tracker.UpsertAsync(request.RunId, lab.LabId, lab.LabName, request.WeekFolder,
                reportName, fileType, WorkflowStatus.Failed, null, startedOn,
                ReportRunIdInfoLogger.IstNow(), WithSource(ex.Message, sourceRemark), ct).ConfigureAwait(false);

            await _runInfo.EndAsync(request.RunId, fileType, sourceSystem,
                $"{fileType} processing ended with failure for lab {lab.LabName} ({lab.LabId}).", ct, logSourceName).ConfigureAwait(false);

            return new LineClaimImportOutcome(fileType, false, false, 0, ex.Message);
        }
    }

    /// <summary>
    /// Why this level would not be loaded, or null to load it.
    /// <para>
    /// Deliberately does NOT consider CreateCsv. Whether the standardized CSV is published to the
    /// output folder is a separate concern from whether the rows reach SQL: the file is always
    /// produced in the staging folder, and the loader reads it from there when publishing is off.
    /// Only Enabled and BulkCopyToTable decide whether a load happens.
    /// </para>
    /// </summary>
    private static string? ResolveSkipReason(LevelMapping? level)
    {
        if (level is null) return "no mapping section for this level in the lab JSON";
        if (!level.Enabled) return "Enabled=false";
        if (!level.BulkCopyToTable) return "BulkCopyToTable=false";
        return null;
    }
}
