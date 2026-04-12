using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Dashboard Index data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces sheets: KPI Summary, Claim Status, Insights, Monthly Trends,
/// Avg Allowed by Panel, Top CPT Detail, and Pay Status.
/// </summary>
public static class DashboardExcelExportBuilder
{
    /// <summary>Creates the workbook from Dashboard view model data.</summary>
    public static XLWorkbook CreateWorkbook(DashboardViewModel vm, string labName)
    {
        var wb = new XLWorkbook();

        BuildKpiSheet(wb, vm, labName);
        BuildClaimStatusSheet(wb, vm.ClaimStatusRows);
        BuildInsightsSheet(wb, vm);
        BuildMonthlyTrendsSheet(wb, vm);
        BuildAvgAllowedSheet(wb, vm);
        BuildTopCptSheet(wb, vm.TopCptDetail);
        BuildPayStatusSheet(wb, vm.PayStatusBreakdown);

        WriteFilterFooter(wb, vm);

        return wb;
    }

    private static void WriteFilterFooter(XLWorkbook wb, DashboardViewModel vm)
    {
        var ws = wb.Worksheets.First();
        int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;

        var filters = new List<(string Label, string? Value)>
        {
            ("Payer Name", vm.FilterPayerName),
            ("Payer Type", vm.FilterPayerType),
            ("Panel Name", vm.FilterPanelName),
            ("Clinic Name", vm.FilterClinicName),
            ("Referring Provider", vm.FilterReferringProvider),
            ("DOS From", vm.FilterDosFrom),
            ("DOS To", vm.FilterDosTo),
            ("First Bill From", vm.FilterFirstBillFrom),
            ("First Bill To", vm.FilterFirstBillTo),
        };

        ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 3, filters);
    }

    // ?? KPI Summary sheet ???????????????????????????????????????????????

    private static void BuildKpiSheet(XLWorkbook wb, DashboardViewModel vm, string labName)
    {
        var ws = wb.AddWorksheet("KPI Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        ExcelTheme.WriteTitleBar(ws, 1, 3, $"Dashboard KPI Summary | {labName}");

        // Claim-level KPIs
        ExcelTheme.WriteSectionTitle(ws, 3, 1, 3, "Claim Level KPIs");
        ExcelTheme.WriteHeaderRow(ws, 4, 1, ["Metric", "Value", "Rate %"]);

        WriteKpiRow(ws, 5, "Total Claims", vm.TotalClaims, null, "#,##0");
        WriteKpiRow(ws, 6, "Total Charges", vm.TotalCharges, null, "$#,##0");
        WriteKpiRow(ws, 7, "Total Payments", vm.TotalPayments, null, "$#,##0");
        WriteKpiRow(ws, 8, "Total Balance", vm.TotalBalance, null, "$#,##0");
        WriteKpiRow(ws, 9, "Collection", vm.CollectionNumerator, vm.CollectionRate, "$#,##0");
        WriteKpiRow(ws, 10, "Denial", vm.DenialNumerator, vm.DenialRate, "$#,##0");
        WriteKpiRow(ws, 11, "Adjustment", vm.AdjustmentNumerator, vm.AdjustmentRate, "$#,##0");
        WriteKpiRow(ws, 12, "Outstanding", vm.OutstandingNumerator, vm.OutstandingRate, "$#,##0");

        // Line-level KPIs
        ExcelTheme.WriteSectionTitle(ws, 14, 1, 3, "Line Level KPIs");
        ExcelTheme.WriteHeaderRow(ws, 15, 1, ["Metric", "Value", "Rate %"]);

        WriteKpiRow(ws, 16, "Total Lines", vm.TotalLines, null, "#,##0");
        WriteKpiRow(ws, 17, "Line Total Charges", vm.LineTotalCharges, null, "$#,##0");
        WriteKpiRow(ws, 18, "Line Total Payments", vm.LineTotalPayments, null, "$#,##0");
        WriteKpiRow(ws, 19, "Line Total Balance", vm.LineTotalBalance, null, "$#,##0");
        WriteKpiRow(ws, 20, "Line Collection Rate", vm.LineTotalPayments, vm.LineCollectionRate, "$#,##0");

        // Payer Type Payments
        if (vm.PayerTypePayments.Count > 0)
        {
            int startRow = 22;
            ExcelTheme.WriteSectionTitle(ws, startRow, 1, 3, "Payer Type Payments");
            ExcelTheme.WriteHeaderRow(ws, startRow + 1, 1, ["Payer Type", "Total Payments", ""]);

            int r = startRow + 2;
            foreach (var kvp in vm.PayerTypePayments.OrderByDescending(x => x.Value))
            {
                var bg = ExcelTheme.GetRowBg(r - startRow - 2);
                ws.Cell(r, 1).Value = kvp.Key;
                ws.Cell(r, 2).Value = kvp.Value;
                ws.Cell(r, 2).Style.NumberFormat.Format = "$#,##0";
                for (int c = 1; c <= 3; c++)
                    ExcelTheme.StyleDataCell(ws.Cell(r, c), bg);
                r++;
            }
        }

        ws.SheetView.FreezeRows(1);
        ExcelTheme.AutoFitColumns(ws, 3, minWidth: 18, firstColMinWidth: 28);
    }

    private static void WriteKpiRow(IXLWorksheet ws, int row, string label, decimal value,
        decimal? rate, string format)
    {
        int idx = row - 5; // approximate row index for banding
        var bg = ExcelTheme.GetRowBg(idx);

        ws.Cell(row, 1).Value = label;
        ws.Cell(row, 2).Value = value;
        ws.Cell(row, 2).Style.NumberFormat.Format = format;

        if (rate.HasValue)
        {
            ws.Cell(row, 3).Value = rate.Value;
            ws.Cell(row, 3).Style.NumberFormat.Format = "0.0\"%\"";
        }

        for (int c = 1; c <= 3; c++)
            ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
    }

    private static void WriteKpiRow(IXLWorksheet ws, int row, string label, int value,
        decimal? rate, string format)
    {
        int idx = row - 5;
        var bg = ExcelTheme.GetRowBg(idx);

        ws.Cell(row, 1).Value = label;
        ws.Cell(row, 2).Value = value;
        ws.Cell(row, 2).Style.NumberFormat.Format = format;

        if (rate.HasValue)
        {
            ws.Cell(row, 3).Value = rate.Value;
            ws.Cell(row, 3).Style.NumberFormat.Format = "0.0\"%\"";
        }

        for (int c = 1; c <= 3; c++)
            ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
    }

    // ?? Claim Status Breakdown sheet ????????????????????????????????????

    private static void BuildClaimStatusSheet(XLWorkbook wb, IReadOnlyList<ClaimStatusRow> rows)
    {
        var ws = wb.AddWorksheet("Claim Status");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Status", "Claims", "Charges", "Payments", "Balance", "Collection %"];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Claim Status Breakdown");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var item = rows[r];

            ws.Cell(rowNum, 1).Value = item.Status;
            ws.Cell(rowNum, 2).Value = item.Claims;
            ws.Cell(rowNum, 3).Value = item.Charges;
            ws.Cell(rowNum, 4).Value = item.Payments;
            ws.Cell(rowNum, 5).Value = item.Balance;
            ws.Cell(rowNum, 6).Value = item.CollectionRate;

            ws.Cell(rowNum, 2).Style.NumberFormat.Format = "#,##0";
            ws.Cell(rowNum, 3).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 5).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 6).Style.NumberFormat.Format = "0.0\"%\"";

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 16, firstColMinWidth: 28);
    }

    // ?? Insights sheet ??????????????????????????????????????????????????

    private static void BuildInsightsSheet(XLWorkbook wb, DashboardViewModel vm)
    {
        var ws = wb.AddWorksheet("Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        int currentRow = 1;
        currentRow = WriteInsightSection(ws, currentRow, "Payer Level Insights", vm.PayerLevelInsights);
        currentRow += 2;
        currentRow = WriteInsightSection(ws, currentRow, "Panel Level Insights", vm.PanelLevelInsights);
        currentRow += 2;
        currentRow = WriteInsightSection(ws, currentRow, "Clinic Level Insights", vm.ClinicLevelInsights);
        currentRow += 2;
        WriteInsightSection(ws, currentRow, "Referring Physician Insights", vm.ReferringPhysicianInsights);

        ExcelTheme.AutoFitColumns(ws, 6, minWidth: 16, firstColMinWidth: 34);
    }

    private static int WriteInsightSection(IXLWorksheet ws, int startRow, string title,
        IReadOnlyList<InsightRow> items)
    {
        ExcelTheme.WriteSectionTitle(ws, startRow, 1, 6, title);

        int headerRow = startRow + 1;
        ExcelTheme.WriteHeaderRow(ws, headerRow, 1,
            ["Name", "Claims", "Charges", "Payments", "Balance", "Collection %"]);

        for (int r = 0; r < items.Count; r++)
        {
            int rowNum = headerRow + 1 + r;
            var bg = ExcelTheme.GetRowBg(r);
            var item = items[r];

            ws.Cell(rowNum, 1).Value = item.Label;
            ws.Cell(rowNum, 2).Value = item.Claims;
            ws.Cell(rowNum, 3).Value = item.Charges;
            ws.Cell(rowNum, 4).Value = item.Payments;
            ws.Cell(rowNum, 5).Value = item.Balance;
            ws.Cell(rowNum, 6).Value = item.CollectionRate;

            ws.Cell(rowNum, 2).Style.NumberFormat.Format = "#,##0";
            ws.Cell(rowNum, 3).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 5).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 6).Style.NumberFormat.Format = "0.0\"%\"";

            for (int c = 1; c <= 6; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        return headerRow + 1 + items.Count;
    }

    // ?? Monthly Trends sheet ????????????????????????????????????????????

    private static void BuildMonthlyTrendsSheet(XLWorkbook wb, DashboardViewModel vm)
    {
        var ws = wb.AddWorksheet("Monthly Trends");
        ws.TabColor = ExcelTheme.TabGold;
        ExcelTheme.ApplyDefaults(ws);

        int currentRow = 1;
        currentRow = WriteTrendSection(ws, currentRow, "Claims by Date of Service (Monthly)", vm.DOSMonthly);
        currentRow += 2;
        WriteTrendSection(ws, currentRow, "Claims by First Billed Date (Monthly)", vm.FirstBillMonthly);

        ExcelTheme.AutoFitColumns(ws, 2, minWidth: 16, firstColMinWidth: 20);
    }

    private static int WriteTrendSection(IXLWorksheet ws, int startRow, string title,
        IReadOnlyList<(string Month, int Count)> items)
    {
        ExcelTheme.WriteSectionTitle(ws, startRow, 1, 2, title);

        int headerRow = startRow + 1;
        ExcelTheme.WriteHeaderRow(ws, headerRow, 1, ["Month", "Claim Count"]);

        for (int r = 0; r < items.Count; r++)
        {
            int rowNum = headerRow + 1 + r;
            var bg = ExcelTheme.GetRowBg(r);

            ws.Cell(rowNum, 1).Value = items[r].Month;
            ws.Cell(rowNum, 2).Value = items[r].Count;
            ws.Cell(rowNum, 2).Style.NumberFormat.Format = "#,##0";

            ExcelTheme.StyleDataCell(ws.Cell(rowNum, 1), bg);
            ExcelTheme.StyleDataCell(ws.Cell(rowNum, 2), bg);
        }

        return headerRow + 1 + items.Count;
    }

    // ?? Avg Allowed by Panel x Month sheet ??????????????????????????????

    private static void BuildAvgAllowedSheet(XLWorkbook wb, DashboardViewModel vm)
    {
        if (vm.AvgAllowedMonths.Count == 0) return;

        var ws = wb.AddWorksheet("Avg Allowed by Panel");
        ws.TabColor = ExcelTheme.TabGold;
        ExcelTheme.ApplyDefaults(ws);

        int colCount = 1 + vm.AvgAllowedMonths.Count;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Average Allowed Amount by Panel × Month");

        string[] headers = ["Panel", .. vm.AvgAllowedMonths];
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);
        ws.Cell(2, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;

        for (int r = 0; r < vm.AvgAllowedByPanelMonth.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var row = vm.AvgAllowedByPanelMonth[r];

            ws.Cell(rowNum, 1).Value = row.PanelName;
            ExcelTheme.StyleDataCell(ws.Cell(rowNum, 1), bg);

            for (int m = 0; m < vm.AvgAllowedMonths.Count; m++)
            {
                var cell = ws.Cell(rowNum, m + 2);
                if (row.AvgByMonth.TryGetValue(vm.AvgAllowedMonths[m], out var val))
                    cell.Value = val;
                else
                    cell.Value = "-";
                cell.Style.NumberFormat.Format = "$#,##0";
                ExcelTheme.StyleDataCell(cell, bg);
            }
        }

        ws.SheetView.FreezeRows(2);
        ws.SheetView.FreezeColumns(1);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 30);
    }

    // ?? Top CPT Detail sheet ????????????????????????????????????????????

    private static void BuildTopCptSheet(XLWorkbook wb, IReadOnlyList<CptDetailRow> rows)
    {
        if (rows.Count == 0) return;

        var ws = wb.AddWorksheet("Top CPT Detail");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["CPT Code", "Charges", "Allowed Amount", "Ins. Balance",
            "Collection %", "Denial %", "No Response %"];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Top CPT by Charges (Enriched)");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var item = rows[r];

            ws.Cell(rowNum, 1).Value = item.CPTCode;
            ws.Cell(rowNum, 2).Value = item.Charges;
            ws.Cell(rowNum, 3).Value = item.AllowedAmount;
            ws.Cell(rowNum, 4).Value = item.InsuranceBalance;
            ws.Cell(rowNum, 5).Value = item.CollectionRate;
            ws.Cell(rowNum, 6).Value = item.DenialRate;
            ws.Cell(rowNum, 7).Value = item.NoResponseRate;

            ws.Cell(rowNum, 2).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 3).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 4).Style.NumberFormat.Format = "$#,##0";
            ws.Cell(rowNum, 5).Style.NumberFormat.Format = "0.0\"%\"";
            ws.Cell(rowNum, 6).Style.NumberFormat.Format = "0.0\"%\"";
            ws.Cell(rowNum, 7).Style.NumberFormat.Format = "0.0\"%\"";

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 16, firstColMinWidth: 16);
    }

    // ?? Pay Status Breakdown sheet ??????????????????????????????????????

    private static void BuildPayStatusSheet(XLWorkbook wb, IReadOnlyDictionary<string, int> breakdown)
    {
        if (breakdown.Count == 0) return;

        var ws = wb.AddWorksheet("Pay Status");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        ExcelTheme.WriteTitleBar(ws, 1, 2, "Line-Level Pay Status Breakdown");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, ["Pay Status", "Count"]);

        int r = 0;
        foreach (var kvp in breakdown.OrderByDescending(x => x.Value))
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);

            ws.Cell(rowNum, 1).Value = kvp.Key;
            ws.Cell(rowNum, 2).Value = kvp.Value;
            ws.Cell(rowNum, 2).Style.NumberFormat.Format = "#,##0";

            ExcelTheme.StyleDataCell(ws.Cell(rowNum, 1), bg);
            ExcelTheme.StyleDataCell(ws.Cell(rowNum, 2), bg);
            r++;
        }

        ExcelTheme.AutoFitColumns(ws, 2, minWidth: 16, firstColMinWidth: 28);
    }
}
