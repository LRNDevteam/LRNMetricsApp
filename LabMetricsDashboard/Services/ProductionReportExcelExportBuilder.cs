using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Production Report data
/// using the Office 2013–2022 blue (Accent 1) / amber (Accent 2) colour palette
/// that matches the on-screen dark-navy / amber header display.
/// Headers use merged cells mirroring the view table layout exactly.
/// </summary>
public static class ProductionReportExcelExportBuilder
{
    /// <summary>Creates the workbook from the Production Report view model.</summary>
    public static XLWorkbook CreateWorkbook(ProductionReportViewModel vm, string labName)
    {
        var wb = new XLWorkbook();

        BuildMonthlySheet(wb, vm, labName);
        BuildWeeklySheet(wb, vm);
        BuildCodingSheet(wb, vm);
        BuildPayerBreakdownSheet(wb, vm);
        BuildPayerPanelSheet(wb, vm);
        BuildUnbilledAgingSheet(wb, vm);
        BuildCptBreakdownSheet(wb, vm);

        WriteFilterFooter(wb, vm);

        return wb;
    }

    // ?? Monthly Claim Volume ?????????????????????????????????????????????

    private static void BuildMonthlySheet(XLWorkbook wb, ProductionReportViewModel vm, string labName)
    {
        var ws = wb.AddWorksheet("Monthly Claim Volume");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        var validYears = vm.Years.Where(y => y > 1900).ToList();
        var validMonths = vm.Months.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var monthsByYear = validMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        int colCount = 1;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            colCount += mons.Count * 2 + 2;
        }
        colCount += 2;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, $"Monthly Claim Volume \u2014 {labName}");
        row++;

        // ?? Header Row 1: year grouping ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Panel & Insurance", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            int span = mons.Count * 2 + 2;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1,
                $"Data based on Billed Date \u2014 {year}", ExcelTheme.BlueHeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // ?? Header Row 2: month names + year total ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, MonthLabel(mk), ExcelTheme.BlueSubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"{year} Total", ExcelTheme.AmberHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.AmberDarkBg);

        // ?? Header Row 3: "No. of Claims" / "Total Billed Charges" ??
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.BlueSubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Total Billed Charges", ExcelTheme.BlueSubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.AmberHeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Total Billed Charges", ExcelTheme.AmberHeaderBg);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow3, hCol, "Total Billed Charges", ExcelTheme.AmberDarkBg);

        row = hRow3 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var panel in vm.PanelRows)
        {
            var bg = ExcelTheme.GetBlueRowBg(dataIdx, isGroupRow: true);
            int col = 1;
            WriteCell(ws, row, col++, panel.PanelName, bg, isText: true);

            foreach (var year in validYears)
            {
                var mons = monthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    var cell = GetMonthCell(panel.ByMonth, mk);
                    WriteCell(ws, row, col++, cell.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
                }
                var yt = GetYearTotal(panel.ByYear, year);
                WriteCell(ws, row, col++, yt.ClaimCount, bg);
                WriteCurrencyCell(ws, row, col++, yt.BilledCharges, bg);
            }
            WriteCell(ws, row, col++, panel.TotalClaims, bg);
            WriteCurrencyCell(ws, row, col++, panel.TotalCharges, bg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            foreach (var payer in panel.TopPayers)
            {
                dataIdx++;
                bg = ExcelTheme.GetBlueRowBg(dataIdx);
                col = 1;
                WriteCell(ws, row, col++, $"  {payer.PayerName}", bg, isText: true);
                foreach (var year in validYears)
                {
                    var mons = monthsByYear.GetValueOrDefault(year, []);
                    foreach (var mk in mons)
                    {
                        var cell = GetMonthCell(payer.ByMonth, mk);
                        WriteCell(ws, row, col++, cell.ClaimCount, bg);
                        WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
                    }
                    var yt = GetYearTotal(payer.ByYear, year);
                    WriteCell(ws, row, col++, yt.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, yt.BilledCharges, bg);
                }
                WriteCell(ws, row, col++, payer.TotalClaims, bg);
                WriteCurrencyCell(ws, row, col++, payer.TotalCharges, bg);
                row++;
            }
            dataIdx++;
        }

        // Grand total row
        ExcelTheme.StyleBlueTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                var cell = GetMonthCell(vm.GrandTotalByMonth, mk);
                ws.Cell(row, gtCol).Value = cell.ClaimCount;
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                ws.Cell(row, gtCol).Value = cell.BilledCharges;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            int yClaims = vm.GrandTotalByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.ClaimCount);
            decimal yCharges = vm.GrandTotalByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.BilledCharges);
            ws.Cell(row, gtCol).Value = yClaims;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        int filteredGrandClaims = vm.GrandTotalByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.ClaimCount);
        decimal filteredGrandCharges = vm.GrandTotalByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.BilledCharges);
        ws.Cell(row, gtCol).Value = filteredGrandClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = filteredGrandCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Weekly Claim Volume ??????????????????????????????????????????????

    private static void BuildWeeklySheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.WeeklyPanelRows.Count == 0) return;

        var ws = wb.AddWorksheet("Weekly Claim Volume");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        var weeks = vm.WeekColumns;
        int colCount = 1 + weeks.Count * 2 + 2;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, "Weekly Claim Volume");
        row++;

        // ?? Header Row 1 ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Panel & Insurance", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        int weekDataSpan = weeks.Count * 2;
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + weekDataSpan - 1,
            "Data based on Last 4 Week [FirstBilledDate]", ExcelTheme.BlueHeaderBg);
        hCol += weekDataSpan;
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // ?? Header Row 2: week date ranges ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var w in weeks)
        {
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1,
                $"{w.WeekStart:M/d/yyyy} \u2013 {w.WeekEnd:M/d/yyyy}", ExcelTheme.BlueSubHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.AmberDarkBg);

        // ?? Header Row 3: sub-column labels ??
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var _ in weeks)
        {
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.BlueSubHeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Total Billed Charges", ExcelTheme.BlueSubHeaderBg);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow3, hCol, "Total Billed Charges", ExcelTheme.AmberDarkBg);

        row = hRow3 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var panel in vm.WeeklyPanelRows)
        {
            var bg = ExcelTheme.GetBlueRowBg(dataIdx, isGroupRow: true);
            int col = 1;
            WriteCell(ws, row, col++, panel.PanelName, bg, isText: true);
            foreach (var w in weeks)
            {
                var cell = GetMonthCell(panel.ByWeek, w.Key);
                WriteCell(ws, row, col++, cell.ClaimCount, bg);
                WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
            }
            WriteCell(ws, row, col++, panel.TotalClaims, bg);
            WriteCurrencyCell(ws, row, col++, panel.TotalCharges, bg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            foreach (var payer in panel.TopPayers)
            {
                dataIdx++;
                bg = ExcelTheme.GetBlueRowBg(dataIdx);
                col = 1;
                WriteCell(ws, row, col++, $"  {payer.PayerName}", bg, isText: true);
                foreach (var w in weeks)
                {
                    var cell = GetMonthCell(payer.ByWeek, w.Key);
                    WriteCell(ws, row, col++, cell.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
                }
                WriteCell(ws, row, col++, payer.TotalClaims, bg);
                WriteCurrencyCell(ws, row, col++, payer.TotalCharges, bg);
                row++;
            }
            dataIdx++;
        }

        // Grand total
        ExcelTheme.StyleBlueTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var w in weeks)
        {
            var cell = GetMonthCell(vm.WeeklyGrandTotalByWeek, w.Key);
            ws.Cell(row, gtCol).Value = cell.ClaimCount;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = cell.BilledCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.WeeklyGrandTotalClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.WeeklyGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Coding ???????????????????????????????????????????????????????????

    private static void BuildCodingSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.CodingPanelRows.Count == 0) return;

        var ws = wb.AddWorksheet("Coding");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        const int colCount = 3;
        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, "Coding (Unbilled)");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1, ["Panel Name", "Claim Count", "Total Charge"], ExcelTheme.BlueHeaderBg);
        row++;

        int dataIdx = 0;
        foreach (var panel in vm.CodingPanelRows)
        {
            var bg = ExcelTheme.GetBlueRowBg(dataIdx, isGroupRow: true);
            WriteCell(ws, row, 1, panel.PanelName, bg, isText: true);
            WriteCell(ws, row, 2, panel.ClaimCount, bg);
            WriteCurrencyCell(ws, row, 3, panel.TotalCharges, bg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            foreach (var cpt in panel.CptRows)
            {
                dataIdx++;
                bg = ExcelTheme.GetBlueRowBg(dataIdx);
                WriteCell(ws, row, 1, $"  {cpt.CptCodeUnitsModifier}", bg, isText: true);
                WriteCell(ws, row, 2, cpt.ClaimCount, bg);
                WriteCurrencyCell(ws, row, 3, cpt.TotalCharges, bg);
                row++;
            }
            dataIdx++;
        }

        ExcelTheme.StyleBlueTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Grand Total";
        ws.Cell(row, 2).Value = vm.CodingGrandTotalClaims;
        ws.Cell(row, 2).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, 3).Value = vm.CodingGrandTotalCharges;
        ws.Cell(row, 3).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Payer Breakdown ??????????????????????????????????????????????????

    private static void BuildPayerBreakdownSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.PayerBreakdownRows.Count == 0) return;

        var ws = wb.AddWorksheet("Payer Breakdown");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        var pbYears = vm.PayerBreakdownYears.Where(y => y > 1900).ToList();
        var pbMonths = vm.PayerBreakdownMonths.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var pbMonthsByYear = pbMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        int colCount = 1;
        foreach (var year in pbYears)
            colCount += pbMonthsByYear.GetValueOrDefault(year, []).Count + 1;
        colCount += 1;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, "Payer Breakdown (Charge Entered Date)");
        row++;

        // ?? Header Row 1: year groups ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Payer", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            int span = mons.Count + 1;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1, year.ToString(), ExcelTheme.BlueHeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1 + 1, hCol, hCol, "Grand Total", ExcelTheme.AmberDarkBg);

        // ?? Header Row 2: month names + year total ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
                WriteHeaderCell(ws, hRow2, hCol++, MonthLabel(mk), ExcelTheme.BlueSubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, $"Year {year} Total", ExcelTheme.AmberHeaderBg);
        }

        row = hRow2 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var pr in vm.PayerBreakdownRows)
        {
            var bg = ExcelTheme.GetBlueRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PayerName, bg, isText: true);
            foreach (var year in pbYears)
            {
                var mons = pbMonthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    int v = pr.ByMonth.GetValueOrDefault(mk, 0);
                    WriteCell(ws, row, col++, v, bg);
                }
                int yt = pr.ByYear.GetValueOrDefault(year, 0);
                WriteCell(ws, row, col++, yt, bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotal, bg);
            row++;
            dataIdx++;
        }

        // Grand total row
        ExcelTheme.StyleBlueTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandByMonth.GetValueOrDefault(mk, 0);
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            }
            int yTotal = vm.PayerBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            ws.Cell(row, gtCol).Value = yTotal;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        }
        ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandTotal;
        ws.Cell(row, gtCol).Style.NumberFormat.NumberFormatId = 3;

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Payer X Panel ????????????????????????????????????????????????????

    private static void BuildPayerPanelSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.PayerPanelRows.Count == 0) return;

        var ws = wb.AddWorksheet("Payer X Panel");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        var panels = vm.PayerPanelColumns;
        int colCount = 1 + panels.Count * 2 + 2;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, "Payer X Panel");
        row++;

        // ?? Header Row 1 ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Payer x Panel", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var p in panels)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, p, ExcelTheme.BlueHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // ?? Header Row 2 ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in panels)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.BlueSubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Total Billed Charges", ExcelTheme.BlueSubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow2, hCol, "Total Billed Charges", ExcelTheme.AmberDarkBg);

        row = hRow2 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var pr in vm.PayerPanelRows)
        {
            var bg = ExcelTheme.GetBlueRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PayerName, bg, isText: true);
            foreach (var p in panels)
            {
                var cell = GetMonthCell(pr.ByPanel, p);
                WriteCell(ws, row, col++, cell.ClaimCount, bg);
                WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotalClaims, bg);
            WriteCurrencyCell(ws, row, col++, pr.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleBlueTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var p in panels)
        {
            var cell = GetMonthCell(vm.PayerPanelGrandByPanel, p);
            ws.Cell(row, gtCol).Value = cell.ClaimCount;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = cell.BilledCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.PayerPanelGrandTotalClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.PayerPanelGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Unbilled X Aging ?????????????????????????????????????????????????

    private static void BuildUnbilledAgingSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.UnbilledAgingRows.Count == 0) return;

        var ws = wb.AddWorksheet("Unbilled X Aging");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        var buckets = AgingBuckets.All;
        int colCount = 1 + buckets.Count * 2 + 2;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, "Unbilled X Aging");
        row++;

        // ?? Header Row 1 ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Unbilled x Aging", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var b in buckets)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, b, ExcelTheme.BlueHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // ?? Header Row 2 ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in buckets)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.BlueSubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Total Billed Charges", ExcelTheme.BlueSubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow2, hCol, "Total Billed Charges", ExcelTheme.AmberDarkBg);

        row = hRow2 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var pr in vm.UnbilledAgingRows)
        {
            var bg = ExcelTheme.GetBlueRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PanelName, bg, isText: true);
            foreach (var b in buckets)
            {
                var cell = GetMonthCell(pr.ByBucket, b);
                WriteCell(ws, row, col++, cell.ClaimCount, bg);
                WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotalClaims, bg);
            WriteCurrencyCell(ws, row, col++, pr.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleBlueTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var b in buckets)
        {
            var cell = GetMonthCell(vm.UnbilledAgingGrandByBucket, b);
            ws.Cell(row, gtCol).Value = cell.ClaimCount;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = cell.BilledCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.UnbilledAgingGrandTotalClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.UnbilledAgingGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? CPT Breakdown ????????????????????????????????????????????????????

    private static void BuildCptBreakdownSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.CptBreakdownRows.Count == 0) return;

        var ws = wb.AddWorksheet("CPT Breakdown");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        var cptYears = vm.CptBreakdownYears.Where(y => y > 1900).ToList();
        var cptMonths = vm.CptBreakdownMonths.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var cptMonthsByYear = cptMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        int colCount = 1;
        foreach (var year in cptYears)
            colCount += cptMonthsByYear.GetValueOrDefault(year, []).Count * 2 + 2;
        colCount += 2;

        int row = 1;
        ExcelTheme.WriteBlueTitleBar(ws, row, colCount, "CPT Breakdown (Billed Date)");
        row++;

        // ?? Header Row 1: year grouping ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "CPT Codes", ExcelTheme.BlueHeaderBg);
        int hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            int span = mons.Count * 2 + 2;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1, year.ToString(), ExcelTheme.BlueHeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.AmberDarkBg);

        // ?? Header Row 2: month names + year total ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, MonthLabel(mk), ExcelTheme.BlueSubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"Year {year} Total", ExcelTheme.AmberHeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.AmberDarkBg);

        // ?? Header Row 3: "Billed Units" | "Billed Amount" ??
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "Billed Units", ExcelTheme.BlueSubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Billed Amount", ExcelTheme.BlueSubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "Billed Units", ExcelTheme.AmberHeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Billed Amount", ExcelTheme.AmberHeaderBg);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "Billed Units", ExcelTheme.AmberDarkBg);
        WriteHeaderCell(ws, hRow3, hCol, "Billed Amount", ExcelTheme.AmberDarkBg);

        row = hRow3 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var cptRow in vm.CptBreakdownRows)
        {
            var bg = ExcelTheme.GetBlueRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, cptRow.CptCode, bg, isText: true);
            foreach (var year in cptYears)
            {
                var mons = cptMonthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    var cell = GetCptCell(cptRow.ByMonth, mk);
                    WriteDecimalCell(ws, row, col++, cell.Units, bg);
                    WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
                }
                var yt = GetCptCell(cptRow.ByYear, year);
                WriteDecimalCell(ws, row, col++, yt.Units, bg);
                WriteCurrencyCell(ws, row, col++, yt.BilledCharges, bg);
            }
            WriteDecimalCell(ws, row, col++, cptRow.GrandTotalUnits, bg);
            WriteCurrencyCell(ws, row, col++, cptRow.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        // Grand total row
        ExcelTheme.StyleBlueTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                var cell = GetCptCell(vm.CptBreakdownGrandByMonth, mk);
                ws.Cell(row, gtCol).Value = cell.Units;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "#,##0";
                ws.Cell(row, gtCol).Value = cell.BilledCharges;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            decimal yUnits = vm.CptBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.Units);
            decimal yCharges = vm.CptBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.BilledCharges);
            ws.Cell(row, gtCol).Value = yUnits;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "#,##0";
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        decimal cptGrandUnits = vm.CptBreakdownGrandByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.Units);
        decimal cptGrandCharges = vm.CptBreakdownGrandByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.BilledCharges);
        ws.Cell(row, gtCol).Value = cptGrandUnits;
        ws.Cell(row, gtCol++).Style.NumberFormat.Format = "#,##0";
        ws.Cell(row, gtCol).Value = cptGrandCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Filter footer ????????????????????????????????????????????????????

    private static void WriteFilterFooter(XLWorkbook wb, ProductionReportViewModel vm)
    {
        var ws = wb.Worksheets.First();
        int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;

        var filters = new List<(string Label, IReadOnlyList<string>? Values)>
        {
            ("Payer Name", vm.FilterPayerNames is { Count: > 0 } ? vm.FilterPayerNames : null),
            ("Panel Name", vm.FilterPanelNames is { Count: > 0 } ? vm.FilterPanelNames : null),
            ("First Bill From", string.IsNullOrWhiteSpace(vm.FilterFirstBillFrom) ? null : new[] { vm.FilterFirstBillFrom }),
            ("First Bill To", string.IsNullOrWhiteSpace(vm.FilterFirstBillTo) ? null : new[] { vm.FilterFirstBillTo }),
        };

        ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 3, filters);
    }

    // ?? Helpers ??????????????????????????????????????????????????????????

    private static string MonthLabel(string ym)
    {
        var parts = ym.Split('-');
        return new DateTime(int.Parse(parts[0]), int.Parse(parts[1]), 1).ToString("MMM");
    }

    private static ProductionMonthCell GetMonthCell(Dictionary<string, ProductionMonthCell>? d, string key)
        => d is not null && d.TryGetValue(key, out var c) ? c : new ProductionMonthCell(0, 0m);

    private static ProductionYearTotal GetYearTotal(Dictionary<int, ProductionYearTotal>? d, int year)
        => d is not null && d.TryGetValue(year, out var t) ? t : new ProductionYearTotal(0, 0m);

    private static CptBreakdownCell GetCptCell(Dictionary<string, CptBreakdownCell>? d, string key)
        => d is not null && d.TryGetValue(key, out var c) ? c : new CptBreakdownCell(0m, 0m);

    private static CptBreakdownCell GetCptCell(Dictionary<int, CptBreakdownCell>? d, int key)
        => d is not null && d.TryGetValue(key, out var c) ? c : new CptBreakdownCell(0m, 0m);

    /// <summary>Writes a merged header cell spanning the given row/column range.</summary>
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

    /// <summary>Writes a single (non-merged) header cell.</summary>
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

    private static void WriteCell(IXLWorksheet ws, int row, int col, string value, XLColor bg, bool isText = false)
    {
        var cell = ws.Cell(row, col);
        cell.Value = value;
        ExcelTheme.StyleDataCell(cell, bg);
        if (isText) cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
    }

    private static void WriteCell(IXLWorksheet ws, int row, int col, int value, XLColor bg)
    {
        var cell = ws.Cell(row, col);
        cell.Value = value;
        cell.Style.NumberFormat.NumberFormatId = 3; // #,##0
        ExcelTheme.StyleDataCell(cell, bg);
    }

    private static void WriteCurrencyCell(IXLWorksheet ws, int row, int col, decimal value, XLColor bg)
    {
        var cell = ws.Cell(row, col);
        cell.Value = value;
        cell.Style.NumberFormat.Format = "$#,##0";
        ExcelTheme.StyleDataCell(cell, bg);
    }

    private static void WriteDecimalCell(IXLWorksheet ws, int row, int col, decimal value, XLColor bg)
    {
        var cell = ws.Cell(row, col);
        cell.Value = value;
        cell.Style.NumberFormat.Format = "#,##0";
        ExcelTheme.StyleDataCell(cell, bg);
    }
}
