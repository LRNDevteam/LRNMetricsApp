using ClosedXML.Excel;
using ClosedXML.Excel;
using LRN.ProductionReports.Models;

namespace LRN.ProductionReports.Services;

/// <summary>
/// Builds Collection Summary Excel workbooks from shared Collection Summary result models.
/// </summary>
public static class CollectionSummaryExcelExportBuilder
{
    /// <summary>
    /// Creates a workbook containing the Collection Summary Monthly Claim Volume and
    /// Weekly Claim Volume tabs for any lab. Works for all labs whose SPs return the
    /// standard column set.
    /// </summary>
    public static XLWorkbook CreateWorkbook(
        CollectionSummaryMonthlyClaimVolumeResult monthly,
        CollectionSummaryWeeklyClaimVolumeResult weekly,
        string labName)
        => CreateNorthWestWorkbook(monthly, weekly, labName);

    /// <summary>Kept for backward compatibility. Use <see cref="CreateWorkbook"/> instead.</summary>
    public static XLWorkbook CreateNorthWestWorkbook(
        CollectionSummaryMonthlyClaimVolumeResult monthly,
        CollectionSummaryWeeklyClaimVolumeResult weekly,
        string labName)
    {
        ArgumentNullException.ThrowIfNull(monthly);
        ArgumentNullException.ThrowIfNull(weekly);
        ArgumentException.ThrowIfNullOrWhiteSpace(labName);

        var workbook = new XLWorkbook();
        AddMonthlyClaimVolumeSheet(workbook, monthly, labName);
        AddWeeklyClaimVolumeSheet(workbook, weekly, labName);
        return workbook;
    }

    private static void AddMonthlyClaimVolumeSheet(
        XLWorkbook workbook,
        CollectionSummaryMonthlyClaimVolumeResult result,
        string labName)
    {
        if (!result.HasData) return;

        var worksheet = workbook.Worksheets.Add("Monthly Claim Volume");
        var years = result.Years.Where(y => y > 1900).ToList();
        var periodsByYear = result.Periods
            .Where(p => p.Year > 1900)
            .GroupBy(p => p.Year)
            .ToDictionary(g => g.Key, g => g.OrderBy(p => p.Month).ToList());

        var colCount = 2 + years.Sum(y => periodsByYear.GetValueOrDefault(y, []).Count * 3 + 3) + 3;
        WriteTitle(worksheet, 1, colCount, $"Monthly Claim Volume - {labName}");

        var headerRow = 2;
        worksheet.Cell(headerRow, 1).Value = "#";
        worksheet.Cell(headerRow, 2).Value = "Panel / Insurance";
        worksheet.Range(headerRow, 1, headerRow + 1, 1).Merge();
        worksheet.Range(headerRow, 2, headerRow + 1, 2).Merge();

        var col = 3;
        foreach (var year in years)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            var span = months.Count * 3 + 3;
            worksheet.Range(headerRow, col, headerRow, col + span - 1).Merge().Value = year;
            foreach (var month in months)
            {
                worksheet.Range(headerRow + 1, col, headerRow + 1, col + 2).Merge().Value = month.Label;
                col += 3;
            }
            worksheet.Range(headerRow + 1, col, headerRow + 1, col + 2).Merge().Value = $"{year} Total";
            col += 3;
        }
        worksheet.Range(headerRow, col, headerRow, col + 2).Merge().Value = "Grand Total";

        WriteMetricHeaders(worksheet, headerRow + 2, 3, years.SelectMany(y => periodsByYear.GetValueOrDefault(y, [])).Count() + years.Count + 1);
        StyleHeader(worksheet.Range(headerRow, 1, headerRow + 2, col + 2));

        var row = headerRow + 3;
        var panelIndex = 0;
        foreach (var panel in result.PanelRows)
        {
            panelIndex++;
            WriteMonthlyRow(worksheet, row++, panelIndex <= 26 ? ((char)('A' + panelIndex - 1)).ToString() : panelIndex.ToString(), panel.PanelName, panel.ByMonth, panel.ByYear, panel.TotalClaimCount, panel.TotalPaid, years, periodsByYear, true);

            foreach (var payer in panel.Payers.Where(p => p.PayerRank <= 3))
                WriteMonthlyRow(worksheet, row++, payer.PayerRank.ToString(), payer.PayerName, payer.ByMonth, payer.ByYear, payer.TotalClaimCount, payer.TotalPaid, years, periodsByYear, false);
        }

        WriteMonthlyRow(worksheet, row, string.Empty, "Grand Total", result.GrandTotalByMonth, result.GrandTotalByYear, result.GrandTotalClaimCount, result.GrandTotalPaid, years, periodsByYear, true);
        StyleBody(worksheet.Range(4, 1, row, col + 2));
        // Index-based: Columns().AdjustToContents() can throw "Collection was modified".
        var lastMonthlyCol = worksheet.LastColumnUsed()?.ColumnNumber() ?? 1;
        for (int c = 1; c <= lastMonthlyCol; c++)
            worksheet.Column(c).AdjustToContents();
        worksheet.SheetView.FreezeRows(4);
    }

    private static void AddWeeklyClaimVolumeSheet(XLWorkbook workbook, CollectionSummaryWeeklyClaimVolumeResult result, string labName)
    {
        if (!result.HasData) return;

        var worksheet = workbook.Worksheets.Add("Weekly Claim Volume");
        var colCount = 2 + result.Weeks.Count * 3 + 3;
        WriteTitle(worksheet, 1, colCount, $"Weekly Claim Volume - {labName}");

        var headerRow = 2;
        worksheet.Cell(headerRow, 1).Value = "#";
        worksheet.Cell(headerRow, 2).Value = "Panel / Insurance";
        worksheet.Range(headerRow, 1, headerRow + 1, 1).Merge();
        worksheet.Range(headerRow, 2, headerRow + 1, 2).Merge();

        var col = 3;
        foreach (var week in result.Weeks)
        {
            worksheet.Range(headerRow, col, headerRow, col + 2).Merge().Value = week.Label;
            col += 3;
        }
        worksheet.Range(headerRow, col, headerRow, col + 2).Merge().Value = "Grand Total";
        WriteMetricHeaders(worksheet, headerRow + 1, 3, result.Weeks.Count + 1);
        StyleHeader(worksheet.Range(headerRow, 1, headerRow + 1, col + 2));

        var row = headerRow + 2;
        var panelIndex = 0;
        foreach (var panel in result.PanelRows)
        {
            panelIndex++;
            WriteWeeklyRow(worksheet, row++, panelIndex <= 26 ? ((char)('A' + panelIndex - 1)).ToString() : panelIndex.ToString(), panel.PanelName, panel.ByWeek, panel.TotalClaimCount, panel.TotalPaid, result.Weeks, true);

            foreach (var payer in panel.Payers.Where(p => p.PayerRank <= 3))
                WriteWeeklyRow(worksheet, row++, payer.PayerRank.ToString(), payer.PayerName, payer.ByWeek, payer.TotalClaimCount, payer.TotalPaid, result.Weeks, false);
        }

        WriteWeeklyRow(worksheet, row, string.Empty, "Grand Total", result.GrandTotalByWeek, result.GrandTotalClaimCount, result.GrandTotalPaid, result.Weeks, true);
        StyleBody(worksheet.Range(4, 1, row, col + 2));
        // Index-based: Columns().AdjustToContents() can throw "Collection was modified".
        var lastWeeklyCol = worksheet.LastColumnUsed()?.ColumnNumber() ?? 1;
        for (int c = 1; c <= lastWeeklyCol; c++)
            worksheet.Column(c).AdjustToContents();
        worksheet.SheetView.FreezeRows(3);
    }

    private static void WriteMonthlyRow(
        IXLWorksheet worksheet,
        int row,
        string rank,
        string label,
        Dictionary<string, CollectionSummaryCell> byMonth,
        Dictionary<int, CollectionSummaryCell> byYear,
        int totalClaims,
        decimal totalPaid,
        List<int> years,
        Dictionary<int, List<CollectionSummaryMonthPeriod>> periodsByYear,
        bool bold)
    {
        var col = 1;
        worksheet.Cell(row, col++).Value = rank;
        worksheet.Cell(row, col++).Value = label;
        foreach (var year in years)
        {
            foreach (var period in periodsByYear.GetValueOrDefault(year, []))
            {
                WriteCellTriplet(worksheet, row, ref col, byMonth.GetValueOrDefault(period.Key));
            }
            WriteCellTriplet(worksheet, row, ref col, byYear.GetValueOrDefault(year));
        }
        WriteCellTriplet(worksheet, row, ref col, new CollectionSummaryCell(totalClaims, totalPaid));
        if (bold) worksheet.Row(row).Style.Font.Bold = true;
    }

    private static void WriteWeeklyRow(
        IXLWorksheet worksheet,
        int row,
        string rank,
        string label,
        Dictionary<string, CollectionSummaryCell> byWeek,
        int totalClaims,
        decimal totalPaid,
        List<CollectionSummaryWeekPeriod> weeks,
        bool bold)
    {
        var col = 1;
        worksheet.Cell(row, col++).Value = rank;
        worksheet.Cell(row, col++).Value = label;
        foreach (var week in weeks)
            WriteCellTriplet(worksheet, row, ref col, byWeek.GetValueOrDefault(week.Key));
        WriteCellTriplet(worksheet, row, ref col, new CollectionSummaryCell(totalClaims, totalPaid));
        if (bold) worksheet.Row(row).Style.Font.Bold = true;
    }

    private static void WriteCellTriplet(IXLWorksheet worksheet, int row, ref int col, CollectionSummaryCell? cell)
    {
        cell ??= new CollectionSummaryCell(0, 0m);
        worksheet.Cell(row, col++).Value = cell.ClaimCount;
        worksheet.Cell(row, col++).Value = cell.TotalPaid;
        worksheet.Cell(row, col++).Value = cell.AveragePaidAmount;
    }

    private static void WriteMetricHeaders(IXLWorksheet worksheet, int row, int startCol, int groups)
    {
        var col = startCol;
        for (var i = 0; i < groups; i++)
        {
            worksheet.Cell(row, col++).Value = "No. of Claims";
            worksheet.Cell(row, col++).Value = "Total Paid";
            worksheet.Cell(row, col++).Value = "Average Paid";
        }
    }

    private static void WriteTitle(IXLWorksheet worksheet, int row, int colCount, string title)
    {
        worksheet.Range(row, 1, row, colCount).Merge().Value = title;
        var range = worksheet.Range(row, 1, row, colCount);
        range.Style.Fill.BackgroundColor = XLColor.FromHtml("#1F4E79");
        range.Style.Font.FontColor = XLColor.White;
        range.Style.Font.Bold = true;
        range.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
    }

    private static void StyleHeader(IXLRange range)
    {
        range.Style.Fill.BackgroundColor = XLColor.FromHtml("#D9EAF7");
        range.Style.Font.Bold = true;
        range.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
    }

    private static void StyleBody(IXLRange range)
    {
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        range.Style.NumberFormat.Format = "#,##0";
        foreach (var cell in range.CellsUsed(c => c.Address.ColumnNumber > 2 && c.Value.IsNumber))
        {
            var header = cell.Worksheet.Cell(3, cell.Address.ColumnNumber).GetString();
            if (header.Contains("Paid", StringComparison.OrdinalIgnoreCase))
                cell.Style.NumberFormat.Format = ExcelTheme.AccountingNumberFormat;
        }
    }
}
