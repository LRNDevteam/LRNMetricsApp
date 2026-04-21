using ClosedXML.Excel;

using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook for the Collection Summary export.
/// Sheets: Top 5 Reimbursement, Top 5 Total Payments, Insurance vs Aging,
/// Panel vs Payment, Rep vs Payments, Insurance vs Payment %, CPT vs Payment %,
/// Panel Averages, ClaimLevelData, LineLevelData.
/// Styled using the blue-themed <see cref="ExcelTheme"/> palette.
/// </summary>
public static class CollectionSummaryExcelExportBuilder
{
    /// <summary>Creates the workbook with all report output sheets and raw data sheets.</summary>
    public static XLWorkbook CreateWorkbook(
        CollectionSummaryViewModel vm,
        List<Dictionary<string, object?>> claimRows,
        List<Dictionary<string, object?>> lineRows,
        string labName,
        IReadOnlyList<(string Label, string? Value)>? activeFilters = null)
    {
        var wb = new XLWorkbook();

        BuildMonthlyClaimVolumeSheet(wb, vm, labName);
        BuildWeeklyClaimVolumeSheet(wb, vm, labName);
        BuildTop5ReimbursementSheet(wb, vm.Top5Reimbursement, labName);
        if (vm.ShowTop5TotalPayments)
            BuildTop5TotalPaymentsSheet(wb, vm.Top5TotalPayments, labName);
        BuildInsuranceAgingSheet(wb, vm.InsuranceAging, labName);
        BuildPanelPaymentSheet(wb, vm.PanelPayments, labName);
        BuildRepPaymentsSheet(wb, vm.RepPayments, labName);
        BuildInsurancePaymentPctSheet(wb, vm.InsurancePaymentPct, labName);
        BuildCptPaymentPctSheet(wb, vm.CptPaymentPct, labName);
        BuildPanelAveragesSheet(wb, vm.PanelAverages, labName);
        BuildSplitRawDataSheets(wb, "ClaimLevelData", claimRows, labName, ExcelTheme.TabBlue);
        BuildSplitRawDataSheets(wb, "LineLevelData", lineRows, labName, ExcelTheme.TabGold);

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            int colCount = ws.LastColumnUsed()?.ColumnNumber() ?? 1;
            WriteFilterFooter(ws, lastRow + 2, colCount, activeFilters);
        }

        return wb;
    }

    // ?? Monthly Claim Volume ????????????????????????????????????????

    private static void BuildMonthlyClaimVolumeSheet(XLWorkbook wb, CollectionSummaryViewModel vm, string labName)
    {
        var pivot = vm.MonthlyClaimVolume;
        if (!pivot.HasData) return;

        var ws = wb.AddWorksheet("Monthly Claim Volume");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        var validYears = pivot.Years.Where(y => y > 1900).ToList();
        var periodsByYear = pivot.Periods
            .Where(p => p.Year > 1900)
            .GroupBy(p => p.Year)
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(p => p.Month).ToList());

        // Calculate total columns: Panel name + per-year(month*2 + yearTotal*2) + grandTotal*2
        int colCount = 1;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            colCount += months.Count * 2 + 2;
        }
        colCount += 2;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Monthly Claim Volume \u2014 {labName}");
        row++;

        // Header Row 1: year groups
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Panel & Insurance", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            int span = months.Count * 2 + 2;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1,
                $"Data based on Check Date \u2014 {year}", ExcelTheme.BlueHeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // Header Row 2: month names + year total
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            foreach (var p in months)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, p.MonthLabel, ExcelTheme.BlueSubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"{year} Total", ExcelTheme.AmberHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.AmberDarkBg);

        // Header Row 3: sub-column labels
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            foreach (var _ in months)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "Encounters", ExcelTheme.BlueSubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Insurance Paid", ExcelTheme.BlueSubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "Encounters", ExcelTheme.AmberHeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Insurance Paid", ExcelTheme.AmberHeaderBg);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "Encounters", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow3, hCol, "Insurance Paid", ExcelTheme.AmberDarkBg);

        row = hRow3 + 1;

        // Data rows
        int idx = 0;
        foreach (var panel in pivot.PanelRows)
        {
            var bg = idx % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            int col = 1;
            WriteCell(ws, row, col++, panel.PanelName, bg, isText: true, bold: true);

            foreach (var year in validYears)
            {
                var months = periodsByYear.GetValueOrDefault(year, []);
                foreach (var p in months)
                {
                    var cell = panel.ByMonth.GetValueOrDefault(p.Key);
                    WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg);
                    WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
                }
                var yt = panel.ByYear.GetValueOrDefault(year);
                WriteCell(ws, row, col++, yt?.EncounterCount ?? 0, bg);
                WriteCell(ws, row, col++, yt?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
            }
            WriteCell(ws, row, col++, panel.TotalEncounters, bg);
            WriteCell(ws, row, col, panel.TotalInsurancePaid, bg, isCurrency: true);
            row++;

            // Payer drill-down
            foreach (var payer in panel.TopPayers)
            {
                col = 1;
                WriteCell(ws, row, col++, $"  {payer.PayerName}", bg, isText: true);
                foreach (var year in validYears)
                {
                    var months = periodsByYear.GetValueOrDefault(year, []);
                    foreach (var p in months)
                    {
                        var cell = payer.ByMonth.GetValueOrDefault(p.Key);
                        WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg);
                        WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
                    }
                    var yt = payer.ByYear.GetValueOrDefault(year);
                    WriteCell(ws, row, col++, yt?.EncounterCount ?? 0, bg);
                    WriteCell(ws, row, col++, yt?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
                }
                WriteCell(ws, row, col++, payer.TotalEncounters, bg);
                WriteCell(ws, row, col, payer.TotalInsurancePaid, bg, isCurrency: true);
                row++;
            }
            idx++;
        }

        // Grand Total row
        {
            var bg = ExcelTheme.BlueTotalRowBg;
            int col = 1;
            WriteCell(ws, row, col++, "Grand Total", bg, isText: true, bold: true);
            foreach (var year in validYears)
            {
                var months = periodsByYear.GetValueOrDefault(year, []);
                foreach (var p in months)
                {
                    var cell = pivot.GrandTotalByMonth.GetValueOrDefault(p.Key);
                    WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg, bold: true);
                    WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
                }
                var yt = pivot.GrandTotalByYear.GetValueOrDefault(year);
                WriteCell(ws, row, col++, yt?.EncounterCount ?? 0, bg, bold: true);
                WriteCell(ws, row, col++, yt?.InsurancePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
            }
            WriteCell(ws, row, col++, pivot.GrandTotalEncounters, bg, bold: true);
            WriteCell(ws, row, col, pivot.GrandTotalInsurancePaid, bg, isCurrency: true, bold: true);
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(hRow3);
    }

    // ?? Weekly Claim Volume ?????????????????????????????????????????

    private static void BuildWeeklyClaimVolumeSheet(XLWorkbook wb, CollectionSummaryViewModel vm, string labName)
    {
        var pivot = vm.WeeklyClaimVolume;
        if (!pivot.HasData) return;

        var ws = wb.AddWorksheet("Weekly Claim Volume");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        int colCount = 1 + pivot.Weeks.Count * 2 + 2; // Panel + weeks*2 + Grand*2
        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Weekly Claim Volume \u2014 {labName}");
        row++;

        // Header Row 1: week labels
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Panel & Insurance", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var w in pivot.Weeks)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, w.Label, ExcelTheme.BlueSubHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // Header Row 2: sub-columns
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in pivot.Weeks)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "Encounters", ExcelTheme.BlueSubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Insurance Paid", ExcelTheme.BlueSubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "Encounters", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow2, hCol, "Insurance Paid", ExcelTheme.AmberDarkBg);

        row = hRow2 + 1;

        int idx = 0;
        foreach (var panel in pivot.PanelRows)
        {
            var bg = idx % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            int col = 1;
            WriteCell(ws, row, col++, panel.PanelName, bg, isText: true, bold: true);
            foreach (var w in pivot.Weeks)
            {
                var cell = panel.ByWeek.GetValueOrDefault(w.Key);
                WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg);
                WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
            }
            WriteCell(ws, row, col++, panel.TotalEncounters, bg);
            WriteCell(ws, row, col, panel.TotalInsurancePaid, bg, isCurrency: true);
            row++;

            foreach (var payer in panel.TopPayers)
            {
                col = 1;
                WriteCell(ws, row, col++, $"  {payer.PayerName}", bg, isText: true);
                foreach (var w in pivot.Weeks)
                {
                    var cell = payer.ByWeek.GetValueOrDefault(w.Key);
                    WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg);
                    WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
                }
                WriteCell(ws, row, col++, payer.TotalEncounters, bg);
                WriteCell(ws, row, col, payer.TotalInsurancePaid, bg, isCurrency: true);
                row++;
            }
            idx++;
        }

        // Grand Total
        {
            var bg = ExcelTheme.BlueTotalRowBg;
            int col = 1;
            WriteCell(ws, row, col++, "Grand Total", bg, isText: true, bold: true);
            foreach (var w in pivot.Weeks)
            {
                var cell = pivot.GrandTotalByWeek.GetValueOrDefault(w.Key);
                WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg, bold: true);
                WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
            }
            WriteCell(ws, row, col++, pivot.GrandTotalEncounters, bg, bold: true);
            WriteCell(ws, row, col, pivot.GrandTotalInsurancePaid, bg, isCurrency: true, bold: true);
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(hRow2);
    }

    // ?? Top 5 Insurance Reimbursement % ?????????????????????????????

    private static void BuildTop5ReimbursementSheet(XLWorkbook wb, List<InsuranceReimbursementRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Top 5 Reimbursement %");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Rank", "Payer Name", "Insurance Payment", "Charge Amount", "Unique Visits", "Reimbursement %"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Top 5 Insurance Reimbursement % \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.BlueHeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            WriteCell(ws, row, 1, r.Rank, bg);
            WriteCell(ws, row, 2, r.PayerName, bg, isText: true);
            WriteCell(ws, row, 3, r.SumInsurancePayment, bg, isCurrency: true);
            WriteCell(ws, row, 4, r.SumChargeAmount, bg, isCurrency: true);
            WriteCell(ws, row, 5, r.UniqueVisitCount, bg);
            WriteCell(ws, row, 6, r.ReimbursementPct, bg, isPct: true);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    // ?? Top 5 Insurance Total Payments ??????????????????????????????

    private static void BuildTop5TotalPaymentsSheet(XLWorkbook wb, List<InsuranceTotalPaymentRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Top 5 Total Payments");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Rank", "Payer Name", "Total Payments", "Unique Visits"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Top 5 Insurance Total Payments \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.BlueHeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            WriteCell(ws, row, 1, r.Rank, bg);
            WriteCell(ws, row, 2, r.PayerName, bg, isText: true);
            WriteCell(ws, row, 3, r.TotalPayments, bg, isCurrency: true);
            WriteCell(ws, row, 4, r.UniqueVisitCount, bg);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    // ?? Insurance vs Aging ??????????????????????????????????????????

    private static void BuildInsuranceAgingSheet(XLWorkbook wb, List<InsuranceAgingRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Insurance vs Aging");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Payer Name",
            "Current Claims", "Current Balance",
            "30+ Claims", "30+ Balance",
            "60+ Claims", "60+ Balance",
            "90+ Claims", "90+ Balance",
            "120+ Claims", "120+ Balance",
            "Total Claims", "Total Balance"
        ];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Insurance vs Aging \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.BlueHeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            int col = 1;
            WriteCell(ws, row, col++, r.PayerName, bg, isText: true);
            WriteCell(ws, row, col++, r.ClaimsCurrent, bg);
            WriteCell(ws, row, col++, r.BalanceCurrent, bg, isCurrency: true);
            WriteCell(ws, row, col++, r.Claims30, bg);
            WriteCell(ws, row, col++, r.Balance30, bg, isCurrency: true);
            WriteCell(ws, row, col++, r.Claims60, bg);
            WriteCell(ws, row, col++, r.Balance60, bg, isCurrency: true);
            WriteCell(ws, row, col++, r.Claims90, bg);
            WriteCell(ws, row, col++, r.Balance90, bg, isCurrency: true);
            WriteCell(ws, row, col++, r.Claims120, bg);
            WriteCell(ws, row, col++, r.Balance120, bg, isCurrency: true);
            WriteCell(ws, row, col++, r.ClaimsTotal, bg);
            WriteCell(ws, row, col, r.BalanceTotal, bg, isCurrency: true);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    // ?? Panel vs Payment ????????????????????????????????????????????

    private static void BuildPanelPaymentSheet(XLWorkbook wb, List<PanelPaymentRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Panel vs Payment");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Panel Name", "No. of Claims", "Insurance Payments"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Panel vs Payment \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.BlueHeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            WriteCell(ws, row, 1, r.PanelName, bg, isText: true);
            WriteCell(ws, row, 2, r.NoOfClaims, bg);
            WriteCell(ws, row, 3, r.InsurancePayments, bg, isCurrency: true);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    // ?? Rep vs Payments ?????????????????????????????????????????????

    private static void BuildRepPaymentsSheet(XLWorkbook wb, RepPaymentPivot pivot, string labName)
    {
        var ws = wb.AddWorksheet("Rep vs Payments");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        if (!pivot.HasData)
        {
            ws.Cell(1, 1).Value = "No data available.";
            ws.Cell(1, 1).Style.Font.Italic = true;
            return;
        }

        int colCount = 1 + pivot.Periods.Count * 2 + 2; // Name + periods*2 + Grand*2
        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Rep vs Payments \u2014 {labName}");
        row++;

        // Header Row 1: period labels
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Sales Rep", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var p in pivot.Periods)
        {
            var label = new DateTime(p.Year, p.Month, 1, 0, 0, 0).ToString("MMM yyyy");
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, label, ExcelTheme.BlueSubHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // Header Row 2: sub-columns
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in pivot.Periods)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "Claims", ExcelTheme.BlueSubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Payments", ExcelTheme.BlueSubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "Claims", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow2, hCol, "Payments", ExcelTheme.AmberDarkBg);

        row = hRow2 + 1;

        for (int i = 0; i < pivot.Rows.Count; i++)
        {
            var r = pivot.Rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            int col = 1;
            WriteCell(ws, row, col++, r.SalesRepName, bg, isText: true);
            foreach (var p in pivot.Periods)
            {
                var cell = r.Cells.GetValueOrDefault(p);
                WriteCell(ws, row, col++, cell?.NoOfClaims ?? 0, bg);
                WriteCell(ws, row, col++, cell?.InsurancePayments ?? 0m, bg, isCurrency: true);
            }
            WriteCell(ws, row, col++, r.GrandClaims, bg);
            WriteCell(ws, row, col, r.GrandPayments, bg, isCurrency: true);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(hRow2);
    }

    // ?? Insurance vs Payment % ??????????????????????????????????????

    private static void BuildInsurancePaymentPctSheet(XLWorkbook wb, List<InsurancePaymentPctRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Insurance vs Payment %");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Payer Name", "Total Claims", "Insurance Payments", "Payment %"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Insurance vs Payment % \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.BlueHeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            WriteCell(ws, row, 1, r.PayerName, bg, isText: true);
            WriteCell(ws, row, 2, r.TotalClaims, bg);
            WriteCell(ws, row, 3, r.InsurancePayments, bg, isCurrency: true);
            WriteCell(ws, row, 4, r.PaymentPct, bg, isPct: true);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    // ?? CPT vs Payment % ????????????????????????????????????????????

    private static void BuildCptPaymentPctSheet(XLWorkbook wb, List<CptPaymentPctRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("CPT vs Payment %");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["CPT Code", "Service Units", "Payment %"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"CPT vs Payment % \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.BlueHeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            WriteCell(ws, row, 1, r.CptCode, bg, isText: true);
            WriteCell(ws, row, 2, r.SumServiceUnits, bg);
            WriteCell(ws, row, 3, r.PaymentPct, bg, isPct: true);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    // ?? Panel Averages ??????????????????????????????????????????????

    private static void BuildPanelAveragesSheet(XLWorkbook wb, List<PanelAveragesRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Panel Averages");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Panel / Payer", "Claims", "Total Charges", "Avg Billed",
            "Carrier Payment", "Avg Carrier Payment",
            "Fully Paid #", "Fully Paid Amt", "Avg Fully Paid",
            "Adjudicated #", "Adjudicated Amt", "Avg Adjudicated",
            "30-Day #", "30-Day Amt", "Avg 30-Day",
            "60-Day #", "60-Day Amt", "Avg 60-Day"
        ];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Panel Averages (Last 6 Months) \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.BlueHeaderBg);
        row++;

        int idx = 0;
        foreach (var panel in rows)
        {
            var bg = idx % 2 == 0 ? XLColor.White : ExcelTheme.BlueBandedRowBg;
            WritePanelAveragesMetricsRow(ws, row, panel.PanelName, panel.Metrics, bg, bold: true);
            row++;

            foreach (var payer in panel.Payers)
            {
                WritePanelAveragesMetricsRow(ws, row, $"  {payer.PayerName}", payer.Metrics, bg, bold: false);
                row++;
            }
            idx++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    private static void WritePanelAveragesMetricsRow(
        IXLWorksheet ws, int row, string label, PanelAveragesMetrics m, XLColor bg, bool bold)
    {
        int col = 1;
        WriteCell(ws, row, col++, label, bg, isText: true, bold: bold);
        WriteCell(ws, row, col++, m.ClaimCount, bg);
        WriteCell(ws, row, col++, m.TotalCharges, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgBilled, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.CarrierPayment, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgCarrierPayment, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.FullyPaidCount, bg);
        WriteCell(ws, row, col++, m.FullyPaidAmount, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgFullyPaid, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AdjudicatedCount, bg);
        WriteCell(ws, row, col++, m.AdjudicatedAmount, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgAdjudicated, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.Days30Count, bg);
        WriteCell(ws, row, col++, m.Days30Amount, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgDays30, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.Days60Count, bg);
        WriteCell(ws, row, col++, m.Days60Amount, bg, isCurrency: true);
        WriteCell(ws, row, col, m.AvgDays60, bg, isCurrency: true);
    }

    // ?? Raw Data Sheets ?????????????????????????????????????????????

    /// <summary>Row threshold above which data is split into multiple sheets.</summary>
    private const int SplitThreshold = 400_000;

    /// <summary>Maximum rows per raw data sheet to prevent out-of-memory on very large tables.</summary>
    private const int MaxRawDataRows = 500_000;

    /// <summary>
    /// Builds raw data sheets. When row count exceeds <see cref="SplitThreshold"/>,
    /// data is split into separate sheets by FirstBillDate year and month
    /// (e.g. ClaimLevelData_2025_Jan, ClaimLevelData_2025_Feb).
    /// Each sheet writes and formats data in <see cref="FormatChunkSize"/> batches to avoid OOM.
    /// </summary>
    private static void BuildSplitRawDataSheets(
        XLWorkbook wb, string baseSheetName, List<Dictionary<string, object?>> rows,
        string labName, XLColor tabColor)
    {
        if (rows.Count <= SplitThreshold)
        {
            BuildRawDataSheet(wb, baseSheetName, rows, labName, tabColor);
            return;
        }

        // Group rows by year and month from FirstBillDate
        var grouped = rows
            .GroupBy(r => (Year: GetFirstBillDateYear(r), Month: GetFirstBillDateMonth(r)))
            .OrderBy(g => g.Key.Year).ThenBy(g => g.Key.Month)
            .ToList();

        foreach (var group in grouped)
        {
            var monthRows = group.ToList();
            int year = group.Key.Year;
            int month = group.Key.Month;
            string yearLabel = year > 0 ? year.ToString() : "Unknown";
            string monthLabel = year > 0
                ? new DateTime(year, month, 1).ToString("MMM")
                : "Unknown";
            string sheetName = TruncateSheetName($"{baseSheetName}_{yearLabel}_{monthLabel}");
            BuildRawDataSheet(wb, sheetName, monthRows, labName, tabColor);
        }
    }

    private static int GetFirstBillDateYear(Dictionary<string, object?> row)
    {
        if (row.TryGetValue("FirstBillDate", out var val))
        {
            if (val is DateTime dt) return dt.Year;
            if (val is string s && DateTime.TryParse(s, out var parsed)) return parsed.Year;
        }
        return 0;
    }

    private static int GetFirstBillDateMonth(Dictionary<string, object?> row)
    {
        if (row.TryGetValue("FirstBillDate", out var val))
        {
            if (val is DateTime dt) return dt.Month;
            if (val is string s && DateTime.TryParse(s, out var parsed)) return parsed.Month;
        }
        return 1;
    }

    /// <summary>Excel sheet names are limited to 31 characters.</summary>
    private static string TruncateSheetName(string name) =>
        name.Length <= 31 ? name : name[..31];

    private static void BuildRawDataSheet(
        XLWorkbook wb, string sheetName, List<Dictionary<string, object?>> rows,
        string labName, XLColor tabColor)
    {
        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = tabColor;
        ExcelTheme.ApplyDefaults(ws);

        if (rows.Count == 0)
        {
            ws.Cell(1, 1).Value = "No data available.";
            ws.Cell(1, 1).Style.Font.Italic = true;
            return;
        }

        var columns = rows[0].Keys.ToArray();
        int colCount = columns.Length;
        bool truncated = rows.Count > MaxRawDataRows;
        int rowsToWrite = Math.Min(rows.Count, MaxRawDataRows);

        // Title bar
        int row = 1;
        var titleText = truncated
            ? $"{sheetName} \u2014 {labName} (showing {rowsToWrite:N0} of {rows.Count:N0} rows)"
            : $"{sheetName} \u2014 {labName} ({rows.Count:N0} rows)";
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, titleText);
        row++;

        // Header row
        ExcelTheme.WriteHeaderRow(ws, row, 1, columns, ExcelTheme.BlueHeaderBg);
        row++;

        // Write data rows — values only, no formatting for raw data sheets
        for (int r = 0; r < rowsToWrite; r++)
        {
            var dataRow = rows[r];
            for (int c = 0; c < columns.Length; c++)
            {
                var val = dataRow[columns[c]];
                if (val is not null)
                    SetRawCellValue(ws.Cell(row, c + 1), val);
            }
            row++;
        }



        // Truncation warning
        if (truncated)
        {
            var warnCell = ws.Cell(row, 1);
            warnCell.Value = $"? Export truncated at {MaxRawDataRows:N0} rows. Total rows in database: {rows.Count:N0}. Apply filters to reduce the dataset.";
            warnCell.Style.Font.Bold = true;
            warnCell.Style.Font.FontColor = XLColor.FromHtml("#9C0006");
            warnCell.Style.Fill.BackgroundColor = XLColor.FromHtml("#FFC7CE");
            ws.Range(row, 1, row, colCount).Merge();
        }

        // Set fixed column widths instead of AutoFitColumns (avoids scanning all rows)
        foreach (var col in ws.ColumnsUsed())
            col.Width = 18;

        ws.SheetView.FreezeRows(2);
    }

    // ?? Helpers ??????????????????????????????????????????????????????

    private static void WriteCell(IXLWorksheet ws, int row, int col, object? value, XLColor bg,
        bool isText = false, bool isCurrency = false, bool isPct = false, bool bold = false)
    {
        var cell = ws.Cell(row, col);

        switch (value)
        {
            case string s:
                cell.Value = s;
                break;
            case decimal d:
                cell.Value = d;
                if (isCurrency) cell.Style.NumberFormat.Format = "#,##0.00";
                else if (isPct) cell.Style.NumberFormat.Format = "#,##0.00\"%\"";
                break;
            case int i:
                cell.Value = i;
                cell.Style.NumberFormat.Format = "#,##0";
                break;
            case null:
                break;
            default:
                cell.Value = value.ToString();
                break;
        }

        ExcelTheme.StyleDataCell(cell, bg);
        if (bold) cell.Style.Font.Bold = true;
    }

    private static void SetRawCellValue(IXLCell cell, object? val)
    {
        if (val is null) return;

        switch (val)
        {
            case decimal d:
                cell.Value = d;
                cell.Style.NumberFormat.Format = "#,##0.00";
                break;
            case double dbl:
                cell.Value = dbl;
                cell.Style.NumberFormat.Format = "#,##0.00";
                break;
            case int i:
                cell.Value = i;
                break;
            case long l:
                cell.Value = l;
                break;
            case DateTime dt:
                cell.Value = dt;
                cell.Style.NumberFormat.Format = "yyyy-MM-dd";
                break;
            default:
                cell.Value = val.ToString();
                break;
        }
    }

    private static void WriteMergedHeader(IXLWorksheet ws, int row1, int row2, int col1, int col2,
        string text, XLColor bg)
    {
        var range = ws.Range(row1, col1, row2, col2);
        range.Merge();
        var cell = ws.Cell(row1, col1);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = ExcelTheme.FontSizeHeader;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        cell.Style.Alignment.WrapText = true;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorderColor = XLColor.White;
    }

    private static void WriteHeaderCell(IXLWorksheet ws, int row, int col, string text, XLColor bg)
    {
        var cell = ws.Cell(row, col);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = ExcelTheme.FontSizeHeader;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        cell.Style.Alignment.WrapText = true;
        cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        cell.Style.Border.OutsideBorderColor = XLColor.White;
    }

    private static void AutoFitColumns(IXLWorksheet ws)
    {
        foreach (var col in ws.ColumnsUsed())
        {
            col.AdjustToContents();
            if (col.Width > 35) col.Width = 35;
        }
    }

    private static void WriteFilterFooter(
        IXLWorksheet ws, int startRow, int colCount,
        IReadOnlyList<(string Label, string? Value)> filters)
    {
        var range = ws.Range(startRow, 1, startRow, colCount);
        range.Merge();
        var cell = ws.Cell(startRow, 1);
        cell.Value = "Active Filters";
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = 11;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = ExcelTheme.BlueHeaderBg;

        int row = startRow + 1;
        foreach (var (label, value) in filters)
        {
            if (string.IsNullOrWhiteSpace(value)) continue;
            ws.Cell(row, 1).Value = label;
            ws.Cell(row, 1).Style.Font.Bold = true;
            ws.Cell(row, 2).Value = value;
            row++;
        }
    }
}
