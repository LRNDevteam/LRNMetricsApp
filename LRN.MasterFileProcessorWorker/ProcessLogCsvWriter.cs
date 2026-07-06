using Microsoft.Extensions.Options;
using System;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public interface IProcessLogCsvWriter
{
    Task UpsertRunAsync(DateTime nowIst, RunLogRow row, CancellationToken ct);
    Task UpsertStepAsync(DateTime nowIst, StepLogRow row, CancellationToken ct);
    Task AppendErrorAsync(DateTime nowIst, ErrorLogRow row, CancellationToken ct);
    Task IncrementRunCountAsync(DateTime nowIst, string runId, bool isWarning, CancellationToken ct);

    /// <summary>
    /// Gets the local file paths for today's three CSV logs (Run/Step/Error).
    /// Useful if you later want to upload them to SharePoint.
    /// </summary>
    ProcessLogCsvPaths GetPaths(DateTime nowIst);
}

public sealed class ProcessLogCsvPaths
{
    public string RunCsvPath { get; init; } = "";
    public string StepCsvPath { get; init; } = "";
    public string ErrorCsvPath { get; init; } = "";
}

public sealed class ProcessLogCsvWriter : IProcessLogCsvWriter
{
    private readonly ProcessLogOptions _logOpt;
    private readonly ImportOptions _importOpt;

    public ProcessLogCsvWriter(IOptions<ProcessLogOptions> logOpt, IOptions<ImportOptions> importOpt)
    {
        _logOpt = logOpt.Value ?? new ProcessLogOptions();
        _importOpt = importOpt.Value ?? new ImportOptions();
    }

    public Task UpsertRunAsync(DateTime nowIst, RunLogRow row, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.CsvEnabled || string.IsNullOrWhiteSpace(row.RunID))
            return Task.CompletedTask;

        var folder = ResolveFolder();
        _ = ProcessLogCsv.UpsertRun(folder, nowIst, row);
        return Task.CompletedTask;
    }

    public Task UpsertStepAsync(DateTime nowIst, StepLogRow row, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.CsvEnabled || string.IsNullOrWhiteSpace(row.RunID))
            return Task.CompletedTask;

        var folder = ResolveFolder();
        _ = ProcessLogCsv.UpsertStep(folder, nowIst, row);
        return Task.CompletedTask;
    }

    public Task AppendErrorAsync(DateTime nowIst, ErrorLogRow row, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.CsvEnabled || string.IsNullOrWhiteSpace(row.RunID))
            return Task.CompletedTask;

        var folder = ResolveFolder();
        _ = ProcessLogCsv.AppendError(folder, nowIst, row);
        return Task.CompletedTask;
    }

    public Task IncrementRunCountAsync(DateTime nowIst, string runId, bool isWarning, CancellationToken ct)
    {
        if (!_logOpt.Enabled || !_logOpt.CsvEnabled || string.IsNullOrWhiteSpace(runId))
            return Task.CompletedTask;

        var folder = ResolveFolder();
        ProcessLogCsv.IncrementRunCount(folder, nowIst, runId, isWarning);
        return Task.CompletedTask;
    }

    public ProcessLogCsvPaths GetPaths(DateTime nowIst)
    {
        var folder = ResolveFolder();
        return new ProcessLogCsvPaths
        {
            RunCsvPath = ProcessLogCsv.GetRunCsvPath(folder, nowIst),
            StepCsvPath = ProcessLogCsv.GetStepCsvPath(folder, nowIst),
            ErrorCsvPath = ProcessLogCsv.GetErrorCsvPath(folder, nowIst)
        };
    }

    private string ResolveFolder()
    {
        var folder = _logOpt.CsvLocalFolder;
        if (string.IsNullOrWhiteSpace(folder))
        {
            var root = _importOpt.ReportOutputsRoot;
            folder = string.IsNullOrWhiteSpace(root)
                ? Path.Combine(AppContext.BaseDirectory, "ProcessLogs")
                : Path.Combine(root, "ProcessLogs");
        }

        // Resolve relative paths against the service base directory.
        folder = folder.Trim();
        if (!Path.IsPathRooted(folder))
            folder = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, folder));

        Directory.CreateDirectory(folder);
        return folder;
    }
}
