using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Sales Rep Summary filtered data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces three sheets: Sales Rep Summary, Highly Collected, and Highly Denied.
/// </summary>
public static class SalesRepSummaryExcelExportBuilder
{
    /// <summary>Creates the workbook with all sheets.</summary>
    public static XLWorkbook CreateWorkbook(
        IReadOnlyList<SalesRepSummaryRow> rows,
        SalesRepSummaryRow? totals,
        IReadOnlyList<TopCollectedItem> topCollectedSalesReps,
        IReadOnlyList<TopCollectedItem> topCollectedClinics,
        IReadOnlyList<TopCollectedItem> topCollectedPayers,
        IReadOnlyList<TopCollectedItem> topCollectedPanels,
        IReadOnlyList<TopDeniedItem> topDeniedSalesReps,
        IReadOnlyList<TopDeniedItem> topDeniedClinics,
        IReadOnlyList<TopDeniedItem> topDeniedPayers,
        IReadOnlyList<TopDeniedItem> topDeniedPanels,
        string labName,
        IReadOnlyList<(string Label, IReadOnlyList<string>? Values)>? activeFilters = null)
    {
        var wb = new XLWorkbook();

        BuildSalesRepSheet(wb, rows, totals, labName);
        BuildHighlyCollectedSheet(wb, topCollectedSalesReps, topCollectedClinics,
            topCollectedPayers, topCollectedPanels);
        BuildHighlyDeniedSheet(wb, topDeniedSalesReps, topDeniedClinics,
            topDeniedPayers, topDeniedPanels);

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 21, activeFilters);
        }

        return wb;
    }

    private static void BuildSalesRepSheet(
        XLWorkbook wb,
        IReadOnlyList<SalesRepSummaryRow> rows,
        SalesRepSummaryRow? totals,
        string labName)
    {
        var ws = wb.AddWorksheet("Sales Rep Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Sales Rep",
            "Billed Claim Count", "Paid Claim Count", "Denied Claim Count", "Outstanding Claim Count",
            "Total Billed Charges", "Total Allowed Amount",
            "Total Insurance Paid Amount", "Total Patient Responsibility",
            "Total Denied Charges", "Total Outstanding Charges",
            "Average Allowed Amount", "Average Insurance Paid Amount",
            "Average Payment %", "Denied Claim %", "Outstanding Claim %",
            "Denied Charges %", "Outstanding Charges %",
            "Allowed on Billed %", "Paid on Allowed %", "Paid Claim %"
        ];

        int colCount = headers.Length;

        var countCols = new HashSet<int> { 1, 2, 3, 4 };
        var moneyCols = new HashSet<int> { 5, 6, 7, 8, 9, 10 };
        var avgCols   = new HashSet<int> { 11, 12 };
        var pctCols   = new HashSet<int> { 13, 14, 15, 16, 17, 18, 19, 20 };

        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"Sales Rep Summary | {labName}");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);
        ws.Cell(2, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;

        ws.SheetView.FreezeRows(2);
        ws.Row(1).Height = 28;
        ws.Row(2).Height = 32;

        for (int r = 0; r < rows.Count; r++)
            WriteSalesRepRow(ws, r + 3, rows[r], r);

        if (totals is not null)
        {
            int totalRow = rows.Count + 3;
            WriteSalesRepRow(ws, totalRow, totals, -1);
            ExcelTheme.StyleTotalRow(ws, totalRow, 1, colCount);
            ws.Cell(totalRow, 1).Value = "Total";
        }

        for (int c = 0; c < colCount; c++)
        {
            var col = ws.Column(c + 1);
            if (moneyCols.Contains(c) || avgCols.Contains(c))
                col.Style.NumberFormat.Format = "$#,##0";
            else if (pctCols.Contains(c))
                col.Style.NumberFormat.Format = "0\"%\"";
            else if (countCols.Contains(c))
                col.Style.NumberFormat.Format = "#,##0";
        }

        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 15, firstColMinWidth: 30);

        // Conditional formatting — "higher is better"
        int lastDataRow = rows.Count + 2 + (totals is not null ? 1 : 0);
        foreach (int c in new[] { 18, 19, 20 })
        {
            var range = ws.Range(3, c + 1, lastDataRow, c + 1);
            range.AddConditionalFormat().WhenGreaterThan(80)
                .Fill.SetBackgroundColor(ExcelTheme.GoodBg).Font.SetFontColor(ExcelTheme.GoodFg);
            range.AddConditionalFormat().WhenBetween(30, 80)
                .Fill.SetBackgroundColor(ExcelTheme.NeutralBg).Font.SetFontColor(ExcelTheme.NeutralFg);
            range.AddConditionalFormat().WhenLessThan(30)
                .Fill.SetBackgroundColor(ExcelTheme.BadBg).Font.SetFontColor(ExcelTheme.BadFg);
        }

        // Conditional formatting — "lower is better"
        foreach (int c in new[] { 14, 15, 16, 17 })
        {
            var range = ws.Range(3, c + 1, lastDataRow, c + 1);
            range.AddConditionalFormat().WhenLessThan(30)
                .Fill.SetBackgroundColor(ExcelTheme.GoodBg).Font.SetFontColor(ExcelTheme.GoodFg);
            range.AddConditionalFormat().WhenBetween(30, 80)
                .Fill.SetBackgroundColor(ExcelTheme.NeutralBg).Font.SetFontColor(ExcelTheme.NeutralFg);
            range.AddConditionalFormat().WhenGreaterThan(80)
                .Fill.SetBackgroundColor(ExcelTheme.BadBg).Font.SetFontColor(ExcelTheme.BadFg);
        }
    }

    private static void WriteSalesRepRow(IXLWorksheet ws, int rowNum, SalesRepSummaryRow row, int rowIndex)
    {
        bool isTotal = rowIndex < 0;
        var bg = isTotal ? ExcelTheme.TotalRowBg : ExcelTheme.GetRowBg(rowIndex);

        object[] values =
        [
            row.SalesRepName,
            row.BilledClaimCount, row.PaidClaimCount, row.DeniedClaimCount, row.OutstandingClaimCount,
            row.TotalBilledCharges, row.TotalAllowedAmount,
            row.TotalInsurancePaidAmount, row.TotalPatientResponsibility,
            row.TotalDeniedCharges, row.TotalOutstandingCharges,
            row.AverageAllowedAmount, row.AverageInsurancePaidAmount,
            row.AveragePaymentPct, row.DeniedClaimPct, row.OutstandingClaimPct,
            row.DeniedChargesPct, row.OutstandingChargesPct,
            row.AllowedOnBilledPct, row.PaidOnAllowedPct, row.PaidClaimPct
        ];

        for (int c = 0; c < values.Length; c++)
        {
            var cell = ws.Cell(rowNum, c + 1);

            if (values[c] is string s)
                cell.Value = s;
            else if (values[c] is int i)
                cell.Value = i;
            else if (values[c] is decimal d)
                cell.Value = d;

            ExcelTheme.StyleDataCell(cell, bg);
            cell.Style.Alignment.Horizontal = c == 0
                ? XLAlignmentHorizontalValues.Left
                : XLAlignmentHorizontalValues.Right;
        }
    }

    private static void BuildHighlyCollectedSheet(
        XLWorkbook wb,
        IReadOnlyList<TopCollectedItem> salesReps,
        IReadOnlyList<TopCollectedItem> clinics,
        IReadOnlyList<TopCollectedItem> payers,
        IReadOnlyList<TopCollectedItem> panels)
    {
        var ws = wb.AddWorksheet("Highly Collected");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        int currentRow = 1;
        currentRow = WriteCollectedSection(ws, currentRow, "Top Collected \u2014 Sales Reps", salesReps);
        currentRow += 2;
        currentRow = WriteCollectedSection(ws, currentRow, "Top Collected \u2014 Clinics", clinics);
        currentRow += 2;
        currentRow = WriteCollectedSection(ws, currentRow, "Top Collected \u2014 Payers", payers);
        currentRow += 2;
        WriteCollectedSection(ws, currentRow, "Top Collected \u2014 Panels", panels);

        ExcelTheme.AutoFitColumns(ws, 5, minWidth: 16, firstColMinWidth: 34);
    }

    private static int WriteCollectedSection(IXLWorksheet ws, int startRow, string title,
        IReadOnlyList<TopCollectedItem> items)
    {
        ExcelTheme.WriteSectionTitle(ws, startRow, 1, 5, title);

        int headerRow = startRow + 1;
        ExcelTheme.WriteHeaderRow(ws, headerRow, 1,
            ["Name", "Claims", "Billed", "Ins. Paid", "Collection %"]);

        for (int r = 0; r < items.Count; r++)
        {
            int rowNum = headerRow + 1 + r;
            var bg = ExcelTheme.GetRowBg(r);
            var item = items[r];

            ws.Cell(rowNum, 1).Value = item.Name;
            ws.Cell(rowNum, 2).Value = item.ClaimCount;
            ws.Cell(rowNum, 3).Value = item.TotalBilledCharges;
            ws.Cell(rowNum, 4).Value = item.TotalInsurancePaid;
            ws.Cell(rowNum, 5).Value = item.CollectionPct;

            ws.Cell(rowNum, 2).Style.NumberFormat.Format = "#,##0";
            ws.Cell(rowNum, 3).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 5).Style.NumberFormat.Format = "0.0\"%\"";

            for (int c = 1; c <= 5; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        return headerRow + 1 + items.Count;
    }

    private static void BuildHighlyDeniedSheet(
        XLWorkbook wb,
        IReadOnlyList<TopDeniedItem> salesReps,
        IReadOnlyList<TopDeniedItem> clinics,
        IReadOnlyList<TopDeniedItem> payers,
        IReadOnlyList<TopDeniedItem> panels)
    {
        var ws = wb.AddWorksheet("Highly Denied");
        ws.TabColor = ExcelTheme.TabRed;
        ExcelTheme.ApplyDefaults(ws);

        int currentRow = 1;
        currentRow = WriteDeniedSection(ws, currentRow, "Top Denied \u2014 Sales Reps", salesReps);
        currentRow += 2;
        currentRow = WriteDeniedSection(ws, currentRow, "Top Denied \u2014 Clinics", clinics);
        currentRow += 2;
        currentRow = WriteDeniedSection(ws, currentRow, "Top Denied \u2014 Payers", payers);
        currentRow += 2;
        WriteDeniedSection(ws, currentRow, "Top Denied \u2014 Panels", panels);

        ExcelTheme.AutoFitColumns(ws, 5, minWidth: 16, firstColMinWidth: 34);
    }

    private static int WriteDeniedSection(IXLWorksheet ws, int startRow, string title,
        IReadOnlyList<TopDeniedItem> items)
    {
        ExcelTheme.WriteSectionTitle(ws, startRow, 1, 5, title, ExcelTheme.TabRed);

        int headerRow = startRow + 1;
        ExcelTheme.WriteHeaderRow(ws, headerRow, 1,
            ["Name", "Denied Claims", "Billed", "Denied Charges", "Denial %"]);

        for (int r = 0; r < items.Count; r++)
        {
            int rowNum = headerRow + 1 + r;
            var bg = ExcelTheme.GetRowBg(r);
            var item = items[r];

            ws.Cell(rowNum, 1).Value = item.Name;
            ws.Cell(rowNum, 2).Value = item.DeniedClaimCount;
            ws.Cell(rowNum, 3).Value = item.TotalBilledCharges;
            ws.Cell(rowNum, 4).Value = item.TotalDeniedCharges;
            ws.Cell(rowNum, 5).Value = item.DenialPct;

            ws.Cell(rowNum, 2).Style.NumberFormat.Format = "#,##0";
            ws.Cell(rowNum, 3).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 5).Style.NumberFormat.Format = "0.0\"%\"";

            for (int c = 1; c <= 5; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        return headerRow + 1 + items.Count;
    }
}
