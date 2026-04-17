using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Clinic Summary filtered data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces three sheets: Clinic Summary, Highly Collected, and Highly Denied.
/// </summary>
public static class ClinicSummaryExcelExportBuilder
{
    /// <summary>Creates the workbook with all sheets.</summary>
    public static XLWorkbook CreateWorkbook(
        IReadOnlyList<ClinicSummaryRow> rows,
        ClinicSummaryRow? totals,
        IReadOnlyList<TopCollectedItem> topCollectedClinics,
        IReadOnlyList<TopCollectedItem> topCollectedSalesReps,
        IReadOnlyList<TopCollectedItem> topCollectedPayers,
        IReadOnlyList<TopCollectedItem> topCollectedPanels,
        IReadOnlyList<TopDeniedItem> topDeniedClinics,
        IReadOnlyList<TopDeniedItem> topDeniedSalesReps,
        IReadOnlyList<TopDeniedItem> topDeniedPayers,
        IReadOnlyList<TopDeniedItem> topDeniedPanels,
        string labName,
        ClinicPanelStatusViewModel? panelStatus = null,
        ClinicDollarAnalysisViewModel? dollarAnalysis = null,
        ClinicDosCountViewModel? dosCount = null,
        IReadOnlyList<(string Label, IReadOnlyList<string>? Values)>? activeFilters = null)
    {
        var wb = new XLWorkbook();

        BuildClinicSummarySheet(wb, rows, totals, labName);
        BuildHighlyCollectedSheet(wb, topCollectedClinics, topCollectedSalesReps,
            topCollectedPayers, topCollectedPanels);
        BuildHighlyDeniedSheet(wb, topDeniedClinics, topDeniedSalesReps,
            topDeniedPayers, topDeniedPanels);

        if (panelStatus is { Clinics.Count: > 0 })
            BuildPanelStatusSheet(wb, panelStatus);

        if (dollarAnalysis is { Clinics.Count: > 0 })
            BuildDollarAnalysisSheet(wb, dollarAnalysis);

        if (dosCount is { Clinics.Count: > 0 })
            BuildDosCountSheet(wb, dosCount);

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 22, activeFilters);
        }

        return wb;
    }

    // ?? Clinic Summary sheet ?????????????????????????????????????????????

    private static void BuildClinicSummarySheet(
        XLWorkbook wb,
        IReadOnlyList<ClinicSummaryRow> rows,
        ClinicSummaryRow? totals,
        string labName)
    {
        var ws = wb.AddWorksheet("Clinic Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Clinic Name",
            "Billed Claim Count", "Paid Claim Count", "Denied Claim Count", "Outstanding Claim Count",
            "Total Billed Charges", "Total Billed Charge on Paid Claim", "Total Allowed Amount",
            "Total Insurance Paid Amount", "Total Patient Responsibility",
            "Total Denied Charges", "Total Outstanding Charges",
            "Average Allowed Amount", "Average Insurance Paid Amount",
            "Average Payment %", "Denied Claim %", "Outstanding Claim %",
            "Denied Charges %", "Outstanding Charges %",
            "Allowed on Billed %", "Paid on Allowed %", "Paid Claim %"
        ];

        int colCount = headers.Length;

        // Column group indices (0-based)
        var countCols = new HashSet<int> { 1, 2, 3, 4 };
        var moneyCols = new HashSet<int> { 5, 6, 7, 8, 9, 10, 11 };
        var avgCols   = new HashSet<int> { 12, 13 };
        var pctCols   = new HashSet<int> { 14, 15, 16, 17, 18, 19, 20, 21 };

        // Row 1 — title bar
        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"Clinic Summary | {labName}");

        // Row 2 — column headers (all use the same dark-green header)
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);
        // First column left-aligned
        ws.Cell(2, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;

        ws.SheetView.FreezeRows(2);
        ws.Row(1).Height = 28;
        ws.Row(2).Height = 32;

        // Data rows
        for (int r = 0; r < rows.Count; r++)
        {
            WriteClinicRow(ws, r + 3, rows[r], r, countCols, moneyCols, avgCols, pctCols);
        }

        // Grand Total row
        if (totals is not null)
        {
            int totalRow = rows.Count + 3;
            WriteClinicRow(ws, totalRow, totals, -1, countCols, moneyCols, avgCols, pctCols);
            ExcelTheme.StyleTotalRow(ws, totalRow, 1, colCount);
            ws.Cell(totalRow, 1).Value = "Total";
        }

        // Number formats (applied to columns below the header rows)
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

        // Conditional formatting — "higher is better" pct columns
        int lastDataRow = rows.Count + 2 + (totals is not null ? 1 : 0);
        foreach (int c in new[] { 19, 20, 21 })
        {
            var range = ws.Range(3, c + 1, lastDataRow, c + 1);
            range.AddConditionalFormat().WhenGreaterThan(80)
                .Fill.SetBackgroundColor(ExcelTheme.GoodBg).Font.SetFontColor(ExcelTheme.GoodFg);
            range.AddConditionalFormat().WhenBetween(30, 80)
                .Fill.SetBackgroundColor(ExcelTheme.NeutralBg).Font.SetFontColor(ExcelTheme.NeutralFg);
            range.AddConditionalFormat().WhenLessThan(30)
                .Fill.SetBackgroundColor(ExcelTheme.BadBg).Font.SetFontColor(ExcelTheme.BadFg);
        }

        // Conditional formatting — "lower is better" pct columns
        foreach (int c in new[] { 15, 16, 17, 18 })
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

    private static void WriteClinicRow(IXLWorksheet ws, int rowNum, ClinicSummaryRow row,
        int rowIndex, HashSet<int> countCols, HashSet<int> moneyCols,
        HashSet<int> avgCols, HashSet<int> pctCols)
    {
        bool isTotal = rowIndex < 0;
        var bg = isTotal ? ExcelTheme.TotalRowBg : ExcelTheme.GetRowBg(rowIndex);

        object[] values =
        [
            row.ClinicName,
            row.BilledClaimCount, row.PaidClaimCount, row.DeniedClaimCount, row.OutstandingClaimCount,
            row.TotalBilledCharges, row.TotalBilledChargeOnPaidClaim, row.TotalAllowedAmount,
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

    // ?? Highly Collected sheet ????????????????????????????????????????????

    private static void BuildHighlyCollectedSheet(
        XLWorkbook wb,
        IReadOnlyList<TopCollectedItem> clinics,
        IReadOnlyList<TopCollectedItem> salesReps,
        IReadOnlyList<TopCollectedItem> payers,
        IReadOnlyList<TopCollectedItem> panels)
    {
        var ws = wb.AddWorksheet("Highly Collected");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        int currentRow = 1;
        currentRow = WriteCollectedSection(ws, currentRow, "Top Collected \u2014 Clinics", clinics);
        currentRow += 2;
        currentRow = WriteCollectedSection(ws, currentRow, "Top Collected \u2014 Sales Reps", salesReps);
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
            var item = items[r];
            int rowNum = headerRow + 1 + r;
            var bg = ExcelTheme.GetRowBg(r);

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

    // ?? Highly Denied sheet ??????????????????????????????????????????????

    private static void BuildHighlyDeniedSheet(
        XLWorkbook wb,
        IReadOnlyList<TopDeniedItem> clinics,
        IReadOnlyList<TopDeniedItem> salesReps,
        IReadOnlyList<TopDeniedItem> payers,
        IReadOnlyList<TopDeniedItem> panels)
    {
        var ws = wb.AddWorksheet("Highly Denied");
        ws.TabColor = ExcelTheme.TabRed;
        ExcelTheme.ApplyDefaults(ws);

        int currentRow = 1;
        currentRow = WriteDeniedSection(ws, currentRow, "Top Denied \u2014 Clinics", clinics);
        currentRow += 2;
        currentRow = WriteDeniedSection(ws, currentRow, "Top Denied \u2014 Sales Reps", salesReps);
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
            var item = items[r];
            int rowNum = headerRow + 1 + r;
            var bg = ExcelTheme.GetRowBg(r);

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

    // ?? Clinic $ Analysis sheet ??????????????????????????????????????

    private static void BuildDollarAnalysisSheet(XLWorkbook wb, ClinicDollarAnalysisViewModel vm)
    {
        var ws = wb.AddWorksheet("Clinic $ Analysis");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        ExcelTheme.WriteHeaderRow(ws, 1, 1,
            ["Clinic Name", "Claim Status", "No. of Claims", "Total Charge", "Insurance Payments"]);

        int rowNum = 2;
        int idx = 0;
        foreach (var clinic in vm.Clinics)
        {
            // Clinic-level row (bold)
            var clinicBg = ExcelTheme.GetRowBg(idx++);
            ws.Cell(rowNum, 1).Value = clinic.ClinicName;
            ws.Cell(rowNum, 2).Value = "";
            ws.Cell(rowNum, 3).Value = clinic.ClaimCount;
            ws.Cell(rowNum, 4).Value = clinic.TotalCharge;
            ws.Cell(rowNum, 5).Value = clinic.InsurancePayment;
            for (int c = 1; c <= 5; c++)
            {
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), clinicBg);
                ws.Cell(rowNum, c).Style.Font.SetBold(true);
            }
            ws.Cell(rowNum, 3).Style.NumberFormat.Format = "#,##0";
            ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0.00";
            ws.Cell(rowNum, 5).Style.NumberFormat.Format = "$#,##0.00";
            rowNum++;

            // Status drill-down rows
            foreach (var status in clinic.Statuses)
            {
                var statusBg = ExcelTheme.GetRowBg(idx++);
                ws.Cell(rowNum, 1).Value = "";
                ws.Cell(rowNum, 2).Value = status.ClaimStatus;
                ws.Cell(rowNum, 3).Value = status.ClaimCount;
                ws.Cell(rowNum, 4).Value = status.TotalCharge;
                ws.Cell(rowNum, 5).Value = status.InsurancePayment;
                for (int c = 1; c <= 5; c++)
                    ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), statusBg);
                ws.Cell(rowNum, 3).Style.NumberFormat.Format = "#,##0";
                ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0.00";
                ws.Cell(rowNum, 5).Style.NumberFormat.Format = "$#,##0.00";
                rowNum++;
            }
        }

        // Grand Total
        ws.Cell(rowNum, 1).Value = "Grand Total";
        ws.Cell(rowNum, 3).Value = vm.GrandTotalClaims;
        ws.Cell(rowNum, 4).Value = vm.GrandTotalCharge;
        ws.Cell(rowNum, 5).Value = vm.GrandTotalInsurancePayment;
        for (int c = 1; c <= 5; c++)
        {
            ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), ExcelTheme.TotalRowBg);
            ws.Cell(rowNum, c).Style.Font.SetBold(true);
        }
        ws.Cell(rowNum, 3).Style.NumberFormat.Format = "#,##0";
        ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0.00";
        ws.Cell(rowNum, 5).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(1);
        ExcelTheme.AutoFitColumns(ws, 5, minWidth: 16, firstColMinWidth: 30);
    }

    // ?? Clinic Count by DOS Month sheet ??????????????????????????????

    private static void BuildDosCountSheet(XLWorkbook wb, ClinicDosCountViewModel vm)
    {
        var monthNames = new[] { "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

        var ws = wb.AddWorksheet("Count by DOS Month");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        // Row 1: Year headers spanning month columns
        int col = 2; // col 1 = Clinic Name
        var yearStartCol = new Dictionary<int, int>();
        foreach (var year in vm.Years)
        {
            yearStartCol[year] = col;
            var monthsInYear = vm.Columns.Count(c => c.Year == year);
            var yearCell = ws.Cell(1, col);
            yearCell.Value = year;
            if (monthsInYear > 1)
                ws.Range(1, col, 1, col + monthsInYear - 1).Merge();
            ExcelTheme.WriteHeaderRow(ws, 1, col, Enumerable.Repeat(year.ToString(), 1).ToArray());
            col += monthsInYear;
        }
        // Grand Total header in row 1
        var grandCol = col;
        ExcelTheme.WriteHeaderRow(ws, 1, grandCol, ["Grand Total"]);

        // Row 1 col 1 header
        ExcelTheme.WriteHeaderRow(ws, 1, 1, ["Clinic Name"]);

        // Row 2: Month sub-headers
        col = 2;
        foreach (var (year, month) in vm.Columns)
        {
            var cell = ws.Cell(2, col);
            cell.Value = monthNames[month];
            ExcelTheme.StyleDataCell(cell, ExcelTheme.TotalRowBg);
            cell.Style.Font.SetBold(true);
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            col++;
        }
        ws.Cell(2, grandCol).Value = "";
        ExcelTheme.StyleDataCell(ws.Cell(2, grandCol), ExcelTheme.TotalRowBg);

        // Data rows
        int rowNum = 3;
        for (int i = 0; i < vm.Clinics.Count; i++)
        {
            var clinic = vm.Clinics[i];
            var bg = ExcelTheme.GetRowBg(i);

            ws.Cell(rowNum, 1).Value = clinic.ClinicName;
            ExcelTheme.StyleDataCell(ws.Cell(rowNum, 1), bg);

            col = 2;
            foreach (var (year, month) in vm.Columns)
            {
                var key = ClinicDosCountViewModel.ColKey(year, month);
                var val = clinic.MonthCounts.GetValueOrDefault(key);
                var cell = ws.Cell(rowNum, col);
                cell.Value = val;
                cell.Style.NumberFormat.Format = "#,##0";
                ExcelTheme.StyleDataCell(cell, bg);
                col++;
            }

            ws.Cell(rowNum, grandCol).Value = clinic.GrandTotal;
            ws.Cell(rowNum, grandCol).Style.NumberFormat.Format = "#,##0";
            ExcelTheme.StyleDataCell(ws.Cell(rowNum, grandCol), bg);
            ws.Cell(rowNum, grandCol).Style.Font.SetBold(true);
            rowNum++;
        }

        // Grand Total footer
        ws.Cell(rowNum, 1).Value = "Grand Total";
        ExcelTheme.StyleDataCell(ws.Cell(rowNum, 1), ExcelTheme.TotalRowBg);
        ws.Cell(rowNum, 1).Style.Font.SetBold(true);

        col = 2;
        foreach (var (year, month) in vm.Columns)
        {
            var key = ClinicDosCountViewModel.ColKey(year, month);
            var val = vm.ColumnTotals.GetValueOrDefault(key);
            var cell = ws.Cell(rowNum, col);
            cell.Value = val;
            cell.Style.NumberFormat.Format = "#,##0";
            ExcelTheme.StyleDataCell(cell, ExcelTheme.TotalRowBg);
            cell.Style.Font.SetBold(true);
            col++;
        }

        ws.Cell(rowNum, grandCol).Value = vm.GrandTotal;
        ws.Cell(rowNum, grandCol).Style.NumberFormat.Format = "#,##0";
        ExcelTheme.StyleDataCell(ws.Cell(rowNum, grandCol), ExcelTheme.TotalRowBg);
        ws.Cell(rowNum, grandCol).Style.Font.SetBold(true);

        ws.SheetView.FreezeRows(2);
        ws.SheetView.FreezeColumns(1);
        ExcelTheme.AutoFitColumns(ws, grandCol, minWidth: 8, firstColMinWidth: 28);
    }

    // ?? Clinic Panel Status sheet ?????????????????????????????????????

    private static void BuildPanelStatusSheet(XLWorkbook wb, ClinicPanelStatusViewModel vm)
    {
        var ws = wb.AddWorksheet("Clinic Panel Status");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var statuses = vm.Statuses;
        int colCount = 2 + statuses.Count + 1; // Clinic, Panel, statuses..., Grand Total

        // Header row
        var headers = new List<string> { "Clinic Name", "Panel Name" };
        headers.AddRange(statuses);
        headers.Add("Grand Total");
        ExcelTheme.WriteHeaderRow(ws, 1, 1, headers.ToArray());

        int rowNum = 2;
        int idx = 0;
        foreach (var clinic in vm.Clinics)
        {
            // Clinic-level row (bold)
            var clinicBg = ExcelTheme.GetRowBg(idx++);
            ws.Cell(rowNum, 1).Value = clinic.ClinicName;
            ws.Cell(rowNum, 2).Value = "";
            for (int s = 0; s < statuses.Count; s++)
            {
                var val = clinic.StatusCounts.GetValueOrDefault(statuses[s]);
                ws.Cell(rowNum, 3 + s).Value = val;
                ws.Cell(rowNum, 3 + s).Style.NumberFormat.Format = "#,##0";
            }
            ws.Cell(rowNum, colCount).Value = clinic.GrandTotal;
            ws.Cell(rowNum, colCount).Style.NumberFormat.Format = "#,##0";
            for (int c = 1; c <= colCount; c++)
            {
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), clinicBg);
                ws.Cell(rowNum, c).Style.Font.SetBold(true);
            }
            rowNum++;

            // Panel drill-down rows
            foreach (var panel in clinic.Panels)
            {
                var panelBg = ExcelTheme.GetRowBg(idx++);
                ws.Cell(rowNum, 1).Value = "";
                ws.Cell(rowNum, 2).Value = panel.PanelName;
                for (int s = 0; s < statuses.Count; s++)
                {
                    var val = panel.StatusCounts.GetValueOrDefault(statuses[s]);
                    ws.Cell(rowNum, 3 + s).Value = val;
                    ws.Cell(rowNum, 3 + s).Style.NumberFormat.Format = "#,##0";
                }
                ws.Cell(rowNum, colCount).Value = panel.GrandTotal;
                ws.Cell(rowNum, colCount).Style.NumberFormat.Format = "#,##0";
                for (int c = 1; c <= colCount; c++)
                    ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), panelBg);
                rowNum++;
            }
        }

        // Grand Total footer
        ws.Cell(rowNum, 1).Value = "Grand Total";
        ws.Cell(rowNum, 2).Value = "";
        for (int s = 0; s < statuses.Count; s++)
        {
            var val = vm.GrandTotals.GetValueOrDefault(statuses[s]);
            ws.Cell(rowNum, 3 + s).Value = val;
            ws.Cell(rowNum, 3 + s).Style.NumberFormat.Format = "#,##0";
        }
        ws.Cell(rowNum, colCount).Value = vm.GrandTotalAll;
        ws.Cell(rowNum, colCount).Style.NumberFormat.Format = "#,##0";
        for (int c = 1; c <= colCount; c++)
        {
            ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), ExcelTheme.TotalRowBg);
            ws.Cell(rowNum, c).Style.Font.SetBold(true);
        }

        ws.SheetView.FreezeRows(1);
        ws.SheetView.FreezeColumns(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 12, firstColMinWidth: 30);
    }
}
