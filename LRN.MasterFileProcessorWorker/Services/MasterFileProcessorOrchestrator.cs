using Common.Logging;
using Common.Logging.ProcessLogging;
using LRN.DataLibrary.Abstractions;
using LRN.DataLibrary.Entities;
using LRN.MasterFileProcessorWorker.IO;
using LRN.MasterFileProcessorWorker.Options;
using LRN.MasterFileProcessorWorker.Processing;
using LRN.MasterFileProcessorWorker.Schema;
using LRN.SharePointClient.Abstractions;
using LRN.SharePointClient.Models;
using LRN.SharePointUploader;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.Services;

public sealed class MasterFileProcessorOrchestrator
{
    private readonly ILoggerService _log;
    private readonly IReadOnlyList<LabOptions> _labs;
    private readonly MasterFileProcessorOptions _opts;

    private readonly ILrnLogRepository _repo;
    private readonly ProcessLogService _processLog;

    private readonly ISharePointClient _sp;
    private readonly SharePointUploadService _uploader;
    private readonly SharePointMasterFileFinder _finder;
    private readonly MasterFileSplitter _splitter;

    public MasterFileProcessorOrchestrator(
        ILoggerService log,
        List<LabOptions> labs,
        IOptions<MasterFileProcessorOptions> opts,
        ILrnLogRepository repo,
        ProcessLogService processLog,
        ISharePointClient sp,
        SharePointUploadService uploader,
        SharePointMasterFileFinder finder,
        MasterFileSplitter splitter)
    {
        _log = log;
        _labs = labs;
        _opts = opts.Value;
        _repo = repo;
        _processLog = processLog;
        _sp = sp;
        _uploader = uploader;
        _finder = finder;
        _splitter = splitter;
    }

    public async Task ProcessAllLabsOnceAsync(CancellationToken ct)
    {
        if (_labs.Count == 0)
        {
            _log.Warn("No labs configured under 'Labs' in appsettings.json.");
            return;
        }

        foreach (var lab in _labs)
        {
            ct.ThrowIfCancellationRequested();

            try
            {
                await ProcessLabOnceAsync(lab, ct);
            }
            catch (Exception ex)
            {
                _log.Error($"Lab processing failed (Lab={lab.LabName}).", ex);
            }
        }
    }

    private async Task ProcessLabOnceAsync(LabOptions lab, CancellationToken ct)
    {
        // 1) Discover latest master file
        var discovery = await _finder.FindLatestAsync(lab.Input, ct);
        if (discovery == null)
        {
            _log.Info($"[{lab.LabName}] No master files found in SharePoint input location.");
            return;
        }

        var lastRun = await _repo.GetLatestRunAsync(lab.LabId, ct);
        if (lastRun?.InputMasterFileName != null && lastRun.InputMasterFileModifiedTime.HasValue)
        {
            var sameFile = string.Equals(lastRun.InputMasterFileName, discovery.File.Name, StringComparison.OrdinalIgnoreCase);
            var notNewer = discovery.File.LastModifiedUtc <= lastRun.InputMasterFileModifiedTime.Value;
            if (sameFile && notNewer)
            {
                _log.Info($"[{lab.LabName}] No new master file. Latest in SP: {discovery.File.Name} ({discovery.File.LastModifiedUtc:O})");
                return;
            }
        }

        // 2) Start run
        var workRoot = Path.IsPathRooted(_opts.WorkRoot)
            ? _opts.WorkRoot
            : Path.Combine(AppContext.BaseDirectory, _opts.WorkRoot);

        Directory.CreateDirectory(workRoot);

        var (runCtx, run) = await _processLog.StartRunAsync(lab.LabId, lab.LabName, workRoot, _opts.SourceSystem, ct);

        // Run metadata
        run.LatestMasterFileFound = true;
        run.InputMasterSharePointPath = discovery.EffectiveFolderPath;
        run.InputMasterFileName = discovery.File.Name;
        run.InputMasterFileModifiedTime = discovery.File.LastModifiedUtc;
        await _repo.UpdateRunAsync(run, ct);

        // 3) Load schema
        var schemaPath = Path.Combine(Path.IsPathRooted(_opts.SchemasRoot) ? _opts.SchemasRoot : Path.Combine(AppContext.BaseDirectory, _opts.SchemasRoot), lab.SchemaFile);
        var schema = SchemaLoader.LoadFromFile(schemaPath);

        // 4) Step: Download
        var stepDownload = await _processLog.StartStepAsync(runCtx, lab.LabName, run.RunID, 20, "DownloadLatestMasterFile", "SharePoint", _opts.SourceSystem,
            fileIn: discovery.File.Name, pathIn: discovery.EffectiveFolderPath, recordsIn: null, ct: ct);

        var localMasterPath = Path.Combine(runCtx.WorkDir, discovery.File.Name);
        try
        {
            await _sp.DownloadFileAsync(lab.Input, discovery.File.Id, localMasterPath, ct);
            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepDownload, _opts.SourceSystem, LrnStatuses.Success,
                recordsOut: null, fileOut: discovery.File.Name, pathOut: localMasterPath, errorCode: null, errorMessage: null, errorDetail: null, ct: ct);
        }
        catch (Exception ex)
        {
            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepDownload, _opts.SourceSystem, LrnStatuses.Failed,
                recordsOut: null, fileOut: null, pathOut: null, errorCode: "SP_DOWNLOAD", errorMessage: ex.Message, errorDetail: ex.ToString(), ct: ct);

            run.TotalErrors += 1;
            await _processLog.LogErrorAsync(runCtx, new LrnErrorLog
            {
                RunID = run.RunID,
                LabName = lab.LabName,
                ErrorTimeIST = ToIst(DateTimeOffset.UtcNow),
                Severity = "Error",
                StepName = stepDownload.StepName,
                ErrorCode = "SP_DOWNLOAD",
                ErrorSummary = "Failed to download latest master file from SharePoint.",
                FileName = discovery.File.Name,
                FilePath = discovery.EffectiveFolderPath,
                RecommendedAction = "Check SharePoint permissions / connectivity, then retry.",
                SourceSystem = _opts.SourceSystem,
                Status = "Open"
            }, ct);

            await FailAndUploadLogsAsync(lab, runCtx, run, "SharePoint download failed", ct);
            return;
        }

        // 5) Step: Split
        var stepSplit = await _processLog.StartStepAsync(runCtx, lab.LabName, run.RunID, 30, "SplitToLineAndClaim", "Transform", _opts.SourceSystem,
            fileIn: discovery.File.Name, pathIn: localMasterPath, recordsIn: null, ct: ct);

        TabularData line;
        TabularData claim;

        try
        {
            (line, claim) = await _splitter.SplitAsync(localMasterPath, schema, ct);

            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepSplit, _opts.SourceSystem, LrnStatuses.Success,
                recordsOut: line.Rows.Count, fileOut: null, pathOut: null, errorCode: null, errorMessage: null, errorDetail: null, ct: ct);
        }
        catch (Exception ex)
        {
            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepSplit, _opts.SourceSystem, LrnStatuses.Failed,
                recordsOut: null, fileOut: null, pathOut: null, errorCode: "SPLIT_FAIL", errorMessage: ex.Message, errorDetail: ex.ToString(), ct: ct);

            run.TotalErrors += 1;
            await _processLog.LogErrorAsync(runCtx, new LrnErrorLog
            {
                RunID = run.RunID,
                LabName = lab.LabName,
                ErrorTimeIST = ToIst(DateTimeOffset.UtcNow),
                Severity = "Error",
                StepName = stepSplit.StepName,
                ErrorCode = "SPLIT_FAIL",
                ErrorSummary = "Failed to split master file into line/claim level data.",
                FileName = discovery.File.Name,
                FilePath = localMasterPath,
                RecommendedAction = "Check file format, sheet names, and schema input settings.",
                SourceSystem = _opts.SourceSystem,
                Status = "Open"
            }, ct);

            await FailAndUploadLogsAsync(lab, runCtx, run, "Split failed", ct);
            return;
        }

        // 6) Step: Mandatory column validation
        var stepValidate = await _processLog.StartStepAsync(runCtx, lab.LabName, run.RunID, 40, "ValidateMandatoryColumns", "Validate", _opts.SourceSystem,
            fileIn: discovery.File.Name, pathIn: localMasterPath, recordsIn: line.Rows.Count, ct: ct);

        var missingLine = ColumnValidator.FindMissingMandatoryColumns(line.Columns, schema.LineLevel.MandatoryColumns);
        var missingClaim = ColumnValidator.FindMissingMandatoryColumns(claim.Columns, schema.ClaimLevel.MandatoryColumns);

        if (missingLine.Count > 0 || missingClaim.Count > 0)
        {
            run.MandatoryColumnCheck = LrnStatuses.Failed;
            run.TotalErrors += 1;
            await _repo.UpdateRunAsync(run, ct);

            var missingText = string.Join(" | ", new[]
            {
                missingLine.Count > 0 ? $"LineMissing=[{string.Join(",", missingLine)}]" : null,
                missingClaim.Count > 0 ? $"ClaimMissing=[{string.Join(",", missingClaim)}]" : null
            }.Where(x => x != null)!);

            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepValidate, _opts.SourceSystem, LrnStatuses.Failed,
                recordsOut: null, fileOut: null, pathOut: null, errorCode: "MANDATORY_MISSING", errorMessage: missingText, errorDetail: missingText, ct: ct);

            await _processLog.LogErrorAsync(runCtx, new LrnErrorLog
            {
                RunID = run.RunID,
                LabName = lab.LabName,
                ErrorTimeIST = ToIst(DateTimeOffset.UtcNow),
                Severity = "Error",
                StepName = stepValidate.StepName,
                ErrorCode = "MANDATORY_MISSING",
                ErrorSummary = "Mandatory column validation failed.",
                MissingColumns = missingText,
                SheetName = schema.Input.LineLevelSheetName,
                FileName = discovery.File.Name,
                FilePath = localMasterPath,
                RecommendedAction = "Update the lab schema JSON or fix the incoming master file headers.",
                SourceSystem = _opts.SourceSystem,
                Status = "Open"
            }, ct);

            await FailAndUploadLogsAsync(lab, runCtx, run, "Mandatory columns missing", ct);
            return;
        }

        run.MandatoryColumnCheck = LrnStatuses.Success;
        await _repo.UpdateRunAsync(run, ct);

        await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepValidate, _opts.SourceSystem, LrnStatuses.Success,
            recordsOut: line.Rows.Count, fileOut: null, pathOut: null, errorCode: null, errorMessage: null, errorDetail: null, ct: ct);

        // 7) Step: Write common outputs
        var stepWrite = await _processLog.StartStepAsync(runCtx, lab.LabName, run.RunID, 50, "WriteCommonOutputs", "Output", _opts.SourceSystem,
            fileIn: discovery.File.Name, pathIn: localMasterPath, recordsIn: line.Rows.Count, ct: ct);

        var lineOutRows = OutputMapper.MapRows(line.Rows, schema.LineLevel.CommonOutputMappings);
        var claimOutRows = OutputMapper.MapRows(claim.Rows, schema.ClaimLevel.CommonOutputMappings);
        // Inject RunID into outputs (common requirement for downstream projects).
        var runIdText = run.RunID.ToString();
        foreach (var r in lineOutRows) r["RunID"] = runIdText;
        foreach (var r in claimOutRows) r["RunID"] = runIdText;


        var lineOutName = $"{lab.LabName}_LineLevel_{run.RunID}.csv";
        var claimOutName = $"{lab.LabName}_ClaimLevel_{run.RunID}.csv";

        var lineOutPath = Path.Combine(runCtx.WorkDir, lineOutName);
        var claimOutPath = Path.Combine(runCtx.WorkDir, claimOutName);

        try
        {
            await CsvUtils.WriteAsync(lineOutPath, schema.LineLevel.CommonOutputMappings.Select(m => m.Target).ToList(), lineOutRows, ct);
            await CsvUtils.WriteAsync(claimOutPath, schema.ClaimLevel.CommonOutputMappings.Select(m => m.Target).ToList(), claimOutRows, ct);

            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepWrite, _opts.SourceSystem, LrnStatuses.Success,
                recordsOut: lineOutRows.Count + claimOutRows.Count, fileOut: $"{claimOutName} | {lineOutName}", pathOut: runCtx.WorkDir,
                errorCode: null, errorMessage: null, errorDetail: null, ct: ct);
        }
        catch (Exception ex)
        {
            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepWrite, _opts.SourceSystem, LrnStatuses.Failed,
                recordsOut: null, fileOut: null, pathOut: null, errorCode: "WRITE_FAIL", errorMessage: ex.Message, errorDetail: ex.ToString(), ct: ct);

            run.TotalErrors += 1;
            await _repo.UpdateRunAsync(run, ct);

            await _processLog.LogErrorAsync(runCtx, new LrnErrorLog
            {
                RunID = run.RunID,
                LabName = lab.LabName,
                ErrorTimeIST = ToIst(DateTimeOffset.UtcNow),
                Severity = "Error",
                StepName = stepWrite.StepName,
                ErrorCode = "WRITE_FAIL",
                ErrorSummary = "Failed to write common outputs.",
                FileName = discovery.File.Name,
                FilePath = localMasterPath,
                RecommendedAction = "Check disk permissions and schema mappings.",
                SourceSystem = _opts.SourceSystem,
                Status = "Open"
            }, ct);

            await FailAndUploadLogsAsync(lab, runCtx, run, "Output write failed", ct);
            return;
        }

        // 8) Step: Upload outputs
        var stepUpload = await _processLog.StartStepAsync(runCtx, lab.LabName, run.RunID, 60, "UploadOutputsToSharePoint", "SharePoint", _opts.SourceSystem,
            fileIn: $"{claimOutName} | {lineOutName}", pathIn: runCtx.WorkDir, recordsIn: lineOutRows.Count + claimOutRows.Count, ct: ct);

        try
        {
            await _uploader.UploadAsync(lab.Output, lineOutPath, lineOutName, ct);
            await _uploader.UploadAsync(lab.Output, claimOutPath, claimOutName, ct);

            run.SplitOutputWrittenToSharePoint = LrnStatuses.Success;
            await _repo.UpdateRunAsync(run, ct);

            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepUpload, _opts.SourceSystem, LrnStatuses.Success,
                recordsOut: null, fileOut: $"{claimOutName} | {lineOutName}", pathOut: lab.Output.FolderPath, errorCode: null, errorMessage: null, errorDetail: null, ct: ct);
        }
        catch (Exception ex)
        {
            run.SplitOutputWrittenToSharePoint = LrnStatuses.Failed;
            run.TotalErrors += 1;
            await _repo.UpdateRunAsync(run, ct);

            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, stepUpload, _opts.SourceSystem, LrnStatuses.Failed,
                recordsOut: null, fileOut: null, pathOut: null, errorCode: "SP_UPLOAD", errorMessage: ex.Message, errorDetail: ex.ToString(), ct: ct);

            await _processLog.LogErrorAsync(runCtx, new LrnErrorLog
            {
                RunID = run.RunID,
                LabName = lab.LabName,
                ErrorTimeIST = ToIst(DateTimeOffset.UtcNow),
                Severity = "Error",
                StepName = stepUpload.StepName,
                ErrorCode = "SP_UPLOAD",
                ErrorSummary = "Failed to upload outputs to SharePoint.",
                FileName = $"{claimOutName} | {lineOutName}",
                FilePath = lab.Output.FolderPath,
                RecommendedAction = "Check SharePoint permissions / output folder path.",
                SourceSystem = _opts.SourceSystem,
                Status = "Open"
            }, ct);

            await FailAndUploadLogsAsync(lab, runCtx, run, "SharePoint upload failed", ct);
            return;
        }

        // 9) Upload logs (run + step + error)
        await UploadLogsAsync(lab, runCtx, run, ct);

        // 10) Complete run
        await _processLog.CompleteRunAsync(runCtx, run, LrnStatuses.Success, notes: null, ct);
        await _uploader.UploadAsync(lab.Logs, runCtx.RunSummaryCsvPath, Path.GetFileName(runCtx.RunSummaryCsvPath), ct);
    }

    private async Task FailAndUploadLogsAsync(LabOptions lab, RunContext runCtx, LrnRunLog run, string notes, CancellationToken ct)
    {
        await UploadLogsAsync(lab, runCtx, run, ct);
        await _processLog.CompleteRunAsync(runCtx, run, LrnStatuses.Failed, notes, ct);
        await _uploader.UploadAsync(lab.Logs, runCtx.RunSummaryCsvPath, Path.GetFileName(runCtx.RunSummaryCsvPath), ct);
    }

    private async Task UploadLogsAsync(LabOptions lab, RunContext runCtx, LrnRunLog run, CancellationToken ct)
    {
        var step = await _processLog.StartStepAsync(runCtx, lab.LabName, run.RunID, 70, "UploadProcessLogs", "SharePoint", _opts.SourceSystem,
            fileIn: Path.GetFileName(runCtx.StepLogCsvPath), pathIn: runCtx.WorkDir, recordsIn: null, ct: ct);

        try
        {
            await _uploader.UploadAsync(lab.Logs, runCtx.RunSummaryCsvPath, Path.GetFileName(runCtx.RunSummaryCsvPath), ct);
            await _uploader.UploadAsync(lab.Logs, runCtx.StepLogCsvPath, Path.GetFileName(runCtx.StepLogCsvPath), ct);
            await _uploader.UploadAsync(lab.Logs, runCtx.ErrorLogCsvPath, Path.GetFileName(runCtx.ErrorLogCsvPath), ct);

            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, step, _opts.SourceSystem, LrnStatuses.Success,
                recordsOut: null, fileOut: "Run/Step/Error log CSVs", pathOut: lab.Logs.FolderPath, errorCode: null, errorMessage: null, errorDetail: null, ct: ct);
        }
        catch (Exception ex)
        {
            await _processLog.CompleteStepAsync(runCtx, run.RunID, lab.LabName, step, _opts.SourceSystem, LrnStatuses.Failed,
                recordsOut: null, fileOut: null, pathOut: null, errorCode: "SP_LOG_UPLOAD", errorMessage: ex.Message, errorDetail: ex.ToString(), ct: ct);

            // Don't throw; run can still be considered failed/success based on earlier steps.
        }
    }

    private static DateTimeOffset ToIst(DateTimeOffset utc)
        => utc.ToOffset(TimeSpan.FromHours(5.5));
}
