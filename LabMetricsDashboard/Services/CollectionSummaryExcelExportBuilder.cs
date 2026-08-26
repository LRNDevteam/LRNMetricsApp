using ClosedXML.Excel;

using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook for the Collection Summary export.
/// Sheets: Top 5 Reimbursement, Top 5 Total Payments, Insurance vs Aging,
/// Panel vs Payment, Rep vs Payments, Insurance vs Payment %, CPT vs Payment %,
/// Panel Averages, ClaimLevelData, LineLevelData.
/// Styled using the same green ExcelTheme palette as Prediction Summary (Calibri / Accent 6).
/// </summary>
public static class CollectionSummaryExcelExportBuilder
{
    /// <summary>
    /// Raw-data row limit. When ClaimLevelData or LineLevelData exceeds this count the
    /// corresponding raw-data sheets are omitted from the workbook and a notice is written
    /// instead to prevent out-of-memory on large labs.
    /// </summary>
    public const int RawDataRowLimit = 200_000;

    /// <summary>Creates the workbook with all report output sheets and raw data sheets.</summary>
    /// <param name="claimRowsOmitted">
    /// When non-null, raw ClaimLevelData was skipped because its count exceeded the limit.
    /// The value is the actual row count; a notice sheet is written instead.
    /// </param>
    /// <param name="lineRowsOmitted">
    /// When non-null, raw LineLevelData was skipped because its count exceeded the limit.
    /// </param>
    public static XLWorkbook CreateWorkbook(
        CollectionSummaryViewModel vm,
        List<Dictionary<string, object?>> claimRows,
        List<Dictionary<string, object?>> lineRows,
        string labName,
        IReadOnlyList<(string Label, string? Value)>? activeFilters = null,
        int? claimRowsOmitted = null,
        int? lineRowsOmitted  = null)
    {
        var wb = new XLWorkbook();

        BuildMonthlyClaimVolumeSheet(wb, vm, labName);
        BuildWeeklyClaimVolumeSheet(wb, vm, labName);
        BuildTop5ReimbursementSheet(wb, vm.Top5Reimbursement, labName);
        if (vm.ShowTop5TotalPayments)
            BuildTop5TotalPaymentsSheet(wb, vm.Top5TotalPayments, labName);
        BuildInsuranceAgingSheet(wb, vm.InsuranceAging, labName);
        BuildPanelPaymentSheet(wb, vm.PanelPayments, labName);
        BuildInsurancePaymentPctSheet(wb, vm.InsurancePaymentPct, labName);
        BuildCptPaymentPctSheet(wb, vm.CptPaymentPct, labName);
        BuildPanelAveragesSheet(wb, vm.PanelAverages, labName);
        BuildAvgPaymentsSheet(wb, vm.AvgPayments, labName);
        BuildStatusSummarySheet(wb, vm.StatusSummary, labName);
        BuildProviderSummarySheet(wb, vm.ProviderSummary, labName);

        if (claimRowsOmitted.HasValue)
            BuildRawDataOmittedNoticeSheet(wb, "ClaimLevelData", claimRowsOmitted.Value, ExcelTheme.TabGreen);
        else
            BuildSplitRawDataSheets(wb, "ClaimLevelData", claimRows, labName, ExcelTheme.TabGreen);

        if (lineRowsOmitted.HasValue)
            BuildRawDataOmittedNoticeSheet(wb, "LineLevelData", lineRowsOmitted.Value, ExcelTheme.TabGold);
        else
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

    /// <summary>
    /// Writes a single-row notice sheet when raw data is omitted because the row count
    /// exceeds <see cref="RawDataRowLimit"/>.
    /// </summary>
    private static void BuildRawDataOmittedNoticeSheet(
        XLWorkbook wb, string sheetBaseName, int rowCount, XLColor tabColor)
    {
        var ws = wb.AddWorksheet(sheetBaseName);
        ws.TabColor = tabColor;
        ExcelTheme.ApplyDefaults(ws);

        var cell = ws.Cell(1, 1);
        cell.Value = $"{sheetBaseName} data not included — {rowCount:N0} rows exceed the {RawDataRowLimit:N0}-row export limit. " +
                     "Use filters on the Collection Summary page to narrow the data before exporting.";
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontColor = XLColor.DarkRed;
        ws.Column(1).Width = 100;
    }

    // ?? Monthly Claim Volume ????????????????????????????????????????

    private static void BuildMonthlyClaimVolumeSheet(XLWorkbook wb, CollectionSummaryViewModel vm, string labName)
    {
        var pivot = vm.MonthlyClaimVolume;
        if (!pivot.HasData) return;

        var ws = wb.AddWorksheet("Monthly Claim Volume");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var validYears = pivot.Years.Where(y => y > 1900).ToList();
        var periodsByYear = pivot.Periods
            .Where(p => p.Year > 1900)
            .GroupBy(p => p.Year)
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(p => p.Month).ToList());

        // Calculate total columns: Panel name + per-year(month*3 + yearTotal*3) + grandTotal*3
        int colCount = 1;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            colCount += months.Count * 3 + 3;
        }
        colCount += 3;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Monthly Claim Volume \u2014 {labName}");
        row++;

        // Header Row 1: year groups
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Panel & Insurance", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            int span = months.Count * 3 + 3;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1,
                $"Data based on Check Date \u2014 {year}", ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 2, "Grand Total", ExcelTheme.AmberDarkBg);

        // Header Row 2: month names + year total
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            foreach (var p in months)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 2, p.MonthLabel, ExcelTheme.SubHeaderBg);
                hCol += 3;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 2, $"{year} Total", ExcelTheme.AmberHeaderBg);
            hCol += 3;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 2, "", ExcelTheme.AmberDarkBg);

        // Header Row 3: sub-column labels
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in validYears)
        {
            var months = periodsByYear.GetValueOrDefault(year, []);
            foreach (var _ in months)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "Encounters", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Insurance Paid", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Average Paid", ExcelTheme.SubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "Encounters", ExcelTheme.AmberHeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Insurance Paid", ExcelTheme.AmberHeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Average Paid", ExcelTheme.AmberHeaderBg);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "Encounters", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow3, hCol++, "Insurance Paid", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow3, hCol, "Average Paid", ExcelTheme.AmberDarkBg);

        row = hRow3 + 1;

        // Data rows
        int idx = 0;
        foreach (var panel in pivot.PanelRows)
        {
            var bg = idx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
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
                    WriteCell(ws, row, col++, cell?.AveragePaidAmount ?? 0m, bg, isCurrency: true);
                }
                var yt = panel.ByYear.GetValueOrDefault(year);
                WriteCell(ws, row, col++, yt?.EncounterCount ?? 0, bg);
                WriteCell(ws, row, col++, yt?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
                WriteCell(ws, row, col++, yt?.AveragePaidAmount ?? 0m, bg, isCurrency: true);
            }
            WriteCell(ws, row, col++, panel.TotalEncounters, bg);
            WriteCell(ws, row, col++, panel.TotalInsurancePaid, bg, isCurrency: true);
            WriteCell(ws, row, col, panel.TotalAveragePaidAmount, bg, isCurrency: true);
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
                        WriteCell(ws, row, col++, cell?.AveragePaidAmount ?? 0m, bg, isCurrency: true);
                    }
                    var yt = payer.ByYear.GetValueOrDefault(year);
                    WriteCell(ws, row, col++, yt?.EncounterCount ?? 0, bg);
                    WriteCell(ws, row, col++, yt?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
                    WriteCell(ws, row, col++, yt?.AveragePaidAmount ?? 0m, bg, isCurrency: true);
                }
                WriteCell(ws, row, col++, payer.TotalEncounters, bg);
                WriteCell(ws, row, col++, payer.TotalInsurancePaid, bg, isCurrency: true);
                WriteCell(ws, row, col, payer.TotalAveragePaidAmount, bg, isCurrency: true);
                row++;
            }
            idx++;
        }

        // Grand Total row
        {
            var bg = ExcelTheme.TotalRowBg;
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
                    WriteCell(ws, row, col++, cell?.AveragePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
                }
                var yt = pivot.GrandTotalByYear.GetValueOrDefault(year);
                WriteCell(ws, row, col++, yt?.EncounterCount ?? 0, bg, bold: true);
                WriteCell(ws, row, col++, yt?.InsurancePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
                WriteCell(ws, row, col++, yt?.AveragePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
            }
            WriteCell(ws, row, col++, pivot.GrandTotalEncounters, bg, bold: true);
            WriteCell(ws, row, col++, pivot.GrandTotalInsurancePaid, bg, isCurrency: true, bold: true);
            WriteCell(ws, row, col, pivot.GrandTotalAveragePaidAmount, bg, isCurrency: true, bold: true);
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
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        int colCount = 1 + pivot.Weeks.Count * 3 + 3; // Panel + weeks*3 + Grand*3
        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Weekly Claim Volume \u2014 {labName}");
        row++;

        // Header Row 1: week labels
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Panel & Insurance", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var w in pivot.Weeks)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 2, w.Label, ExcelTheme.SubHeaderBg);
            hCol += 3;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 2, "Grand Total", ExcelTheme.AmberDarkBg);

        // Header Row 2: sub-columns
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in pivot.Weeks)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "Encounters", ExcelTheme.SubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Insurance Paid", ExcelTheme.SubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Average Paid", ExcelTheme.SubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "Encounters", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow2, hCol++, "Insurance Paid", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow2, hCol, "Average Paid", ExcelTheme.AmberDarkBg);

        row = hRow2 + 1;

        int idx = 0;
        foreach (var panel in pivot.PanelRows)
        {
            var bg = idx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
            int col = 1;
            WriteCell(ws, row, col++, panel.PanelName, bg, isText: true, bold: true);
            foreach (var w in pivot.Weeks)
            {
                var cell = panel.ByWeek.GetValueOrDefault(w.Key);
                WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg);
                WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true);
                WriteCell(ws, row, col++, cell?.AveragePaidAmount ?? 0m, bg, isCurrency: true);
            }
            WriteCell(ws, row, col++, panel.TotalEncounters, bg);
            WriteCell(ws, row, col++, panel.TotalInsurancePaid, bg, isCurrency: true);
            WriteCell(ws, row, col, panel.TotalAveragePaidAmount, bg, isCurrency: true);
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
                    WriteCell(ws, row, col++, cell?.AveragePaidAmount ?? 0m, bg, isCurrency: true);
                }
                WriteCell(ws, row, col++, payer.TotalEncounters, bg);
                WriteCell(ws, row, col++, payer.TotalInsurancePaid, bg, isCurrency: true);
                WriteCell(ws, row, col, payer.TotalAveragePaidAmount, bg, isCurrency: true);
                row++;
            }
            idx++;
        }

        // Grand Total
        {
            var bg = ExcelTheme.TotalRowBg;
            int col = 1;
            WriteCell(ws, row, col++, "Grand Total", bg, isText: true, bold: true);
            foreach (var w in pivot.Weeks)
            {
                var cell = pivot.GrandTotalByWeek.GetValueOrDefault(w.Key);
                WriteCell(ws, row, col++, cell?.EncounterCount ?? 0, bg, bold: true);
                WriteCell(ws, row, col++, cell?.InsurancePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
                WriteCell(ws, row, col++, cell?.AveragePaidAmount ?? 0m, bg, isCurrency: true, bold: true);
            }
            WriteCell(ws, row, col++, pivot.GrandTotalEncounters, bg, bold: true);
            WriteCell(ws, row, col++, pivot.GrandTotalInsurancePaid, bg, isCurrency: true, bold: true);
            WriteCell(ws, row, col, pivot.GrandTotalAveragePaidAmount, bg, isCurrency: true, bold: true);
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(hRow2);
    }

    // ?? Top 5 Insurance Reimbursement % ?????????????????????????????

    private static void BuildTop5ReimbursementSheet(XLWorkbook wb, List<InsuranceReimbursementRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Top 5 Reimbursement %");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Rank", "Payer Name", "Insurance Payment", "Charge Amount", "Unique Visits", "Reimbursement %"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Top 5 Insurance Reimbursement % \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
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
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Rank", "Payer Name", "Total Payments", "Unique Visits"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Top 5 Insurance Total Payments \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
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
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        // Augustus carries a billing source (ClaimLevelData.Source, e.g. "IRCM") in front of
        // the payer; labs whose SP returns no Source column keep the original column set.
        bool showSource = rows.Any(r => !string.IsNullOrWhiteSpace(r.Source));

        var headerList = new List<string>();
        if (showSource) headerList.Add("Source");
        headerList.AddRange(
        [
            "Payer Name",
            "Current Claims", "Current Balance",
            "30+ Claims", "30+ Balance",
            "60+ Claims", "60+ Balance",
            "90+ Claims", "90+ Balance",
            "120+ Claims", "120+ Balance",
            "Total Claims", "Total Balance"
        ]);
        string[] headers = [.. headerList];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Insurance vs Aging \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        if (showSource)
        {
            // Mirror the report tab: one collapsible outline group per billing source,
            // its totals on the summary row above the payers.
            ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

            var groups = rows
                .GroupBy(r => r.Source ?? string.Empty, StringComparer.OrdinalIgnoreCase)
                .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase);

            int groupIdx = 0;
            foreach (var group in groups)
            {
                var groupRows = group.ToList();
                var sourceLabel = string.IsNullOrWhiteSpace(group.Key) ? "(blank)" : group.Key;
                var bg = groupIdx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;

                WriteAgingRow(ws, row++, sourceLabel, $"{sourceLabel} Total",
                    groupRows.Sum(r => r.ClaimsCurrent), groupRows.Sum(r => r.BalanceCurrent),
                    groupRows.Sum(r => r.Claims30), groupRows.Sum(r => r.Balance30),
                    groupRows.Sum(r => r.Claims60), groupRows.Sum(r => r.Balance60),
                    groupRows.Sum(r => r.Claims90), groupRows.Sum(r => r.Balance90),
                    groupRows.Sum(r => r.Claims120), groupRows.Sum(r => r.Balance120),
                    groupRows.Sum(r => r.ClaimsTotal), groupRows.Sum(r => r.BalanceTotal),
                    ExcelTheme.SubHeaderBg, bold: true, showSource: true);

                int firstChild = row;
                foreach (var r in groupRows)
                {
                    WriteAgingRow(ws, row++, r.Source, r.PayerName,
                        r.ClaimsCurrent, r.BalanceCurrent, r.Claims30, r.Balance30,
                        r.Claims60, r.Balance60, r.Claims90, r.Balance90,
                        r.Claims120, r.Balance120, r.ClaimsTotal, r.BalanceTotal,
                        bg, bold: false, showSource: true);
                }

                if (row > firstChild)
                {
                    ws.Rows(firstChild, row - 1).Group();
                    ws.Rows(firstChild, row - 1).Collapse();
                }

                groupIdx++;
            }
        }
        else
        {
            for (int i = 0; i < rows.Count; i++)
            {
                var r = rows[i];
                var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
                WriteAgingRow(ws, row++, r.Source, r.PayerName,
                    r.ClaimsCurrent, r.BalanceCurrent, r.Claims30, r.Balance30,
                    r.Claims60, r.Balance60, r.Claims90, r.Balance90,
                    r.Claims120, r.Balance120, r.ClaimsTotal, r.BalanceTotal,
                    bg, bold: false, showSource: false);
            }
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    private static void WriteAgingRow(
        IXLWorksheet ws, int row, string source, string label,
        int cCur, decimal bCur, int c30, decimal b30, int c60, decimal b60,
        int c90, decimal b90, int c120, decimal b120, int cTot, decimal bTot,
        XLColor bg, bool bold, bool showSource)
    {
        int col = 1;
        if (showSource)
            WriteCell(ws, row, col++, source, bg, isText: true, bold: bold);
        WriteCell(ws, row, col++, label, bg, isText: true, bold: bold);
        WriteCell(ws, row, col++, cCur, bg, bold: bold);
        WriteCell(ws, row, col++, bCur, bg, isCurrency: true, bold: bold);
        WriteCell(ws, row, col++, c30, bg, bold: bold);
        WriteCell(ws, row, col++, b30, bg, isCurrency: true, bold: bold);
        WriteCell(ws, row, col++, c60, bg, bold: bold);
        WriteCell(ws, row, col++, b60, bg, isCurrency: true, bold: bold);
        WriteCell(ws, row, col++, c90, bg, bold: bold);
        WriteCell(ws, row, col++, b90, bg, isCurrency: true, bold: bold);
        WriteCell(ws, row, col++, c120, bg, bold: bold);
        WriteCell(ws, row, col++, b120, bg, isCurrency: true, bold: bold);
        WriteCell(ws, row, col++, cTot, bg, bold: true);
        WriteCell(ws, row, col, bTot, bg, isCurrency: true, bold: true);
    }

    // ?? Panel vs Payment ????????????????????????????????????????????

    private static void BuildPanelPaymentSheet(XLWorkbook wb, List<PanelPaymentRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Panel vs Payment");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Panel Name", "No. of Claims", "Insurance Payments"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Panel vs Payment \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        // Collapse the per-month grain (Elixir) into one row per panel for the flat export.
        // Augustus ranks by Count of PanelNew; other labs rank by SUM(InsurancePayment).
        var isAugustus = labName.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase)
            || labName.Equals("Augustus", StringComparison.OrdinalIgnoreCase);
        var flatRows = rows
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .Select(g => new
            {
                PanelName = g.Key,
                NoOfClaims = g.Sum(x => x.NoOfClaims),
                InsurancePayments = g.Sum(x => x.InsurancePayments),
            })
            .OrderByDescending(r => isAugustus ? r.NoOfClaims : r.InsurancePayments)
            .ToList();

        for (int i = 0; i < flatRows.Count; i++)
        {
            var r = flatRows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
            WriteCell(ws, row, 1, r.PanelName, bg, isText: true);
            WriteCell(ws, row, 2, r.NoOfClaims, bg);
            WriteCell(ws, row, 3, r.InsurancePayments, bg, isCurrency: true);
            row++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(3);
    }

    // ?? Insurance vs Payment % ??????????????????????????????????????

    private static void BuildInsurancePaymentPctSheet(XLWorkbook wb, List<InsurancePaymentPctRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Insurance vs Payment %");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Payer Name", "Total Claims", "Insurance Payments", "Payment %"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Insurance vs Payment % \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
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
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["CPT Code", "Service Units", "Payment %"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"CPT vs Payment % \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
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
        ws.TabColor = ExcelTheme.TabGreen;
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
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Panel Averages (Last 6 Months) \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        // Mirror the report tab: each panel is a collapsible outline group over its payers.
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        int idx = 0;
        foreach (var panel in rows)
        {
            var bg = idx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
            WritePanelAveragesMetricsRow(ws, row, panel.PanelName, panel.Metrics, bg, bold: true);
            row++;

            int firstChild = row;
            foreach (var payer in panel.Payers)
            {
                WritePanelAveragesMetricsRow(ws, row, $"  {payer.PayerName}", payer.Metrics, bg, bold: false);
                row++;
            }
            if (row > firstChild)
            {
                ws.Rows(firstChild, row - 1).Group();
                ws.Rows(firstChild, row - 1).Collapse();
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

    // ?? Average Payments (Per Panel | Last 6 Months | Posted Date) ?????

    private static void BuildAvgPaymentsSheet(XLWorkbook wb, PanelAveragesResult result, string labName)
    {
        if (result.PanelRows.Count == 0) return;

        var ws = wb.AddWorksheet("Avg Payments");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Panel / Payer", "No of Claims", "Total Charges", "Avg Billed $",
            "Fully Paid #", "Fully Paid $", "Avg Fully Paid $",
            "Adjudicated #", "Adjudicated $", "Avg Adjudicated $",
            "30-Day #", "30-Day $", "Avg 30-Day $",
            "60-Day #", "60-Day $", "Avg 60-Day $"
        ];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount,
            $"Average Payments \u2014 Per Panel | Last 6 Months | Posted Date \u2014 {labName}");
        row++;

        // Two-row header: span group columns
        var groupBg = ExcelTheme.SubHeaderBg;
        WriteMergedHeader(ws, row, row, 1, 4, "Panel / Payer � Summary", ExcelTheme.HeaderBg);
        WriteMergedHeader(ws, row, row, 5, 7,  "Fully Paid",   groupBg);
        WriteMergedHeader(ws, row, row, 8, 10, "Adjudicated",  groupBg);
        WriteMergedHeader(ws, row, row, 11, 13, "30 Days",     groupBg);
        WriteMergedHeader(ws, row, row, 14, 16, "60 Days",     groupBg);
        row++;

        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;
        int freezeRow = row;

        // Mirror the report tab: each panel is a collapsible outline group over its payers.
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        int idx = 0;
        foreach (var panel in result.PanelRows)
        {
            var bg = idx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
            WriteAvgPayMetricsRow(ws, row, panel.PanelName, panel.Metrics, bg, bold: true);
            row++;

            int firstChild = row;
            foreach (var payer in panel.Payers)
            {
                WriteAvgPayMetricsRow(ws, row, $"  {payer.PayerName}", payer.Metrics, bg, bold: false);
                row++;
            }
            if (row > firstChild)
            {
                ws.Rows(firstChild, row - 1).Group();
                ws.Rows(firstChild, row - 1).Collapse();
            }
            idx++;
        }

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(freezeRow - 1);
    }

    private static void WriteAvgPayMetricsRow(
        IXLWorksheet ws, int row, string label, PanelAveragesMetrics m, XLColor bg, bool bold)
    {
        int col = 1;
        WriteCell(ws, row, col++, label,             bg, isText: true, bold: bold);
        WriteCell(ws, row, col++, m.ClaimCount,      bg);
        WriteCell(ws, row, col++, m.TotalCharges,    bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgBilled,       bg, isCurrency: true);
        WriteCell(ws, row, col++, m.FullyPaidCount,  bg);
        WriteCell(ws, row, col++, m.FullyPaidAmount, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgFullyPaid,    bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AdjudicatedCount,  bg);
        WriteCell(ws, row, col++, m.AdjudicatedAmount, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgAdjudicated,    bg, isCurrency: true);
        WriteCell(ws, row, col++, m.Days30Count,  bg);
        WriteCell(ws, row, col++, m.Days30Amount, bg, isCurrency: true);
        WriteCell(ws, row, col++, m.AvgDays30,   bg, isCurrency: true);
        WriteCell(ws, row, col++, m.Days60Count,  bg);
        WriteCell(ws, row, col++, m.Days60Amount, bg, isCurrency: true);
        WriteCell(ws, row, col,   m.AvgDays60,   bg, isCurrency: true);
    }

    // ?? Status Summary ??????????????????????????????????????????????

    private static void BuildStatusSummarySheet(XLWorkbook wb, StatusSummaryResult result, string labName)
    {

        if (!result.HasData) return;

        var ws = wb.AddWorksheet("Status Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        // Summary rows appear ABOVE their detail rows (parent before children)
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        // Colour palette — same green family as Prediction Summary Excel
        var claimStatusBg = ExcelTheme.TitleBg;      // dark green — ClaimStatus header
        var panelBg       = ExcelTheme.HeaderBg;     // green — Panel
        var cptBg         = ExcelTheme.BandedRowBg;  // light green — CPT
        var payerBg       = XLColor.White;           // white — Payer
        var grandBg       = ExcelTheme.TitleBg;      // darkest green — Grand Total

        // 5 columns � no separate "Level" column; hierarchy is visual
        string[] headers = ["Row Labels", "Count of Claims", "Ins. Payments", "Ins. Balance", "Pt Balance"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Status Summary \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;
        ws.SheetView.FreezeRows(row - 1);

        foreach (var csRow in result.Rows)
        {
            // L1 � ClaimStatus: no outline level (always visible), dark header
            WriteSsRow(ws, row++, csRow.ClaimStatus,
                csRow.NoClaims, csRow.InsurancePayments, csRow.InsuranceBalance, csRow.PatientBalance,
                claimStatusBg, XLColor.White, bold: true, indent: 0, outlineLevel: 0);

            foreach (var panelRow in csRow.PanelRows)
            {
                // L2 � Panel: outline level 1
                WriteSsRow(ws, row++, panelRow.PanelName,
                    panelRow.NoClaims, panelRow.InsurancePayments, panelRow.InsuranceBalance, panelRow.PatientBalance,
                    panelBg, XLColor.White, bold: true, indent: 1, outlineLevel: 1);

                foreach (var cptRow in panelRow.CptRows)
                {
                    // L3 � CPT: outline level 2
                    WriteSsRow(ws, row++, cptRow.CptCode,
                        cptRow.NoClaims, cptRow.InsurancePayments, cptRow.InsuranceBalance, cptRow.PatientBalance,
                        cptBg, ExcelTheme.TitleBg, bold: true, indent: 2, outlineLevel: 2);

                    foreach (var payerRow in cptRow.Payers)
                    {
                        // L4 � Payer: outline level 3 (deepest, initially visible)
                        WriteSsRow(ws, row++, payerRow.PayerName,
                            payerRow.NoClaims, payerRow.InsurancePayments, payerRow.InsuranceBalance, payerRow.PatientBalance,
                            payerBg, XLColor.FromHtml("#334155"), bold: false, indent: 4, outlineLevel: 3);
                    }
                }
            }
        }

        // Grand Total
        var grandLabel = ws.Cell(row, 1);
        grandLabel.Value = "Grand Total";
        grandLabel.Style.Fill.BackgroundColor = grandBg;
        grandLabel.Style.Font.Bold = true;
        grandLabel.Style.Font.FontColor = XLColor.White;

        WriteGrandTotalCell(ws, row, 2, result.GrandNoClaims,          grandBg);
        WriteGrandTotalCell(ws, row, 3, result.GrandInsurancePayments, grandBg, isCurrency: true);
        WriteGrandTotalCell(ws, row, 4, result.GrandInsuranceBalance,  grandBg, isCurrency: true);
        WriteGrandTotalCell(ws, row, 5, result.GrandPatientBalance,    grandBg, isCurrency: true);

        ws.Column(1).Width = 46;
        ws.Column(2).Width = 16;
        ws.Column(3).Width = 20;
        ws.Column(4).Width = 20;
        ws.Column(5).Width = 18;
    }

    /// <summary>Writes one Status Summary data row with outline grouping and accounting-style currency.</summary>
    private static void WriteSsRow(
        IXLWorksheet ws, int rowNum, string label,
        int noClaims, decimal insPayments, decimal insBalance, decimal ptBalance,
        XLColor bg, XLColor fontColor, bool bold, int indent, int outlineLevel)
    {
        if (outlineLevel > 0)
            ws.Row(rowNum).OutlineLevel = outlineLevel;

        ApplySsStyle(ws.Cell(rowNum, 1), bg, fontColor, bold, indent);
        ws.Cell(rowNum, 1).Value = label;

        var claimsCell = ws.Cell(rowNum, 2);
        claimsCell.Value = noClaims;
        claimsCell.Style.NumberFormat.Format = "#,##0";
        claimsCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        ApplySsStyle(claimsCell, bg, fontColor, bold, 0);

        WriteSsCurrency(ws.Cell(rowNum, 3), insPayments, bg, fontColor, bold);
        WriteSsCurrency(ws.Cell(rowNum, 4), insBalance,  bg, fontColor, bold);
        WriteSsCurrency(ws.Cell(rowNum, 5), ptBalance,   bg, fontColor, bold);
    }

    private static void ApplySsStyle(IXLCell cell, XLColor bg, XLColor fontColor, bool bold, int indent)
    {
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Font.FontColor = fontColor;
        cell.Style.Font.Bold = bold;
        if (indent > 0) cell.Style.Alignment.Indent = indent;
        cell.Style.Border.BottomBorder = XLBorderStyleValues.Hair;
        cell.Style.Border.BottomBorderColor = ExcelTheme.BorderColor;
    }

    /// <summary>
    /// Writes a currency cell using Excel accounting format: left-aligned $, right-aligned amount,
    /// "$ -" for zero � exactly matching the screenshot layout.
    /// </summary>
    private static void WriteSsCurrency(IXLCell cell, decimal value, XLColor bg, XLColor fontColor, bool bold)
    {
        if (value == 0m)
        {
            cell.Value = "-";
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        }
        else
        {
            cell.Value = value;
            cell.Style.NumberFormat.Format = @"_($* #,##0.00_);_($* (#,##0.00);_($* ""-""??_);_(@_)";
        }
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Font.FontColor = fontColor;
        cell.Style.Font.Bold = bold;
        cell.Style.Border.BottomBorder = XLBorderStyleValues.Hair;
        cell.Style.Border.BottomBorderColor = ExcelTheme.BorderColor;
    }

    private static void WriteGrandTotalCell(IXLWorksheet ws, int row, int col, object value, XLColor bg, bool isCurrency = false)
    {
        var cell = ws.Cell(row, col);
        if (value is int i) cell.Value = i;
        else if (value is decimal d) { cell.Value = d; if (isCurrency) cell.Style.NumberFormat.Format = "#,##0.00"; }
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
    }


    // ?? Provider Summary ??????????????????????????????????????????????

    private static void BuildProviderSummarySheet(XLWorkbook wb, ProviderSummaryResult result, string labName)
    {
        if (!result.HasData) return;

        var ws = wb.AddWorksheet("Provider Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["#", "Referring Provider", "No. of Claims", "Insurance Payments", "Insurance Balance", "Patient Balance", "Claim Share %"];
        int colCount = headers.Length;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, $"Provider Summary \u2014 {labName}");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;
        int freezeRow = row;

        for (int i = 0; i < result.Rows.Count; i++)
        {
            var r = result.Rows[i];
            var bg = i % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
            var sharePct = result.GrandNoClaims > 0
                ? Math.Round((decimal)r.NoOfClaims / result.GrandNoClaims * 100m, 2)
                : 0m;

            WriteCell(ws, row, 1, r.Rank,              bg);
            WriteCell(ws, row, 2, r.ReferringProvider, bg, isText: true);
            WriteCell(ws, row, 3, r.NoOfClaims,        bg);
            WriteCell(ws, row, 4, r.InsurancePayments, bg, isCurrency: true);
            WriteCell(ws, row, 5, r.InsuranceBalance,  bg, isCurrency: true);
            WriteCell(ws, row, 6, r.PatientBalance,    bg, isCurrency: true);
            WriteCell(ws, row, 7, sharePct,            bg, isPct: true);
            row++;
        }

        // Grand Total row
        var grandBg = ExcelTheme.TitleBg;
        var grandLbl = ws.Cell(row, 1);
        grandLbl.Value = "Grand Total";
        grandLbl.Style.Fill.BackgroundColor = grandBg;
        grandLbl.Style.Font.Bold = true;
        grandLbl.Style.Font.FontColor = XLColor.White;
        ws.Cell(row, 2).Style.Fill.BackgroundColor = grandBg;

        WriteGrandTotalCell(ws, row, 3, result.GrandNoClaims,        grandBg);
        WriteGrandTotalCell(ws, row, 4, result.GrandInsurancePayments, grandBg, isCurrency: true);
        WriteGrandTotalCell(ws, row, 5, result.GrandInsuranceBalance,  grandBg, isCurrency: true);
        WriteGrandTotalCell(ws, row, 6, result.GrandPatientBalance,    grandBg, isCurrency: true);
        var shareCell = ws.Cell(row, 7);
        shareCell.Value = 100m;
        shareCell.Style.NumberFormat.Format = "#,##0.00\"%\"";
        shareCell.Style.Fill.BackgroundColor = grandBg;
        shareCell.Style.Font.Bold = true;
        shareCell.Style.Font.FontColor = XLColor.White;
        shareCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;

        AutoFitColumns(ws);
        ws.SheetView.FreezeRows(freezeRow - 1);
    }

    // ?? Raw Data Sheets ??????????????????????????????????????????????

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
        ExcelTheme.WriteTitleBar(ws, row, colCount, titleText);
        row++;

        // Header row
        ExcelTheme.WriteHeaderRow(ws, row, 1, columns, ExcelTheme.HeaderBg);
        row++;

        // Write data rows � values only, no formatting for raw data sheets
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

        // Set fixed column widths instead of AutoFitColumns (avoids scanning all rows).
        // Materialize first: setting Width registers a column definition in the
        // worksheet's internal collection, which would invalidate a live
        // ColumnsUsed() enumerator ("Collection was modified…").
        foreach (var col in ws.ColumnsUsed().ToList())
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
        // Materialize first: AdjustToContents/Width mutate the worksheet's internal
        // column collection, which would invalidate a live ColumnsUsed() enumerator
        // ("Collection was modified…").
        foreach (var col in ws.ColumnsUsed().ToList())
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
        cell.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;

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
