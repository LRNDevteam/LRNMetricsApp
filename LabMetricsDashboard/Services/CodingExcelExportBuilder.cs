using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Coding Summary data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces sheets: Financial Dashboard, YTD Insights, YTD Summary,
/// WTD Insights, WTD Summary, and Validation Detail.
/// </summary>
public static class CodingExcelExportBuilder
{
    /// <summary>Creates the workbook from the Coding Summary view model.</summary>
    public static XLWorkbook CreateWorkbook(CodingSummaryViewModel vm, string labName)
    {
        var wb = new XLWorkbook();

        if (vm.FinancialRows.Count > 0)
            BuildFinancialSheet(wb, vm.FinancialRows, labName);

        if (vm.InsightRows.Count > 0)
            BuildYtdInsightsSheet(wb, vm.InsightRows);

        if (vm.SummaryRows.Count > 0)
            BuildYtdSummarySheet(wb, vm.SummaryRows);

        if (vm.WtdInsightRows.Count > 0)
            BuildWtdInsightsSheet(wb, vm.WtdInsightRows);

        if (vm.WtdSummaryRows.Count > 0)
            BuildWtdSummarySheet(wb, vm.WtdSummaryRows);

        if (vm.DetailRows.Count > 0)
            BuildValidationDetailSheet(wb, vm.DetailRows);

        return wb;
    }

    // ?? Financial Dashboard sheet ???????????????????????????????????????

    private static void BuildFinancialSheet(XLWorkbook wb,
        List<CodingFinancialSummaryRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Financial Dashboard");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Week", "Report Date",
            "Total Claims", "Total Billed", "Expected Billed",
            "Rev Impact Claims", "Rev Impact Actual Billed", "Rev Impact Loss", "Rev Impact Recoup",
            "Rev Loss Claims", "Rev Loss Actual Billed", "Rev Loss Potential",
            "Rev at Risk Claims", "Rev at Risk Actual Billed", "Rev at Risk Recoup",
            "Compliance Claims", "Claims w/ Issues", "Compliance Rate",
            "Missing CPTs", "Additional CPTs", "Both Missing & Additional",
            "Total Error Claims", "Compliance Rate %"
        ];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"Coding Financial Dashboard | {labName}");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var f = rows[r];

            ws.Cell(rowNum, 1).Value = f.WeekFolder;
            ws.Cell(rowNum, 2).Value = f.ReportDate;
            ws.Cell(rowNum, 3).Value = f.TotalClaims;
            ws.Cell(rowNum, 4).Value = f.TotalBilledCharges;
            ws.Cell(rowNum, 5).Value = f.ExpectedBilledCharges;
            if (f.RevenueImpact_Claims.HasValue) ws.Cell(rowNum, 6).Value = f.RevenueImpact_Claims.Value;
            ws.Cell(rowNum, 7).Value = f.RevenueImpact_ActualBilled;
            ws.Cell(rowNum, 8).Value = f.RevenueImpact_PotentialLoss;
            ws.Cell(rowNum, 9).Value = f.RevenueImpact_ExpectedRecoup;
            if (f.RevenueLoss_Claims.HasValue) ws.Cell(rowNum, 10).Value = f.RevenueLoss_Claims.Value;
            ws.Cell(rowNum, 11).Value = f.RevenueLoss_ActualBilled;
            ws.Cell(rowNum, 12).Value = f.RevenueLoss_PotentialLoss;
            if (f.RevenueAtRisk_Claims.HasValue) ws.Cell(rowNum, 13).Value = f.RevenueAtRisk_Claims.Value;
            ws.Cell(rowNum, 14).Value = f.RevenueAtRisk_ActualBilled;
            ws.Cell(rowNum, 15).Value = f.RevenueAtRisk_PotentialRecoup;
            if (f.Compliance_TotalClaims.HasValue) ws.Cell(rowNum, 16).Value = f.Compliance_TotalClaims.Value;
            if (f.Compliance_ClaimsWithIssues.HasValue) ws.Cell(rowNum, 17).Value = f.Compliance_ClaimsWithIssues.Value;
            ws.Cell(rowNum, 18).Value = f.ComplianceRate;
            if (f.ClaimsWithMissingCPTs.HasValue) ws.Cell(rowNum, 19).Value = f.ClaimsWithMissingCPTs.Value;
            if (f.ClaimsWithAdditionalCPTs.HasValue) ws.Cell(rowNum, 20).Value = f.ClaimsWithAdditionalCPTs.Value;
            if (f.ClaimsWithBothMissingAndAdditional.HasValue) ws.Cell(rowNum, 21).Value = f.ClaimsWithBothMissingAndAdditional.Value;
            if (f.TotalErrorClaims.HasValue) ws.Cell(rowNum, 22).Value = f.TotalErrorClaims.Value;
            ws.Cell(rowNum, 23).Value = f.ComplianceRatePct;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        // Number formats
        var countCols = new[] { 3, 6, 10, 13, 16, 17, 19, 20, 21, 22 };
        var moneyCols = new[] { 4, 5, 7, 8, 9, 11, 12, 14, 15 };
        foreach (int c in countCols) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        foreach (int c in moneyCols) ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 16);
    }

    // ?? YTD Insights sheet ??????????????????????????????????????????????

    private static void BuildYtdInsightsSheet(XLWorkbook wb, List<CodingInsightRow> rows)
    {
        var ws = wb.AddWorksheet("YTD Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Year", "Panel Name", "Billable CPT Combo", "Total Claims",
            "Billed Charges/Claim", "Billed CPT Combo", "Missing CPTs",
            "Billed Charges (Missing)", "Lost Revenue",
            "Additional CPTs", "Billed Charges (Additional)", "Revenue at Risk", "Net Impact"
        ];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "YTD Coding Insights");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var i = rows[r];

            ws.Cell(rowNum, 1).Value = i.Year;
            ws.Cell(rowNum, 2).Value = i.PanelName;
            ws.Cell(rowNum, 3).Value = i.BillableCptCombo;
            ws.Cell(rowNum, 4).Value = i.TotalClaims;
            ws.Cell(rowNum, 5).Value = i.BilledChargesPerClaim;
            ws.Cell(rowNum, 6).Value = i.BilledCptCombo;
            ws.Cell(rowNum, 7).Value = i.MissingCpts;
            ws.Cell(rowNum, 8).Value = i.TotalBilledChargesForMissingCpts;
            ws.Cell(rowNum, 9).Value = i.LostRevenue;
            ws.Cell(rowNum, 10).Value = i.AdditionalCpts;
            ws.Cell(rowNum, 11).Value = i.TotalBilledChargesForAdditionalCpts;
            ws.Cell(rowNum, 12).Value = i.RevenueAtRisk;
            ws.Cell(rowNum, 13).Value = i.NetImpact;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        ws.Column(4).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 5, 8, 9, 11, 12, 13 })
            ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 12);
    }

    // ?? YTD Summary sheet ???????????????????????????????????????????????

    private static void BuildYtdSummarySheet(XLWorkbook wb, List<CodingSummaryRow> rows)
    {
        var ws = wb.AddWorksheet("YTD Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Year", "Panel Name", "Billable CPT Combo", "Billed CPT Combo",
            "Missing CPTs", "Additional CPTs",
            "Total Claims", "Total Billed Charges",
            "Claims w/ Missing", "Billed Charges (Missing)",
            "Claims w/ Additional", "Billed Charges (Additional)",
            "Lost Revenue", "Revenue at Risk", "Net Impact"
        ];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "YTD Coding Summary");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var s = rows[r];

            ws.Cell(rowNum, 1).Value = s.Year;
            ws.Cell(rowNum, 2).Value = s.PanelName;
            ws.Cell(rowNum, 3).Value = s.BillableCptCombo;
            ws.Cell(rowNum, 4).Value = s.BilledCptCombo;
            ws.Cell(rowNum, 5).Value = s.MissingCpts;
            ws.Cell(rowNum, 6).Value = s.AdditionalCpts;
            ws.Cell(rowNum, 7).Value = s.TotalClaims;
            ws.Cell(rowNum, 8).Value = s.TotalBilledCharges;
            ws.Cell(rowNum, 9).Value = s.DistinctClaimsWithMissingCpts;
            ws.Cell(rowNum, 10).Value = s.TotalBilledChargesForMissingCpts;
            ws.Cell(rowNum, 11).Value = s.DistinctClaimsWithAdditionalCpts;
            ws.Cell(rowNum, 12).Value = s.TotalBilledChargesForAdditionalCpts;
            ws.Cell(rowNum, 13).Value = s.LostRevenue;
            ws.Cell(rowNum, 14).Value = s.RevenueAtRisk;
            ws.Cell(rowNum, 15).Value = s.NetImpact;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        foreach (int c in new[] { 7, 9, 11 }) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 8, 10, 12, 13, 14, 15 }) ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 12);
    }

    // ?? WTD Insights sheet ??????????????????????????????????????????????

    private static void BuildWtdInsightsSheet(XLWorkbook wb, List<CodingWtdInsightRow> rows)
    {
        var ws = wb.AddWorksheet("WTD Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Week", "Panel Name", "Billable CPT Combo", "Total Claims",
            "Total Billed Charges", "Billed CPT Combo", "Missing CPTs",
            "Billed Charges (Missing)", "Revenue Loss",
            "Additional CPTs", "Billed Charges (Additional)", "Potential Recoupment", "Net Impact"
        ];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "WTD Coding Insights");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var i = rows[r];

            ws.Cell(rowNum, 1).Value = i.WeekFolder;
            ws.Cell(rowNum, 2).Value = i.PanelName;
            ws.Cell(rowNum, 3).Value = i.BillableCptCombo;
            ws.Cell(rowNum, 4).Value = i.TotalClaims;
            ws.Cell(rowNum, 5).Value = i.TotalBilledCharges;
            ws.Cell(rowNum, 6).Value = i.BilledCptCombo;
            ws.Cell(rowNum, 7).Value = i.MissingCpts;
            ws.Cell(rowNum, 8).Value = i.BilledChargesForMissingCpts;
            ws.Cell(rowNum, 9).Value = i.RevenueLoss;
            ws.Cell(rowNum, 10).Value = i.AdditionalCpts;
            ws.Cell(rowNum, 11).Value = i.BilledChargesForAdditionalCpts;
            ws.Cell(rowNum, 12).Value = i.PotentialRecoupment;
            ws.Cell(rowNum, 13).Value = i.NetImpact;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        ws.Column(4).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 5, 8, 9, 11, 12, 13 })
            ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 16);
    }

    // ?? WTD Summary sheet ???????????????????????????????????????????????

    private static void BuildWtdSummarySheet(XLWorkbook wb, List<CodingWtdSummaryRow> rows)
    {
        var ws = wb.AddWorksheet("WTD Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Week", "Panel Name", "Billable CPT Combo", "Billed CPT Combo",
            "Missing CPTs", "Additional CPTs",
            "Total Claims", "Claims w/ Missing",
            "Billed Charges (Missing)", "Avg Allowed (Missing)"
        ];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "WTD Coding Summary");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var s = rows[r];

            ws.Cell(rowNum, 1).Value = s.WeekFolder;
            ws.Cell(rowNum, 2).Value = s.PanelName;
            ws.Cell(rowNum, 3).Value = s.BillableCptCombo;
            ws.Cell(rowNum, 4).Value = s.BilledCptCombo;
            ws.Cell(rowNum, 5).Value = s.MissingCpts;
            ws.Cell(rowNum, 6).Value = s.AdditionalCpts;
            ws.Cell(rowNum, 7).Value = s.TotalClaims;
            ws.Cell(rowNum, 8).Value = s.DistinctClaimsWithMissingCpts;
            ws.Cell(rowNum, 9).Value = s.TotalBilledChargesForMissingCpts;
            ws.Cell(rowNum, 10).Value = s.AvgAllowedAmountForMissingCpts;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        foreach (int c in new[] { 7, 8 }) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 9, 10 }) ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 16);
    }

    // ?? Validation Detail sheet ?????????????????????????????????????????

    private static void BuildValidationDetailSheet(XLWorkbook wb, List<CodingValidationDetailRow> rows)
    {
        var ws = wb.AddWorksheet("Validation Detail");
        ws.TabColor = ExcelTheme.TabGold;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Week", "Accession No", "Panel Name", "Date of Service",
            "Actual CPT", "Expected CPT", "Missing CPTs", "Additional CPTs",
            "Status", "Total Charge", "Missing CPT Charges", "Additional CPT Charges", "Remarks"
        ];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Coding Validation Detail");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var d = rows[r];

            ws.Cell(rowNum, 1).Value = d.WeekFolder;
            ws.Cell(rowNum, 2).Value = d.AccessionNo;
            ws.Cell(rowNum, 3).Value = d.PanelName;
            ws.Cell(rowNum, 4).Value = d.DateofService;
            ws.Cell(rowNum, 5).Value = d.ActualCPTCode;
            ws.Cell(rowNum, 6).Value = d.ExpectedCPTCode;
            ws.Cell(rowNum, 7).Value = d.MissingCPTCodes;
            ws.Cell(rowNum, 8).Value = d.AdditionalCPTCodes;
            ws.Cell(rowNum, 9).Value = d.ValidationStatus;
            ws.Cell(rowNum, 10).Value = d.TotalCharge;
            ws.Cell(rowNum, 11).Value = d.MissingCPT_Charges;
            ws.Cell(rowNum, 12).Value = d.AdditionalCPT_Charges;
            ws.Cell(rowNum, 13).Value = d.Remarks;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 14);
    }
}
