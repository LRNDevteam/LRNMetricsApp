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
/// the two paths can never drift.
/// </summary>
public sealed class ExecutiveSummaryReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.ExecutiveSummary;

    private readonly LabSettings _labSettings;
    private readonly SqlPhiExecutiveSummaryRepository _repo;
    private readonly ILogger<ExecutiveSummaryReportGenerator> _logger;

    public ExecutiveSummaryReportGenerator(
        LabSettings labSettings,
        SqlPhiExecutiveSummaryRepository repo,
        ILogger<ExecutiveSummaryReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig)
            || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException($"Executive Summary is not available for '{job.LabName}'.");

        if (!ExecutiveSummaryController.LabPrefixMap.TryGetValue(job.LabName, out var prefix))
            throw new InvalidOperationException($"Executive Summary has no SP prefix mapping for '{job.LabName}'.");

        var connStr = labConfig.DbConnectionString;
        var spName  = SqlPhiExecutiveSummaryRepository.ExecutiveSummaryGetSpName(prefix);
        var f = ExecutiveSummaryFilters.FromJson(job.FilterDetailsJson);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        if (!await _repo.StoredProcedureExistsAsync(connStr, spName, ct))
            throw new InvalidOperationException(
                $"Data not generated for '{job.LabName}': stored procedure '{spName}' does not exist.");
        await Progress(10);

        // Same argument shaping as ExecutiveSummaryController.Index.
        var panelsStr    = Join(f.Panels);
        var clinicsStr   = Join(f.Clinics);
        var providersStr = Join(f.Providers);
        var repsStr      = Join(f.Reps);

        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();

        var vm = await _repo.GetExecutiveSummaryAsync(
            connStr, spName, availableLabs, job.LabName,
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

        var bytes = new ExecutiveSummaryExcelBuilder().Build(vm);
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

    private static string? Join(List<string>? values) =>
        values is { Count: > 0 } ? string.Join(",", values) : null;

    private static DateTime? ParseDate(string? value) =>
        DateTime.TryParse(value, out var d) && d != default ? d : null;
}
