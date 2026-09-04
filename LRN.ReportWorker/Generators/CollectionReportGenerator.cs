using ClosedXML.Excel;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ProductionReports.Services;
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
    private readonly IProductionReportRepository _prodRepo;   // for the shared SP-export streamer
    private readonly INotesRepository _notes;
    private readonly ILogger<CollectionReportGenerator> _logger;

    public CollectionReportGenerator(
        IServiceProvider services,
        LabSettings labSettings,
        ICollectionSummaryRepository repo,
        IProductionReportRepository prodRepo,
        INotesRepository notes,
        ILogger<CollectionReportGenerator> logger)
    {
        _services    = services;
        _labSettings = labSettings;
        _repo        = repo;
        _prodRepo    = prodRepo;
        _notes       = notes;
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
        using (var wb = LabMetricsDashboard.Services.CollectionSummaryExcelExportBuilder.CreateWorkbook(
            vm, [], [], job.LabName, f.ToActiveFilterList()))
        {
            foreach (var placeholder in wb.Worksheets
                         .Where(ws => ws.Name is "ClaimLevelData" or "LineLevelData")
                         .ToList())
                placeholder.Delete();

            await InsightsSheetInjector.InsertAsync(
                wb, _notes, connStr, job.LabName, "Collection Report", ct);

            using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
                wb.SaveAs(fs);
        }
        await progress(20);
        _ = (claimCount, lineCount);   // pre-counts drive GenerateAsync's log/progress only

        // Raw Claim/Line sheets now stream through the SAME bucketed SP export mechanism the
        // Production Summary report uses (memory-flat, SQL-pre-split), but against Collection-
        // specific SPs that honour ALL Collection filters — including CheckDate — and filter
        // Payer/Panel on the columns the Collection filter dropdown is built from
        // (PayerName_Raw + the lab-specific panel column). RecordId/FileLogId are dropped per
        // the client's field selection (2026-07-31).
        //
        // Filter mapping into AppendSpExportSheetsToFileAsync:
        //   Collection "First Bill" (fb*) -> FirstBilledDate  => filterFirstBilled*
        //   Collection DOS (dos*)         -> DateOfService     => filterDos*
        //   Collection CheckDate (cd*)    -> CheckDate         => filterCheckDate*
        //   (ChargeEnteredDate / filterFirstBill* is unused by Collection -> left null)
        var sqlRepo = _prodRepo as SqlProductionReportRepository
            ?? throw new InvalidOperationException(
                "Production report repository must be SqlProductionReportRepository for the Collection SP export.");

        var claimPanelColumn = LabCollectionPrefix.GetPanelColumn(job.LabName);   // PanelType (NW) / PanelName
        string[] excludeColumns = ["RecordId", "FileLogId"];
        var claimInclude = LabClaimLineColumnCatalog.GetClaimColumns(job.LabName);
        var lineInclude  = LabClaimLineColumnCatalog.GetLineColumns(job.LabName);

        var claimRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            tempPath, connStr,
            "dbo.usp_GetCollectionClaimLevelExportBuckets",
            "dbo.usp_GetCollectionClaimLevelExportDataByDateRange",
            "ClaimLevel", LRN.ProductionReports.Services.ExcelTheme.TabGreen,
            filterPayerNames: payerFilter,
            filterPanelNames: panelFilter,
            filterDosFrom: dosFrom, filterDosTo: dosTo,
            filterFirstBilledFrom: fbFrom, filterFirstBilledTo: fbTo,
            filterCheckDateFrom: cdFrom, filterCheckDateTo: cdTo,
            panelColumn: claimPanelColumn,
            excludeColumns: excludeColumns,
            includeColumns: claimInclude,
            ct: ct).ConfigureAwait(false);
        await progress(55);

        var lineRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            tempPath, connStr,
            "dbo.usp_GetCollectionLineLevelExportBuckets",
            "dbo.usp_GetCollectionLineLevelExportDataByDateRange",
            "LineLevel", LRN.ProductionReports.Services.ExcelTheme.TabGold,
            filterPayerNames: payerFilter,
            filterPanelNames: panelFilter,
            filterDosFrom: dosFrom, filterDosTo: dosTo,
            filterFirstBilledFrom: fbFrom, filterFirstBilledTo: fbTo,
            filterCheckDateFrom: cdFrom, filterCheckDateTo: cdTo,
            panelColumn: null,   // line table uses Panelname for every lab (SP default)
            excludeColumns: excludeColumns,
            includeColumns: lineInclude,
            ct: ct).ConfigureAwait(false);

        await progress(95);
        return claimRows + lineRows;
    }

    private static DateOnly? ParseDate(string? value) =>
        DateOnly.TryParse(value, out var d) && d != default ? d : null;
}
