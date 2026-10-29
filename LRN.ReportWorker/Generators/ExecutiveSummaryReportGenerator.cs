using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Executive Summary export — same per-lab stored procedure
/// (dbo.usp_Get{prefix}_ExecutiveSummary) and ExecutiveSummaryExcelBuilder the
/// ExecutiveSummary page uses for its synchronous "export=excel" download.
/// Lab → SP prefix resolution reuses ExecutiveSummaryController.LabPrefixMap so
/// the two paths can never drift. Well Health is prefix WH
/// (dbo.usp_GetWH_ExecutiveSummary).
/// </summary>
public sealed class ExecutiveSummaryReportGenerator : IReportGenerator, IReportSnapshotSource
{
    public string ReportType => ReportTypes.ExecutiveSummary;
    public string SnapshotReportCode => ReportSnapshotCodes.ExecutiveSummary;

    private readonly LabSettings _labSettings;
    private readonly SqlPhiExecutiveSummaryRepository _repo;
    private readonly ExecutiveSummaryHighlightsExcel _highlights;
    private readonly ILogger<ExecutiveSummaryReportGenerator> _logger;

    public ExecutiveSummaryReportGenerator(
        LabSettings labSettings,
        SqlPhiExecutiveSummaryRepository repo,
        ExecutiveSummaryHighlightsExcel highlights,
        ILogger<ExecutiveSummaryReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _highlights  = highlights;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        var f = ExecutiveSummaryFilters.FromJson(job.FilterDetailsJson);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        var vm = await LoadViewModelAsync(job.LabName, f, Progress, ct);

        var bytes = new ExecutiveSummaryExcelBuilder().Build(vm);
        await Progress(75);

        // NorthWest, Cove, Analyze Pathology, Augustus, WellHealth: Production / Collection / LIMS / Denial Highlights tabs of the page.
        if (ExecutiveSummaryHighlightsExcel.AppliesTo(job.LabName))
            bytes = await _highlights.AppendAsync(bytes, job.LabName, ct);
        await Progress(90);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        try
        {
            await File.WriteAllBytesAsync(tempPath, bytes, ct);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "ExecutiveSummary {ReportId} [{Lab}]: {Rows:N0} rows, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, vm.Rows.Count, size, targetPath);
        await Progress(100);

        return new GeneratedReportFile(fileName, targetPath, size, vm.Rows.Count);
    }

    public async Task<object?> LoadUnfilteredAsync(string labName, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var labConfig)
            || string.IsNullOrWhiteSpace(labConfig.DbConnectionString)
            || !ExecutiveSummaryController.LabPrefixMap.ContainsKey(labName))
            return null;
        return await LoadViewModelAsync(labName, ExecutiveSummaryFilters.FromJson(null), _ => Task.CompletedTask, ct);
    }

    /// <summary>The page's view model for these filters: the grid plus the run / analysis-range banner.</summary>
    private async Task<PhiExecutiveSummaryViewModel> LoadViewModelAsync(
        string labName, ExecutiveSummaryFilters f, Func<byte, Task> Progress, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var labConfig)
            || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException($"Executive Summary is not available for '{labName}'.");

        if (!ExecutiveSummaryController.LabPrefixMap.TryGetValue(labName, out var prefix))
            throw new InvalidOperationException($"Executive Summary has no SP prefix mapping for '{labName}'.");

        var connStr = labConfig.DbConnectionString;
        var spName  = SqlPhiExecutiveSummaryRepository.ExecutiveSummaryGetSpName(prefix);

        if (!await _repo.StoredProcedureExistsAsync(connStr, spName, ct))
            throw new InvalidOperationException(
                $"Data not generated for '{labName}': stored procedure '{spName}' does not exist.");
        await Progress(10);

        // Same argument shaping as ExecutiveSummaryController.Index.
        var panelsStr    = Join(f.Panels);
        var clinicsStr   = Join(f.Clinics);
        var providersStr = Join(f.Providers);
        var repsStr      = Join(f.Reps);

        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();

        var vm = await _repo.GetExecutiveSummaryAsync(
            connStr, spName, availableLabs, labName,
            f.YearFrom, f.YearTo, f.MonthFrom, f.MonthTo,
            useExtendedFilters: true,
            dosFrom:    ParseDate(f.DosFrom),
            dosTo:      ParseDate(f.DosTo),
            billedFrom: ParseDate(f.BilledFrom),
            billedTo:   ParseDate(f.BilledTo),
            panels:     panelsStr,
            clinics:    clinicsStr,
            providers:  providersStr,
            reps:       repsStr,
            ct: ct);
        await Progress(60);

        // Restore true selections (repository re-splits comma-joined strings, which
        // corrupts values containing commas) — same fix as the controller applies.
        vm.SelectedPanels    = f.Panels    ?? [];
        vm.SelectedClinics   = f.Clinics   ?? [];
        vm.SelectedProviders = f.Providers ?? [];
        vm.SelectedReps      = f.Reps      ?? [];

        // Run / analysis-range banner (mirrors the page header).
        var (weekFolder, claimRunId, limsRunId) = await _repo.GetRunInfoAsync(connStr, ct);
        vm.ReportWeekFolder = weekFolder;
        vm.ReportRunId      = claimRunId;
        vm.LimsRunId        = limsRunId;
        await Progress(70);
        return vm;
    }

    private static string? Join(List<string>? values) =>
        values is { Count: > 0 } ? string.Join(",", values) : null;

    private static DateTime? ParseDate(string? value) =>
        DateTime.TryParse(value, out var d) && d != default ? d : null;
}
