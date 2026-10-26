using ClosedXML.Excel;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LRN.ProductionReports.Models;
using LRN.ProductionReports.Services;
using Microsoft.Extensions.Logging;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Executive Summary download for the labs with highlight tabs (NorthWest, Cove, Analyze
/// Pathology, Augustus, WellHealth): appends the page's Production, Collection, LIMS and Denial Highlights
/// tabs as extra sheets (Denial only where <see cref="ShowsDenialHighlights"/>). Each section reuses its own report's repository calls, Excel sheet builders
/// and Key Insights block, so the numbers match the Production Summary, Collection Summary,
/// LIS Summary and Denial Summary pages (unfiltered).
/// Shared by ExecutiveSummaryController (export=excel) and LRN.ReportWorker's
/// ExecutiveSummaryReportGenerator.
/// </summary>
public sealed class ExecutiveSummaryHighlightsExcel
{
    private const string ProductionReportName = "Production Report";
    private const string CollectionReportName = "Collection Report";
    private const string LisReportName        = "LIS Report";
    private const string LisDateType          = "Collected";

    private static readonly Dictionary<string, string> DenialSheetNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Monthly Summary"] = "Denial Highlights - Monthly",
        ["Weekly Summary"]  = "Denial Highlights - Weekly",
    };

    private readonly LabSettings _labSettings;
    private readonly INorthWestProductionSummaryRepository _production;
    private readonly IAugustusProductionSummaryRepository _augProduction;
    private readonly IReadOnlyDictionary<string, ILabProductionSummaryRepository> _labProduction;
    private readonly ICollectionSummaryRepository _collection;
    private readonly ILisSummaryRepository _lis;
    private readonly IDenialClaimReportRepository _denial;
    private readonly INotesRepository _notes;
    private readonly LabConfigOptions? _labConfig;
    private readonly ILogger<ExecutiveSummaryHighlightsExcel> _logger;

    public ExecutiveSummaryHighlightsExcel(
        LabSettings labSettings,
        INorthWestProductionSummaryRepository production,
        IAugustusProductionSummaryRepository augProduction,
        IReadOnlyDictionary<string, ILabProductionSummaryRepository> labProduction,
        ICollectionSummaryRepository collection,
        ILisSummaryRepository lis,
        IDenialClaimReportRepository denial,
        INotesRepository notes,
        ILogger<ExecutiveSummaryHighlightsExcel> logger,
        LabConfigOptions? labConfig = null)
    {
        _labSettings   = labSettings;
        _production    = production;
        _augProduction = augProduction;
        _labProduction = labProduction;
        _collection    = collection;
        _lis           = lis;
        _denial        = denial;
        _notes         = notes;
        _labConfig     = labConfig;
        _logger        = logger;
    }

    /// <summary>Labs whose Executive Summary page shows the highlight tabs.</summary>
    public static bool AppliesTo(string? labName) =>
        LabCollectionPrefix.GetPrefix(labName) is "NW" or "Cove" or "AnP" or "Aug" or "WH" or "CB" or "TD";

    /// <summary>Labs among <see cref="AppliesTo"/> whose Denial Highlights tab is live.</summary>
    public static bool ShowsDenialHighlights(string? labName) =>
        LabCollectionPrefix.GetPrefix(labName) is "NW" or "Cove" or "AnP" or "Aug" or "WH" or "CB" or "TD";

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
            () => BuildProductionAsync(connStr, labName, config, ct));
        var collectionTask = TryBuildAsync("Collection Highlights", labName,
            () => BuildCollectionAsync(connStr, labName, config, ct));
        var lisTask = TryBuildAsync("LIMS Highlights", labName,
            () => BuildLisAsync(connStr, labName, ct));
        var denialTask = ShowsDenialHighlights(labName)
            ? TryBuildAsync("Denial Highlights", labName, () => BuildDenialAsync(connStr, labName, ct))
            : null;
        await Task.WhenAll(new[] { productionTask, collectionTask, lisTask, denialTask }.OfType<Task<XLWorkbook>>());

        using var target = new XLWorkbook(new MemoryStream(executiveSummaryXlsx));

        using (var production = productionTask.Result)
            CopySheets(production, target, "Production Highlights",
                name => name.Equals(InsightsExcelBuilder.SheetName, StringComparison.OrdinalIgnoreCase)
                    ? "Production Highlights" : null);

        using (var collection = collectionTask.Result)
            CopySheets(collection, target, "Collection Highlights",
                name => name.Equals(InsightsExcelBuilder.SheetName, StringComparison.OrdinalIgnoreCase)
                    ? "Collection Highlights" : null);

        using (var lis = lisTask.Result)
        {
            CopySheets(lis, target, "LIMS Highlights",
                name => name.Equals("LIS Summary", StringComparison.OrdinalIgnoreCase) ? "LIMS Highlights" : null);
            CopySheets(lis, target, "LIMS Key Insights",
                name => name.Equals(InsightsExcelBuilder.SheetName, StringComparison.OrdinalIgnoreCase)
                    ? "LIMS Key Insights" : null);
        }

        if (denialTask is not null)
        {
            using var denial = denialTask.Result;
            CopySheets(denial, target, "Denial Highlights",
                name => DenialSheetNames.GetValueOrDefault(name)
                    ?? (name.Equals(InsightsExcelBuilder.SheetName, StringComparison.OrdinalIgnoreCase)
                        ? "Denial Highlights" : null));
        }

        using var ms = new MemoryStream();
        target.SaveAs(ms);
        return ms.ToArray();
    }

    private async Task<XLWorkbook> BuildProductionAsync(
        string connStr, string labName, LabCsvConfig config, CancellationToken ct)
    {
        var isNorthWest = LabCollectionPrefix.IsNorthWest(labName);
        var isAugustus  = LabCollectionPrefix.IsAugustus(labName);
        ILabProductionSummaryRepository? labRepo = null;
        if (!isNorthWest && !isAugustus && !_labProduction.TryGetValue(labName, out labRepo))
            throw new InvalidOperationException($"No Production Summary repository is registered for '{labName}'.");

        var monthlyTask = isNorthWest
            ? _production.GetMonthlyAsync(connStr, null, null, null, null, null, null, null, null, ct)
            : isAugustus
                ? _augProduction.GetMonthlyAsync(connStr, null, null, null, null, null, null, null, null, ct)
                : labRepo!.GetMonthlyAsync(connStr, null, null, null, null, null, null, null, null, ct);
        var weeklyTask = isNorthWest
            ? _production.GetWeeklyAsync(connStr, null, null, null, null, null, null, null, null, ct)
            : isAugustus
                ? _augProduction.GetWeeklyAsync(connStr, null, null, null, null, null, null, null, null, ct)
                : labRepo!.GetWeeklyAsync(connStr, null, null, null, null, null, null, null, null, ct);
        await Task.WhenAll(monthlyTask, weeklyTask);
        var monthly = monthlyTask.Result;
        var weekly  = weeklyTask.Result;

        var vm = new ProductionReportViewModel
        {
            AvailableLabs              = _labSettings.Labs.Keys.OrderBy(x => x).ToList(),
            SelectedLab                = labName,
            ProductionSummaryRule      = config.ProductionSummary?.Rule,
            ProductionSummaryWeekRule  = config.ProductionSummary?.WeekRule,
            ProductionSummaryWeekRange = config.ProductionSummary?.WeekRange,
            Months                     = monthly.Months,
            Years                      = monthly.Years,
            PanelRows                  = monthly.PanelRows,
            GrandTotalByMonth          = monthly.GrandTotalByMonth,
            GrandTotalClaims           = monthly.GrandTotalClaims,
            GrandTotalCharges          = monthly.GrandTotalCharges,
            WeekColumns                = weekly.WeekColumns,
            WeeklyPanelRows            = weekly.PanelRows,
            WeeklyGrandTotalByWeek     = weekly.GrandTotalByWeek,
            WeeklyGrandTotalClaims     = weekly.GrandTotalClaims,
            WeeklyGrandTotalCharges    = weekly.GrandTotalCharges,
        };

        var wb = isNorthWest
            ? NorthWestProductionSummaryExcelExportBuilder.CreateHighlightsWorkbook(vm, labName)
            : ProductionReportExcelExportBuilder.CreateHighlightsWorkbook(vm, labName);
        await AppendInsightsAsync(wb, connStr, labName, ProductionReportName, ct);
        return wb;
    }

    private async Task<XLWorkbook> BuildCollectionAsync(
        string connStr, string labName, LabCsvConfig config, CancellationToken ct)
    {
        var showTotalPayments = !config.DisableShowTop5TotalPayments;
        var useLineEncounters = string.Equals(config.CollectionOutput, "table1", StringComparison.OrdinalIgnoreCase);
        var byDateBasis = LabCollectionPrefix.UsesAvgPaymentsByDateBasis(labName);
        var last3Months = !byDateBasis && LabCollectionPrefix.ShowsAvgPaymentsLast3Months(labName);

        // Same source as the unfiltered page: the {prefix}_CS_* snapshot tables where the page
        // reads them. NorthWest keeps the live reads its download has always used.
        var prefix = config.EnableCollectionSummaryReport ? LabCollectionPrefix.GetPrefix(labName) : null;
        var useAggregates = prefix is not null
            && !LabCollectionPrefix.IsNorthWest(labName)
            && !LabCollectionPrefix.UsesSpCollectionLogic(labName)
            && !LabCollectionPrefix.ReadsCollectionSpsLive(labName);

        var monthlyTask = useAggregates
            ? _collection.GetCollectionMonthlyVolumeFromAggregatesAsync(connStr, prefix!, ct)
            : _collection.GetCollectionMonthlyVolumeAsync(
                connStr, labName, useLineEncounters, null, null, null, null, null, null, null, null, ct);
        var weeklyTask = useAggregates
            ? _collection.GetCollectionWeeklyVolumeFromAggregatesAsync(connStr, prefix!, ct)
            : _collection.GetCollectionWeeklyVolumeAsync(
                connStr, useLineEncounters, null, null, null, null, null, null, null, null, labName, ct);
        var reimbursementTask = useAggregates
            ? _collection.GetTop5ReimbursementFromAggregatesAsync(connStr, prefix!, ct)
            : _collection.GetTop5ReimbursementAsync(
                connStr, null, null, null, null, null, null, null, null, labName, ct);
        var totalPaymentsTask = !showTotalPayments
            ? Task.FromResult(new Top5TotalPaymentsResult([]))
            : useAggregates
                ? _collection.GetTop5TotalPaymentsFromAggregatesAsync(connStr, prefix!, ct)
                : _collection.GetTop5TotalPaymentsAsync(
                    connStr, null, null, null, null, null, null, null, null, labName, ct);
        var avgDosTask = byDateBasis
            ? _collection.GetAvgPaymentsByDateBasisAsync(
                connStr, AvgPaymentsDateBasis.DateOfService,
                null, null, null, null, null, null, null, null, labName, ct)
            : Task.FromResult(new PanelAveragesResult([]));
        var avgPaymentsTask = byDateBasis
            ? _collection.GetAvgPaymentsByDateBasisAsync(
                connStr, AvgPaymentsDateBasis.CheckDate,
                null, null, null, null, null, null, null, null, labName, ct)
            : _collection.GetAvgPaymentsAsync(
                connStr, null, null, null, null, null, null, null, null, labName, ct, lastMonths: 6);
        var avgLast3Task = last3Months
            ? _collection.GetAvgPaymentsAsync(
                connStr, null, null, null, null, null, null, null, null, labName, ct, lastMonths: 3)
            : Task.FromResult(new PanelAveragesResult([]));
        await Task.WhenAll(monthlyTask, weeklyTask, reimbursementTask, totalPaymentsTask,
            avgDosTask, avgPaymentsTask, avgLast3Task);

        var vm = new CollectionSummaryViewModel
        {
            SelectedLab                = labName,
            MonthlyClaimVolume         = CollectionSummaryController.BuildCollectionMonthlyPivot(monthlyTask.Result),
            WeeklyClaimVolume          = CollectionSummaryController.BuildCollectionWeeklyPivot(weeklyTask.Result),
            UsesLineEncounters         = useLineEncounters,
            IsAggregateMode            = useAggregates,
            Top5Reimbursement          = reimbursementTask.Result.Rows,
            Top5TotalPayments          = totalPaymentsTask.Result.Rows,
            ShowTop5TotalPayments      = showTotalPayments,
            AvgPaymentsDos             = avgDosTask.Result,
            AvgPayments                = avgPaymentsTask.Result,
            AvgPaymentsLast3Months     = avgLast3Task.Result,
            ShowAvgPaymentsByDateBasis = byDateBasis,
        };

        var wb = CollectionSummaryExcelExportBuilder.CreateHighlightsWorkbook(vm, labName);
        StackOntoInsightsSheet(wb);
        await AppendInsightsAsync(wb, connStr, labName, CollectionReportName, ct);
        return wb;
    }

    /// <summary>
    /// Moves every other sheet (Top 5 Insurances, Average Payments) onto the bottom of the
    /// Insights sheet, below Monthly &amp; Weekly, so the section is one sheet.
    /// </summary>
    private static void StackOntoInsightsSheet(XLWorkbook wb)
    {
        if (!wb.Worksheets.TryGetWorksheet(InsightsExcelBuilder.SheetName, out var target)) return;

        var stacked = wb.Worksheets.Where(w => w != target)
            .OrderBy(w => w.Name.Equals(CollectionSummaryExcelExportBuilder.Top5InsurancesSheetName, StringComparison.OrdinalIgnoreCase) ? 0
                        : w.Name.Equals("Avg payments_Last 3 Months", StringComparison.OrdinalIgnoreCase) ? 2 : 1)
            .ThenBy(w => w.Position)
            .ToList();
        foreach (var ws in stacked)
        {
            var used = ws.RangeUsed();
            if (used is not null)
            {
                var lastRow = used.LastRow().RowNumber();
                var lastCol = used.LastColumn().ColumnNumber();
                var startRow = (target.LastRowUsed()?.RowNumber() ?? 0) + 3;

                ws.Range(1, 1, lastRow, lastCol).CopyTo(target.Cell(startRow, 1));
                for (var r = 1; r <= lastRow; r++)
                    target.Row(startRow + r - 1).Height = ws.Row(r).Height;
                for (var c = 1; c <= lastCol; c++)
                    target.Column(c).Width = Math.Max(target.Column(c).Width, ws.Column(c).Width);
            }
            ws.Delete();
        }
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

    /// <summary>
    /// Monthly and Weekly Summary of the Denial Summary page: the lab's usp_Get{prefix}_Denial*
    /// SPs (NorthWest, Analyze Pathology, Augustus, WellHealth), else the inline ClaimLevelData summary (Cove).
    /// </summary>
    private async Task<XLWorkbook> BuildDenialAsync(string connStr, string labName, CancellationToken ct)
    {
        var weekStartsOn = _labConfig?.GetDenialSummaryWeekStart(labName) ?? SqlDenialClaimReportRepository.DefaultWeekStartsOn;
        var model = await DenialClaimReportExcelBuilder.LoadSummaryAsync(
            _denial, connStr, labName, weekStartsOn,
            _labConfig?.GetDenialSummaryDateColumn(labName),
            _labConfig?.GetDenialSummaryBalanceColumn(labName), ct);
        return DenialClaimReportExcelBuilder.BuildSummary(model);
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
}
