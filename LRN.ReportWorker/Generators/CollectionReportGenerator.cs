using ClosedXML.Excel;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Collection Report export — the full Collection Summary workbook with the
/// big ClaimLevelData / LineLevelData raw sheets INCLUDED (the synchronous export
/// skips them above 200K rows to avoid OOM).
///
/// Summary sheets: CollectionSummaryController.BuildCollectionExportViewModelAsync
/// (same repository queries/pivots) + CollectionSummaryExcelExportBuilder.
///
/// Raw sheets: streamed straight from SqlDataReader in 10K-row chunks using the
/// repository-built SELECTs (BuildClaim/LineLevelExportQuery — same SQL as the
/// sync export), split into sheets every 300K rows. Rows never sit in a giant
/// list, so 700K+ row tables export fine.
/// </summary>
public sealed class CollectionReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.CollectionReport;

    private readonly IServiceProvider _services;
    private readonly LabSettings _labSettings;
    private readonly ICollectionSummaryRepository _repo;
    private readonly ILogger<CollectionReportGenerator> _logger;

    public CollectionReportGenerator(
        IServiceProvider services,
        LabSettings labSettings,
        ICollectionSummaryRepository repo,
        ILogger<CollectionReportGenerator> logger)
    {
        _services    = services;
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not configured.");
        if (!labConfig.LineClaimEnable || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException($"Collection Report is not available for '{job.LabName}'.");

        var connStr = labConfig.DbConnectionString;
        var f = CollectionReportFilters.FromJson(job.FilterDetailsJson);

        // Same date semantics as the synchronous action.
        DateOnly? fbFrom  = ParseDate(f.FirstBillFrom);
        DateOnly? fbTo    = ParseDate(f.FirstBillTo);
        DateOnly? dosFrom = ParseDate(f.DosFrom);
        DateOnly? dosTo   = ParseDate(f.DosTo);
        DateOnly? cdFrom  = ParseDate(f.CheckDateFrom);
        DateOnly? cdTo    = ParseDate(f.CheckDateTo);
        var payerFilter = f.PayerNames is { Count: > 0 } ? f.PayerNames : null;
        var panelFilter = f.PanelNames is { Count: > 0 } ? f.PanelNames : null;

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        // Row counts up front — drives accurate progress %.
        var claimCount = await _repo.GetClaimLevelDataCountAsync(
            connStr, payerFilter, panelFilter, fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo, ct);
        var lineCount = await _repo.GetLineLevelDataCountAsync(
            connStr, payerFilter, panelFilter, fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo, ct);
        await Progress(5);

        var showTotalPayments = !labConfig.DisableShowTop5TotalPayments;
        var useLineEncounters = !string.IsNullOrWhiteSpace(labConfig.CollectionOutput)
            && string.Equals(labConfig.CollectionOutput, "table1", StringComparison.OrdinalIgnoreCase);

        var controller = _services.GetRequiredService<CollectionSummaryController>();
        controller.ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() };

        var vm = await controller.BuildCollectionExportViewModelAsync(
            job.LabName, connStr, useLineEncounters, showTotalPayments,
            payerFilter, panelFilter, fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo, ct);
        await Progress(15);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        int totalRows;
        try
        {
            totalRows = await WriteWorkbookAsync(
                connStr, job, vm, f, payerFilter, panelFilter,
                fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo,
                claimCount, lineCount, tempPath, Progress, ct);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { }
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "CollectionReport {ReportId} [{Lab}]: {Claim:N0} claim + {Line:N0} line rows, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, claimCount, lineCount, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, totalRows);
    }

    private async Task<int> WriteWorkbookAsync(
        string connStr, ClaimedReport job, CollectionSummaryViewModel vm, CollectionReportFilters f,
        List<string>? payerFilter, List<string>? panelFilter,
        DateOnly? fbFrom, DateOnly? fbTo, DateOnly? dosFrom, DateOnly? dosTo,
        DateOnly? cdFrom, DateOnly? cdTo,
        int claimCount, int lineCount, string tempPath,
        Func<byte, Task> progress, CancellationToken ct)
    {
        // Summary sheets via ClosedXML (small). Raw Claim/Line sheets streamed with
        // OpenXml and merged in — ClosedXML SaveAs OOMs when those sheets are huge.
        using (var wb = CollectionSummaryExcelExportBuilder.CreateWorkbook(
            vm, [], [], job.LabName, f.ToActiveFilterList()))
        {
            foreach (var placeholder in wb.Worksheets
                         .Where(ws => ws.Name is "ClaimLevelData" or "LineLevelData")
                         .ToList())
                placeholder.Delete();

            using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
                wb.SaveAs(fs);
        }
        await progress(20);

        var totalAll = Math.Max(1, claimCount + lineCount);

        var (claimQuery, claimParams) = _repo.BuildClaimLevelExportQuery(
            payerFilter, panelFilter, fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo);
        var claimRows = await OpenXmlRowStreamer.AppendSqlSheetsToWorkbookAsync(
            tempPath, connStr, claimQuery, claimParams, "ClaimLevelData",
            done => progress((byte)(20 + Math.Min(35, done * 35L / totalAll))), ct);
        await progress(55);

        var (lineQuery, lineParams) = _repo.BuildLineLevelExportQuery(
            payerFilter, panelFilter, fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo);
        var lineRows = await OpenXmlRowStreamer.AppendSqlSheetsToWorkbookAsync(
            tempPath, connStr, lineQuery, lineParams, "LineLevelData",
            done => progress((byte)(55 + Math.Min(35, done * 35L / totalAll))), ct);

        await progress(95);
        return claimRows + lineRows;
    }

    private static DateOnly? ParseDate(string? value) =>
        DateOnly.TryParse(value, out var d) && d != default ? d : null;
}
