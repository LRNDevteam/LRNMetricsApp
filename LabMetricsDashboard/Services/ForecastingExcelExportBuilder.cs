using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Forecasting Summary data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces sheets: Median Summary and Mode Summary (weekly by payer).
/// </summary>
public static class ForecastingExcelExportBuilder
{
    /// <summary>Creates the workbook from the Forecasting Summary view model.</summary>
    public static XLWorkbook CreateWorkbook(ForecastingSummaryViewModel vm, string labName,
        IReadOnlyList<(string Label, string? Value)>? activeFilters = null)
    {
        var wb = new XLWorkbook();

        BuildWeeklySheet(wb, "Median Summary", vm.MedianSummary, labName);
        BuildWeeklySheet(wb, "Mode Summary", vm.ModeSummary, labName);

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 2, activeFilters);
        }

        return wb;
    }

    private static void BuildWeeklySheet(XLWorkbook wb, string sheetName,
        WeeklyForecastSummary summary, string labName)
    {
        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var weeks = summary.Weeks;
        // Columns: Payer | <per-week: Allowed, Paid> | Total Allowed | Total Paid
        int fixedCols = 1;
        int weekCols = weeks.Count * 2;
        int totalCols = 2;
        int colCount = fixedCols + weekCols + totalCols;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"{sheetName} — Last 4 Weeks | {labName}");

        // Header row 1 — Payer + week ranges merged + Total
        ws.Cell(2, 1).Value = "Payer";
        ws.Cell(2, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, 1).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(2, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Cell(2, 1).Style.Alignment.WrapText = true;

        for (int w = 0; w < weeks.Count; w++)
        {
            int startCol = fixedCols + w * 2 + 1;
            var range = ws.Range(2, startCol, 2, startCol + 1);
            range.Merge();
            var cell = ws.Cell(2, startCol);
            cell.Value = weeks[w].Label;
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // Total header
        int totalStartCol = fixedCols + weekCols + 1;
        var totalRange = ws.Range(2, totalStartCol, 2, totalStartCol + 1);
        totalRange.Merge();
        ws.Cell(2, totalStartCol).Value = "Total";
        ws.Cell(2, totalStartCol).Style.Font.Bold = true;
        ws.Cell(2, totalStartCol).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, totalStartCol).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(2, totalStartCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        // Header row 2 — sub-headers (Allowed / Paid)
        ws.Cell(3, 1).Value = "";
        ws.Cell(3, 1).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        for (int w = 0; w < weeks.Count; w++)
        {
            int sc = fixedCols + w * 2 + 1;
            ExcelTheme.WriteHeaderRow(ws, 3, sc, ["Allowed", "Paid"]);
        }
        ExcelTheme.WriteHeaderRow(ws, 3, totalStartCol, ["Allowed", "Paid"]);

        // Data rows
        int row = 4;
        for (int i = 0; i < summary.PayerRows.Count; i++)
        {
            var p = summary.PayerRows[i];
            var bg = ExcelTheme.GetRowBg(i);

            ws.Cell(row, 1).Value = p.PayerName;

            for (int w = 0; w < weeks.Count; w++)
            {
                int sc = fixedCols + w * 2 + 1;
                if (p.WeekAmounts.TryGetValue(weeks[w].Start, out var wa))
                {
                    ws.Cell(row, sc).Value = wa.ExpectedAllowed;
                    ws.Cell(row, sc + 1).Value = wa.ExpectedPaid;
                }
            }

            ws.Cell(row, totalStartCol).Value = p.TotalAllowed;
            ws.Cell(row, totalStartCol + 1).Value = p.TotalPaid;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
            row++;
        }

        // Totals row
        var t = summary.Totals;
        ExcelTheme.StyleTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Total";
        for (int w = 0; w < weeks.Count; w++)
        {
            int sc = fixedCols + w * 2 + 1;
            if (t.WeekAmounts.TryGetValue(weeks[w].Start, out var wa))
            {
                ws.Cell(row, sc).Value = wa.ExpectedAllowed;
                ws.Cell(row, sc + 1).Value = wa.ExpectedPaid;
            }
        }
        ws.Cell(row, totalStartCol).Value = t.TotalAllowed;
        ws.Cell(row, totalStartCol + 1).Value = t.TotalPaid;

        // Number formats for all money columns
        for (int c = 2; c <= colCount; c++)
            ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(3);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 28);
    }
}
