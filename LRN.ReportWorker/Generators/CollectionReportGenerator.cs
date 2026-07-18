using System.Data;
using ClosedXML.Excel;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
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

    private const int SheetSplitThreshold = 300_000;
    private const int InsertBatchSize     = 10_000;

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
        // Summary sheets from the existing builder; raw lists empty — the two
        // placeholder raw sheets it creates are removed and replaced below with
        // streamed, chunked versions.
        using var wb = CollectionSummaryExcelExportBuilder.CreateWorkbook(
            vm, [], [], job.LabName, f.ToActiveFilterList());

        foreach (var placeholder in wb.Worksheets
                     .Where(ws => ws.Name is "ClaimLevelData" or "LineLevelData")
                     .ToList())
            placeholder.Delete();

        var totalAll = Math.Max(1, claimCount + lineCount);

        // Progress budget: 15–55% claim rows, 55–90% line rows, 90%+ save.
        var (claimQuery, claimParams) = _repo.BuildClaimLevelExportQuery(
            payerFilter, panelFilter, fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo);
        var claimRows = await StreamTableAsync(
            wb, connStr, claimQuery, claimParams, "ClaimLevelData", job.LabName,
            ExcelTheme.TabGreen,
            done => progress((byte)(15 + Math.Min(40, done * 40L / totalAll))), ct);

        var (lineQuery, lineParams) = _repo.BuildLineLevelExportQuery(
            payerFilter, panelFilter, fbFrom, fbTo, dosFrom, dosTo, cdFrom, cdTo);
        var lineRows = await StreamTableAsync(
            wb, connStr, lineQuery, lineParams, "LineLevelData", job.LabName,
            ExcelTheme.SubHeaderBg,
            done => progress((byte)(55 + Math.Min(35, done * 35L / totalAll))), ct);

        await progress(90);

        using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            wb.SaveAs(fs);

        return claimRows + lineRows;
    }

    /// <summary>
    /// Streams one SELECT into sheets named {baseName}, {baseName}_P2, … —
    /// 10K-row InsertData batches, new sheet every 300K rows.
    /// </summary>
    private static async Task<int> StreamTableAsync(
        XLWorkbook wb, string connStr, string sql, List<SqlParameter> parameters,
        string baseName, string labName, XLColor tabColor,
        Func<int, Task> onRows, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connStr);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 1800 };
        foreach (var p in parameters)
            cmd.Parameters.Add(new SqlParameter(p.ParameterName, p.Value ?? DBNull.Value));

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        var headers = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToArray();

        IXLWorksheet? ws = null;
        var nextRow = 3;
        var sheetRowCount = 0;
        var sheetIndex = 0;
        var total = 0;
        var batch = new List<object?[]>(InsertBatchSize);

        void Flush()
        {
            if (ws is null || batch.Count == 0) { batch.Clear(); return; }
            ws.Cell(nextRow, 1).InsertData(batch);
            nextRow += batch.Count;
            batch.Clear();
        }

        IXLWorksheet NewSheet()
        {
            sheetIndex++;
            var name = sheetIndex == 1 ? baseName : $"{baseName}_P{sheetIndex}";
            var sheet = wb.AddWorksheet(name.Length <= 31 ? name : name[..31]);
            sheet.TabColor = tabColor;
            sheet.Style.Font.FontName = "Calibri";
            sheet.Style.Font.FontSize = 10;

            sheet.Range(1, 1, 1, headers.Length).Merge();
            var title = sheet.Cell(1, 1);
            title.Value = $"{baseName} — {labName}" + (sheetIndex > 1 ? $" (part {sheetIndex})" : "");
            title.Style.Font.Bold = true;
            title.Style.Font.FontColor = XLColor.White;
            title.Style.Font.FontName = ExcelTheme.FontName;
            title.Style.Font.FontSize = ExcelTheme.FontSizeTitle;
            title.Style.Fill.BackgroundColor = ExcelTheme.TitleBg;

            for (var c = 0; c < headers.Length; c++)
                sheet.Cell(2, c + 1).Value = headers[c];
            var hdr = sheet.Range(2, 1, 2, headers.Length);
            hdr.Style.Font.Bold = true;
            hdr.Style.Font.FontColor = XLColor.White;
            hdr.Style.Font.FontName = ExcelTheme.FontName;
            hdr.Style.Font.FontSize = ExcelTheme.FontSizeHeader;
            hdr.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
            sheet.SheetView.FreezeRows(2);
            return sheet;
        }

        while (await reader.ReadAsync(ct))
        {
            ct.ThrowIfCancellationRequested();

            if (ws is null || sheetRowCount >= SheetSplitThreshold)
            {
                Flush();
                ws = NewSheet();
                nextRow = 3;
                sheetRowCount = 0;
            }

            var values = new object?[headers.Length];
            for (var c = 0; c < headers.Length; c++)
            {
                var v = reader.GetValue(c);
                values[c] = v is DBNull ? string.Empty : v;
            }
            batch.Add(values);
            total++;
            sheetRowCount++;

            if (batch.Count >= InsertBatchSize)
            {
                Flush();
                await onRows(total);
            }
        }
        Flush();

        if (ws is null)
        {
            var empty = wb.AddWorksheet(baseName);
            empty.TabColor = tabColor;
            empty.Cell(1, 1).Value = "No data available.";
        }

        return total;
    }

    private static DateOnly? ParseDate(string? value) =>
        DateOnly.TryParse(value, out var d) && d != default ? d : null;
}
