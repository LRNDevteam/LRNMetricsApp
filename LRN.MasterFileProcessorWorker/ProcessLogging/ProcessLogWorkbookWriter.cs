using LRN.MasterFileProcessorWorker.SharePoint;
using Microsoft.Extensions.Options;
using System;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public interface IProcessLogWorkbookWriter
{
    Task UpsertRunAsync(DateTime nowIst, RunLogRow row, CancellationToken ct);
    Task UpsertStepAsync(DateTime nowIst, StepLogRow row, CancellationToken ct);
    Task AppendErrorAsync(DateTime nowIst, ErrorLogRow row, CancellationToken ct);
    Task IncrementRunCountAsync(DateTime nowIst, string runId, bool isWarning, CancellationToken ct);
    Task UploadWorkbookAsync(DateTime nowIst, CancellationToken ct);
    ProcessLogWorkbookPaths GetPaths(DateTime nowIst);
}

public sealed class ProcessLogWorkbookPaths
{
    public string WorkbookPath { get; init; } = "";
    public string WorkbookFileName { get; init; } = "";
}

/// <summary>
/// Writes process logs to a single daily Excel workbook (3 sheets) and optionally uploads it to SharePoint.
/// </summary>
public sealed class ProcessLogWorkbookWriter : IProcessLogWorkbookWriter
{
    private readonly ProcessLogOptions _logOpt;
    private readonly ImportOptions _importOpt;
    private readonly SharePointDownloader _sp;

    private string? _cachedDriveId;

    public ProcessLogWorkbookWriter(IOptions<ProcessLogOptions> logOpt, IOptions<ImportOptions> importOpt, SharePointDownloader sp)
    {
        _logOpt = logOpt.Value ?? new ProcessLogOptions();
        _importOpt = importOpt.Value ?? new ImportOptions();
        _sp = sp;
    }

    public Task UpsertRunAsync(DateTime nowIst, RunLogRow row, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.WorkbookEnabled || string.IsNullOrWhiteSpace(row.RunID))
            return Task.CompletedTask;

        var folder = ResolveFolder(nowIst);
        _ = ProcessLogWorkbook.UpsertRun(folder, _logOpt.WorkbookFilePrefix, nowIst, row);

        if (ShouldUploadEachWrite())
            return SafeUploadAsync(nowIst, ct);

        return Task.CompletedTask;
    }

    public Task UpsertStepAsync(DateTime nowIst, StepLogRow row, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.WorkbookEnabled || string.IsNullOrWhiteSpace(row.RunID))
            return Task.CompletedTask;

        var folder = ResolveFolder(nowIst);
        _ = ProcessLogWorkbook.UpsertStep(folder, _logOpt.WorkbookFilePrefix, nowIst, row);

        if (ShouldUploadEachWrite())
            return SafeUploadAsync(nowIst, ct);

        return Task.CompletedTask;
    }

    public Task AppendErrorAsync(DateTime nowIst, ErrorLogRow row, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.WorkbookEnabled || string.IsNullOrWhiteSpace(row.RunID))
            return Task.CompletedTask;

        var folder = ResolveFolder(nowIst);
        _ = ProcessLogWorkbook.AppendError(folder, _logOpt.WorkbookFilePrefix, nowIst, row);

        if (ShouldUploadEachWrite())
            return SafeUploadAsync(nowIst, ct);

        return Task.CompletedTask;
    }

    public Task IncrementRunCountAsync(DateTime nowIst, string runId, bool isWarning, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.WorkbookEnabled || string.IsNullOrWhiteSpace(runId))
            return Task.CompletedTask;

        var folder = ResolveFolder(nowIst);
        ProcessLogWorkbook.IncrementRunCount(folder, _logOpt.WorkbookFilePrefix, nowIst, runId, isWarning);

        if (ShouldUploadEachWrite())
            return SafeUploadAsync(nowIst, ct);

        return Task.CompletedTask;
    }

    public Task UploadWorkbookAsync(DateTime nowIst, CancellationToken ct)
        => SafeUploadAsync(nowIst, ct);

    public ProcessLogWorkbookPaths GetPaths(DateTime nowIst)
    {
        var folder = ResolveFolder(nowIst);
        var path = ProcessLogWorkbook.GetWorkbookPath(folder, _logOpt.WorkbookFilePrefix, nowIst);
        return new ProcessLogWorkbookPaths
        {
            WorkbookPath = path,
            WorkbookFileName = Path.GetFileName(path)
        };
    }

    private bool ShouldUploadEachWrite()
        => string.Equals(_logOpt.WorkbookUploadMode, "EachWrite", StringComparison.OrdinalIgnoreCase);

    private string ResolveFolder(DateTime nowIst)
    {
        var folder = _logOpt.WorkbookLocalFolder;
        if (string.IsNullOrWhiteSpace(folder))
        {
            var root = _importOpt.ReportOutputsRoot;
            folder = string.IsNullOrWhiteSpace(root)
                ? Path.Combine(AppContext.BaseDirectory, "ProcessLogs")
                : Path.Combine(root, "ProcessLogs");
        }

        folder = folder.Trim();
        if (!Path.IsPathRooted(folder))
            folder = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, folder));

        Directory.CreateDirectory(folder);
        return folder;
    }

    private async Task SafeUploadAsync(DateTime nowIst, CancellationToken ct)
    {
        if (!_logOpt.WorkbookUploadToSharePoint) return;
        if (_importOpt.SharePoint == null || !_importOpt.SharePoint.Enabled) return;

        try
        {
            var paths = GetPaths(nowIst);
            if (!File.Exists(paths.WorkbookPath)) return;

            var driveId = _cachedDriveId;
            if (string.IsNullOrWhiteSpace(driveId))
            {
                driveId = await _sp.TryGetDriveIdAsync(ct);
                _cachedDriveId = driveId;
            }

            if (string.IsNullOrWhiteSpace(driveId)) return;

            var spFolder = ResolveSharePointFolder(nowIst);
            if (string.IsNullOrWhiteSpace(spFolder)) return;

            await _sp.UploadFileToFolderPathAsync(
                driveId: driveId!,
                folderPath: spFolder,
                localFilePath: paths.WorkbookPath,
                uploadFileName: paths.WorkbookFileName,
                ct: ct);
        

            // Also upload daily CSV logs (Run/Step/Error) to the same SharePoint folder, if CSV logging is enabled.
            await TryUploadCsvLogsAsync(nowIst, driveId!, spFolder, ct);
}
        catch
        {
            // Never let logging/upload failures break the pipeline.
        }
    }

    
    private async Task TryUploadCsvLogsAsync(DateTime nowIst, string driveId, string spFolder, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.CsvEnabled) return;
        if (_importOpt.SharePoint == null || !_importOpt.SharePoint.Enabled) return;
        if (_importOpt.SharePoint.UploadMasterProcessorLog == false) return;
        if (string.IsNullOrWhiteSpace(driveId) || string.IsNullOrWhiteSpace(spFolder)) return;

        try
        {
            var folder = ResolveCsvFolder();

            var runCsv = ProcessLogCsv.GetRunCsvPath(folder, nowIst);
            var stepCsv = ProcessLogCsv.GetStepCsvPath(folder, nowIst);
            var errCsv = ProcessLogCsv.GetErrorCsvPath(folder, nowIst);

            async Task UploadIfExistsAsync(string path)
            {
                if (!File.Exists(path)) return;
                await _sp.UploadFileToFolderPathAsync(
                    driveId: driveId,
                    folderPath: spFolder,
                    localFilePath: path,
                    uploadFileName: Path.GetFileName(path),
                    ct: ct);
            }

            await UploadIfExistsAsync(runCsv);
            await UploadIfExistsAsync(stepCsv);
            await UploadIfExistsAsync(errCsv);
        }
        catch
        {
            // Never let log upload failures break the pipeline.
        }
    }

    private string ResolveCsvFolder()
    {
        var folder = _logOpt.CsvLocalFolder;
        if (string.IsNullOrWhiteSpace(folder))
        {
            var root = _importOpt.ReportOutputsRoot;
            folder = string.IsNullOrWhiteSpace(root)
                ? Path.Combine(AppContext.BaseDirectory, "ProcessLogs")
                : Path.Combine(root, "ProcessLogs");
        }

        folder = folder.Trim();
        if (!Path.IsPathRooted(folder))
            folder = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, folder));

        Directory.CreateDirectory(folder);
        return folder;
    }

private string ResolveSharePointFolder(DateTime nowIst)
    {
        // SharePoint must be enabled and log upload allowed
        if (_importOpt.SharePoint == null || !_importOpt.SharePoint.Enabled)
            return "";

        // Optional gate: allow turning off master processor log uploads independently
        if (_importOpt.SharePoint.UploadMasterProcessorLog == false)
            return "";

        // Prefer explicit ProcessLog config, else use MasterProcessor log folder, else fall back to FileStatus folder.
        var baseFolder = _logOpt.WorkbookSharePointFolderPath;

        if (string.IsNullOrWhiteSpace(baseFolder))
            baseFolder = _importOpt.SharePoint.MasterProcessorLogUploadFolderPath;

        if (string.IsNullOrWhiteSpace(baseFolder))
            baseFolder = _importOpt.SharePoint.FileStatusLogUploadFolderPath;

        if (string.IsNullOrWhiteSpace(baseFolder))
            return "";

        baseFolder = baseFolder.Trim().Trim('/');

// If user provided ImportLogs root, expand to ImportLogs/{yyyy}/{Month}
        // If user provided ImportLogs/{yyyy}, expand to ImportLogs/{yyyy}/{Month}
        var month = nowIst.ToString("MMMM", CultureInfo.InvariantCulture);
        var year = nowIst.ToString("yyyy", CultureInfo.InvariantCulture);

        if (baseFolder.EndsWith("ImportLogs", StringComparison.OrdinalIgnoreCase))
            return $"{baseFolder}/{year}/{month}";

        if (baseFolder.EndsWith($"ImportLogs/{year}", StringComparison.OrdinalIgnoreCase))
            return $"{baseFolder}/{month}";

        // If caller already points to a year/month structure, use as-is
        return baseFolder;
    }
}
