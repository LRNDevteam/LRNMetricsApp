using ClosedXML.Excel;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LRN.ProductionReports.Models;
using Microsoft.Extensions.Logging;

namespace LabMetricsDashboard.Services;

/// <summary>
/// NorthWest Executive Summary download: appends the page's Production, Collection and
/// LIMS Highlights tabs as extra sheets. Each section reuses its own report's repository
/// calls, Excel sheet builders and Key Insights block, so the numbers match the
/// Production Summary, Collection Summary and LIS Summary downloads (unfiltered).
/// Shared by ExecutiveSummaryController (export=excel) and LRN.ReportWorker's
/// ExecutiveSummaryReportGenerator.
/// </summary>
public sealed class ExecutiveSummaryHighlightsExcel
{
    private const string ProductionReportName = "Production Report";
    private const string CollectionReportName = "Collection Report";
    private const string LisReportName        = "LIS Report";
    private const string LisDateType          = "Collected";

    private static readonly Dictionary<string, string> CollectionSheetNames = new(StringComparer.OrdinalIgnoreCase)
    {
        [InsightsExcelBuilder.SheetName] = "Collection Highlights",
        [CollectionSummaryExcelExportBuilder.Top5InsurancesSheetName] = "CH - Top 5 Insurances",
        [CollectionSummaryExcelExportBuilder.PanelAveragesDosSheetName]       = "CH - Panel Avg by DOS",
        [CollectionSummaryExcelExportBuilder.PanelAveragesCheckDateSheetName] = "CH - Panel Avg by Check Date",
    };

    private readonly LabSettings _labSettings;
    private readonly INorthWestProductionSummaryRepository _production;
    private readonly ICollectionSummaryRepository _collection;
    private readonly ILisSummaryRepository _lis;
    private readonly INotesRepository _notes;
    private readonly ILogger<ExecutiveSummaryHighlightsExcel> _logger;

    public ExecutiveSummaryHighlightsExcel(
        LabSettings labSettings,
        INorthWestProductionSummaryRepository production,
        ICollectionSummaryRepository collection,
        ILisSummaryRepository lis,
        INotesRepository notes,
        ILogger<ExecutiveSummaryHighlightsExcel> logger)
    {
        _labSettings = labSettings;
        _production  = production;
        _collection  = collection;
        _lis         = lis;
        _notes       = notes;
        _logger      = logger;
    }

    public static bool AppliesTo(string? labName) => LabCollectionPrefix.IsNorthWest(labName);

    /// <summary>
    /// Returns the Executive Summary workbook with the highlight sheets appended.
    /// A section that fails to load gets a one-line notice sheet instead of failing the download.
    /// </summary>
    public async Task<byte[]> AppendAsync(byte[] executiveSummaryXlsx, string labName, CancellationToken ct)
    {
        if (!AppliesTo(labName)
            || !_labSettings.Labs.TryGetValue(labName, out var config)
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return executiveSummaryXlsx;

        var connStr = config.DbConnectionString;

        var productionTask = TryBuildAsync("Production Highlights", labName,
            () => BuildProductionAsync(connStr, labName, ct));
        var collectionTask = TryBuildAsync("Collection Highlights", labName,
            () => BuildCollectionAsync(connStr, labName, config, ct));
        var lisTask = TryBuildAsync("LIMS Highlights", labName,
            () => BuildLisAsync(connStr, labName, ct));
        await Task.WhenAll(productionTask, collectionTask, lisTask);

        using var target = new XLWorkbook(new MemoryStream(executiveSummaryXlsx));

        using (var production = productionTask.Result)
            CopySheets(production, target, "Production Highlights",
                name => name.Equals(InsightsExcelBuilder.SheetName, StringComparison.OrdinalIgnoreCase)
                    ? "Production Highlights" : null);

        using (var collection = collectionTask.Result)
            CopySheets(collection, target, "Collection Highlights",
                name => CollectionSheetNames.GetValueOrDefault(name) ?? SheetName("CH - " + name));

        using (var lis = lisTask.Result)
        {
            CopySheets(lis, target, "LIMS Highlights",
                name => name.Equals("LIS Summary", StringComparison.OrdinalIgnoreCase) ? "LIMS Highlights" : null);
            CopySheets(lis, target, "LIMS Key Insights",
                name => name.Equals(InsightsExcelBuilder.SheetName, StringComparison.OrdinalIgnoreCase)
                    ? "LIMS Key Insights" : null);
        }

        using var ms = new MemoryStream();
        target.SaveAs(ms);
        return ms.ToArray();
    }

    private async Task<XLWorkbook> BuildProductionAsync(string connStr, string labName, CancellationToken ct)
    {
        var monthlyTask = _production.GetMonthlyAsync(connStr, null, null, null, null, null, null, null, null, ct);
        var weeklyTask  = _production.GetWeeklyAsync(connStr, null, null, null, null, null, null, null, null, ct);
        await Task.WhenAll(monthlyTask, weeklyTask);
        var monthly = monthlyTask.Result;
        var weekly  = weeklyTask.Result;

        var vm = new ProductionReportViewModel
        {
            AvailableLabs           = _labSettings.Labs.Keys.OrderBy(x => x).ToList(),
            SelectedLab             = labName,
            Months                  = monthly.Months,
            Years                   = monthly.Years,
            PanelRows               = monthly.PanelRows,
            GrandTotalByMonth       = monthly.GrandTotalByMonth,
            GrandTotalClaims        = monthly.GrandTotalClaims,
            GrandTotalCharges       = monthly.GrandTotalCharges,
            WeekColumns             = weekly.WeekColumns,
            WeeklyPanelRows         = weekly.PanelRows,
            WeeklyGrandTotalByWeek  = weekly.GrandTotalByWeek,
            WeeklyGrandTotalClaims  = weekly.GrandTotalClaims,
            WeeklyGrandTotalCharges = weekly.GrandTotalCharges,
        };

        var wb = NorthWestProductionSummaryExcelExportBuilder.CreateHighlightsWorkbook(vm, labName);
        await AppendInsightsAsync(wb, connStr, labName, ProductionReportName, ct);
        return wb;
    }

    private async Task<XLWorkbook> BuildCollectionAsync(
        string connStr, string labName, LabCsvConfig config, CancellationToken ct)
    {
        var showTotalPayments = !config.DisableShowTop5TotalPayments;
        var useLineEncounters = string.Equals(config.CollectionOutput, "table1", StringComparison.OrdinalIgnoreCase);

        var monthlyTask = _collection.GetCollectionMonthlyVolumeAsync(
            connStr, labName, useLineEncounters, null, null, null, null, null, null, null, null, ct);
        var weeklyTask = _collection.GetCollectionWeeklyVolumeAsync(
            connStr, useLineEncounters, null, null, null, null, null, null, null, null, labName, ct);
        var reimbursementTask = _collection.GetTop5ReimbursementAsync(
            connStr, null, null, null, null, null, null, null, null, labName, ct);
        var totalPaymentsTask = showTotalPayments
            ? _collection.GetTop5TotalPaymentsAsync(
                connStr, null, null, null, null, null, null, null, null, labName, ct)
            : Task.FromResult(new Top5TotalPaymentsResult([]));
        var avgDosTask = _collection.GetAvgPaymentsByDateBasisAsync(
            connStr, AvgPaymentsDateBasis.DateOfService,
            null, null, null, null, null, null, null, null, labName, ct);
        var avgCheckDateTask = _collection.GetAvgPaymentsByDateBasisAsync(
            connStr, AvgPaymentsDateBasis.CheckDate,
            null, null, null, null, null, null, null, null, labName, ct);
        await Task.WhenAll(monthlyTask, weeklyTask, reimbursementTask, totalPaymentsTask, avgDosTask, avgCheckDateTask);

        var vm = new CollectionSummaryViewModel
        {
            SelectedLab                = labName,
            MonthlyClaimVolume         = CollectionSummaryController.BuildCollectionMonthlyPivot(monthlyTask.Result),
            WeeklyClaimVolume          = CollectionSummaryController.BuildCollectionWeeklyPivot(weeklyTask.Result),
            UsesLineEncounters         = useLineEncounters,
            Top5Reimbursement          = reimbursementTask.Result.Rows,
            Top5TotalPayments          = totalPaymentsTask.Result.Rows,
            ShowTop5TotalPayments      = showTotalPayments,
            AvgPaymentsDos             = avgDosTask.Result,
            AvgPayments                = avgCheckDateTask.Result,
            ShowAvgPaymentsByDateBasis = true,
        };

        var wb = CollectionSummaryExcelExportBuilder.CreateHighlightsWorkbook(vm, labName);
        await AppendInsightsAsync(wb, connStr, labName, CollectionReportName, ct);
        return wb;
    }

    private async Task<XLWorkbook> BuildLisAsync(string connStr, string labName, CancellationToken ct)
    {
        var summary = await _lis.GetLisSummaryAsync(
            connStr, labName, null, LisDateType, null, null,
            null, null, null, null, null, ct, includeKeyMetrics: false);

        var wb = LisSummaryExcelExportBuilder.CreateWorkbook(
            summary, lineData: null, labName, LisDateType, null, null,
            null, null, null, null, null);
        await AppendInsightsAsync(wb, connStr, labName, LisReportName, ct);
        return wb;
    }

    private async Task AppendInsightsAsync(
        XLWorkbook wb, string connStr, string labName, string reportName, CancellationToken ct)
    {
        var insights = await InsightsExcelBuilder.LoadAsync(_notes, connStr, reportName, ct);
        var tplCols  = await InsightsExcelBuilder.LoadTemplateColumnsAsync(_notes, connStr, reportName, ct);
        InsightsExcelBuilder.InsertAsFirstSheet(wb, insights, labName, reportName, tplCols);
    }

    private async Task<XLWorkbook> TryBuildAsync(string section, string labName, Func<Task<XLWorkbook>> build)
    {
        try
        {
            return await build();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Executive Summary {Section} sheet failed for lab {Lab}.", section, labName);
            var wb = new XLWorkbook();
            var ws = wb.AddWorksheet(InsightsExcelBuilder.SheetName);
            ws.Cell(1, 1).Value = $"{section} could not be loaded: {ex.Message}";
            ws.Cell(1, 1).Style.Font.Bold = true;
            ws.Cell(1, 1).Style.Font.FontColor = XLColor.DarkRed;
            ws.Column(1).Width = 100;
            return wb;
        }
    }

    /// <summary>
    /// Copies every sheet of <paramref name="source"/> that <paramref name="rename"/> maps to a
    /// name onto the end of <paramref name="target"/>. Writes a notice sheet named
    /// <paramref name="fallbackName"/> when nothing was copied (no data for the section).
    /// </summary>
    private static void CopySheets(
        XLWorkbook source, XLWorkbook target, string fallbackName, Func<string, string?> rename)
    {
        var copied = 0;
        foreach (var ws in source.Worksheets.OrderBy(w => w.Position).ToList())
        {
            var name = rename(ws.Name);
            if (name is null || target.Worksheets.Contains(name)) continue;
            ws.CopyTo(target, name);
            copied++;
        }

        if (copied > 0 || target.Worksheets.Contains(fallbackName)) return;

        var notice = target.AddWorksheet(fallbackName);
        notice.Cell(1, 1).Value = $"No data available for {fallbackName}.";
        notice.Cell(1, 1).Style.Font.Bold = true;
        notice.Column(1).Width = 60;
    }

    private static string SheetName(string name) => name.Length <= 31 ? name : name[..31];
}
