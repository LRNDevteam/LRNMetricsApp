using ClosedXML.Excel;
using LRN.ProductionReports.Models;
using LRN.ProductionReports.Services;
using Microsoft.Extensions.Logging;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook for the NorthWest Production Summary Report.
/// All sheets use the Office 2013�2022 green (Accent 6) colour palette from
/// <see cref="ExcelTheme"/> � matching the Page Layout ? Colors ? Office 2013�2022 theme:
/// <list type="bullet">
///   <item>Title bars   � <c>TitleBg  #385723</c> (Accent 6 Darker 50 %)</item>
///   <item>Column-group headers � <c>HeaderBg  #548235</c> (Accent 6 Darker 25 %)</item>
///   <item>Month / sub-section � <c>SubHeaderBg  #70AD47</c> (Accent 6 base)</item>
///   <item>Panel / group rows  � <c>GroupRowBg  #C5E0B4</c> (Accent 6 Lighter 60 %)</item>
///   <item>Banded data rows    � <c>BandedRowBg  #E2EFDA</c> (Accent 6 Lighter 80 %)</item>
///   <item>Total row           � <c>TotalRowBg  #A9D18E</c> (Accent 6 Lighter 40 %)</item>
///   <item>Year / grand-total highlight � <c>GoldAccent  #FFC000</c> (Accent 4)</item>
/// </list>
/// </summary>
public static class NorthWestProductionSummaryExcelExportBuilder
{
    /// <summary>Row threshold above which raw-data is split into multiple sheets (3 lakh).</summary>
    private const int SplitThreshold = 300_000;

    /// <summary>Maximum rows written per raw-data sheet to prevent out-of-memory.</summary>
    private const int MaxRawDataRows = 500_000;

    // ?? Pre-splitting ?????????????????????????????????????????????????????????

    /// <summary>
    /// Pre-computes sheet segments for a NorthWest raw-data table
    /// (ClaimLevelData or LineLevelData) <b>before</b> the workbook is created.
    /// NW rows are split by <c>ChargeEnteredDate</c> year (NW's primary date column).
    /// <list type="bullet">
    ///   <item>? 3 lakh rows ? one segment named <paramref name="baseSheetName"/>.</item>
    ///   <item>&gt; 3 lakh ? split by year; years still exceeding 3 lakh are further split by month.</item>
    /// </list>
    /// Sheet names: <c>YYYY_BaseName</c> or <c>YYYY_MM_BaseName</c>, truncated to 31 chars.
    /// </summary>
    public static List<RawDataSegment> PreSplitRawData(
        string baseSheetName, string[] columns, List<object?[]> rows)
    {
        var segments = new List<RawDataSegment>();

        if (rows.Count == 0)
        {
            segments.Add(new RawDataSegment(baseSheetName, columns, rows));
            return segments;
        }

        if (rows.Count <= SplitThreshold)
        {
            segments.Add(new RawDataSegment(baseSheetName, columns, rows));
            return segments;
        }

        // Group by ChargeEnteredDate year (NW primary date), fallback to FirstBilledDate, then 0 (Unknown).
        var byYear = rows
            .GroupBy(r => GetChargeEnteredYear(columns, r))
            .OrderBy(g => g.Key)
            .ToList();

        foreach (var yearGroup in byYear)
        {
            int year      = yearGroup.Key;
            string label  = year > 0 ? year.ToString() : "Unknown";
            var yearRows  = yearGroup.ToList();

            if (yearRows.Count <= SplitThreshold)
            {
                segments.Add(new RawDataSegment(
                    Truncate($"{label}_{baseSheetName}"), columns, yearRows));
            }
            else
            {
                // Split further by month
                foreach (var monthGroup in yearRows
                    .GroupBy(r => GetChargeEnteredMonth(columns, r))
                    .OrderBy(g => g.Key))
                {
                    if (monthGroup.Any())
                        segments.Add(new RawDataSegment(
                            Truncate($"{label}_{monthGroup.Key:D2}_{baseSheetName}"),
                            columns,
                            monthGroup.ToList()));
                }
            }
        }

        return segments;
    }

    // ?? Public entry points ???????????????????????????????????????????????????

    /// <summary>
    /// Creates the NorthWest Production Summary workbook from the view model (summary sheets only).
    /// </summary>
    public static XLWorkbook CreateWorkbook(ProductionReportViewModel vm, string labName)
    {
        var wb = new XLWorkbook();

        BuildMonthlyAndWeeklySheet(wb, vm, labName);
        BuildCodingSheet(wb, vm);
        BuildPayerBreakdownSheet(wb, vm);
        BuildPanelBreakdownSheet(wb, vm);
        BuildPayerMonthBreakdownSheet(wb, "Insight Daq", "Insight Daq — Top 10 Payers (Charge Entered Date)", "Payer",
            vm.InsightDaqRows, vm.InsightDaqYears, vm.InsightDaqMonths,
            vm.InsightDaqGrandByMonth, vm.InsightDaqGrandChargesByMonth,
            vm.InsightDaqGrandTotal, vm.InsightDaqGrandTotalCharges);
        BuildPayerMonthBreakdownSheet(wb, "Insight WebPM", "Insight WebPM — Top 10 Payers (Charge Entered Date)", "Payer",
            vm.InsightWebPmRows, vm.InsightWebPmYears, vm.InsightWebPmMonths,
            vm.InsightWebPmGrandByMonth, vm.InsightWebPmGrandChargesByMonth,
            vm.InsightWebPmGrandTotal, vm.InsightWebPmGrandTotalCharges);
        BuildHighestPayerSheet(wb, vm);
        BuildPayerPanelSheet(wb, vm);
        BuildUnbilledAgingSheet(wb, vm);
        BuildCptBreakdownSheet(wb, vm);
        WriteFilterFooter(wb, vm);

        return wb;
    }

    /// <summary>
    /// Creates the NorthWest Production Summary workbook including raw
    /// ClaimLevelData and LineLevelData sheets from pre-split segments.
    /// Call <see cref="PreSplitRawData"/> for each dataset before invoking this method
    /// so that the heavy split step happens before the ClosedXML object graph is created.
    /// </summary>
    public static XLWorkbook CreateWorkbook(
        ProductionReportViewModel vm,
        string labName,
        IReadOnlyList<RawDataSegment> claimSegments,
        IReadOnlyList<RawDataSegment> lineSegments,
        ILogger? logger = null)
    {
        var wb = new XLWorkbook();

        BuildMonthlyAndWeeklySheet(wb, vm, labName);
        BuildCodingSheet(wb, vm);
        BuildPayerBreakdownSheet(wb, vm);
        BuildPanelBreakdownSheet(wb, vm);
        BuildPayerMonthBreakdownSheet(wb, "Insight Daq", "Insight Daq — Top 10 Payers (Charge Entered Date)", "Payer",
            vm.InsightDaqRows, vm.InsightDaqYears, vm.InsightDaqMonths,
            vm.InsightDaqGrandByMonth, vm.InsightDaqGrandChargesByMonth,
            vm.InsightDaqGrandTotal, vm.InsightDaqGrandTotalCharges);
        BuildPayerMonthBreakdownSheet(wb, "Insight WebPM", "Insight WebPM — Top 10 Payers (Charge Entered Date)", "Payer",
            vm.InsightWebPmRows, vm.InsightWebPmYears, vm.InsightWebPmMonths,
            vm.InsightWebPmGrandByMonth, vm.InsightWebPmGrandChargesByMonth,
            vm.InsightWebPmGrandTotal, vm.InsightWebPmGrandTotalCharges);
        BuildHighestPayerSheet(wb, vm);
        BuildPayerPanelSheet(wb, vm);
        BuildUnbilledAgingSheet(wb, vm);
        BuildCptBreakdownSheet(wb, vm);

        int idx = 0;
        foreach (var seg in claimSegments)
        {
            BuildRawDataSheet(wb, seg.SheetName, seg.Columns, seg.Rows, labName, ExcelTheme.TabGreen);
            logger?.LogInformation(
                "[NWExcelExport][Sheet] ClaimLevel {Idx}/{Total} '{Name}' ({Rows:N0} rows)",
                ++idx, claimSegments.Count, seg.SheetName, seg.Rows.Count);
        }

        idx = 0;
        foreach (var seg in lineSegments)
        {
            BuildRawDataSheet(wb, seg.SheetName, seg.Columns, seg.Rows, labName, ExcelTheme.TabGold);
            logger?.LogInformation(
                "[NWExcelExport][Sheet] LineLevel {Idx}/{Total} '{Name}' ({Rows:N0} rows)",
                ++idx, lineSegments.Count, seg.SheetName, seg.Rows.Count);
        }

        WriteFilterFooter(wb, vm);

        return wb;
    }


    // ?? Monthly & Weekly Claim Volume ?????????????????????????????????????????

    private static void BuildMonthlyAndWeeklySheet(
        XLWorkbook wb, ProductionReportViewModel vm, string labName)
    {
        var ws = wb.AddWorksheet("MonthlyAndWeeklyVolume");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        // ?? Report metadata block ?????????????????????????????????????????
        int metaRow = 1;
        var metaItems = new[]
        {
            ("Client Name",  labName),
            ("Report Type",  "NorthWest Production Summary"),
            ("Analysis Range", "Billed Date"),
        };
        foreach (var (label, value) in metaItems)
        {
            var lbl = ws.Cell(metaRow, 1);
            lbl.Value = label + ":";
            lbl.Style.Font.Bold = true;
            lbl.Style.Font.FontSize = 9;
            lbl.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;

            var val = ws.Cell(metaRow, 2);
            val.Value = value;
            val.Style.Font.FontSize = 9;
            val.Style.Font.Bold = true;
            val.Style.Font.FontColor = ExcelTheme.TitleBg;
            metaRow++;
        }
        metaRow++; // blank separator

        var validYears  = vm.Years.Where(y => y > 1900).ToList();
        var validMonths = vm.Months.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var monthsByYear = validMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        // Column count: 1 (panel label) + per-year(months�2 + 2 year-total) + 2 grand-total
        int colCount = 1;
        foreach (var year in validYears)
            colCount += monthsByYear.GetValueOrDefault(year, []).Count * 2 + 2;
        colCount += 2;

        int row = metaRow;

        // ?? Title bar ?????????????????????????????????????????????????????
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Production | Date of Entry");
        row++;

        // ?? Header Row 1: "Panel & Top Insurances" + year groups + Grand Total ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1,
            "Panel & Top Insurances", ExcelTheme.HeaderBg);

        int hCol = 2;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            int span = mons.Count * 2 + 2;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1,
                year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1 + 1, hCol, hCol + 1,
            "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // ?? Header Row 2: month name spans + year-total columns ???????????
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1,
                    MonthLabel(mk), ExcelTheme.SubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1,
                $"{year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            hCol += 2;
        }

        // ?? Header Row 3: "No. of Claim" / "Total Billed" sub-labels ??????
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "No. of Claim", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Total Billed",  ExcelTheme.SubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claim",
                ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            WriteHeaderCell(ws, hRow3, hCol++, "Total Billed",
                ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claim",
            ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow3, hCol, "Total Billed",
            ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow3 + 1;

        // ?? Data rows ?????????????????????????????????????????????????????
        int panelIdx = 0;
        foreach (var panel in vm.PanelRows)
        {
            int col = 1;
            WriteCell(ws, row, col++,
                $"{PanelLabel(panelIdx)}  {panel.PanelName}", ExcelTheme.GroupRowBg, isText: true);

            foreach (var year in validYears)
            {
                var mons = monthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    var mc = GetMonthCell(panel.ByMonth, mk);
                    WriteCell(ws, row, col++, mc.ClaimCount, ExcelTheme.GroupRowBg);
                    WriteCurrencyCell(ws, row, col++, mc.BilledCharges, ExcelTheme.GroupRowBg);
                }
                var yt = GetYearTotal(panel.ByYear, year);
                WriteCell(ws, row, col++, yt.ClaimCount, ExcelTheme.GroupRowBg);
                WriteCurrencyCell(ws, row, col++, yt.BilledCharges, ExcelTheme.GroupRowBg);
            }
            WriteCell(ws, row, col++, panel.TotalClaims, ExcelTheme.GroupRowBg);
            WriteCurrencyCell(ws, row, col, panel.TotalCharges, ExcelTheme.GroupRowBg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            int firstChild = row;
            int payerIdx = 0;
            foreach (var payer in panel.TopPayers)
            {
                var bg = payerIdx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
                col = 1;
                WriteCell(ws, row, col++, $"    {payer.PayerName}", bg, isText: true);

                foreach (var year in validYears)
                {
                    var mons = monthsByYear.GetValueOrDefault(year, []);
                    foreach (var mk in mons)
                    {
                        var mc = GetMonthCell(payer.ByMonth, mk);
                        WriteCell(ws, row, col++, mc.ClaimCount, bg);
                        WriteCurrencyCell(ws, row, col++, mc.BilledCharges, bg);
                    }
                    var yt = GetYearTotal(payer.ByYear, year);
                    WriteCell(ws, row, col++, yt.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, yt.BilledCharges, bg);
                }
                WriteCell(ws, row, col++, payer.TotalClaims, bg);
                WriteCurrencyCell(ws, row, col, payer.TotalCharges, bg);
                row++;
                payerIdx++;
            }
            GroupChildRows(ws, firstChild, row - 1);
            panelIdx++;
        }

        // ?? Total row (dark green, white text) ????????????????????????????
        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Total";
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                var mc = GetMonthCell(vm.GrandTotalByMonth, mk);
                ws.Cell(row, gtCol).Value = mc.ClaimCount;
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                ws.Cell(row, gtCol).Value = mc.BilledCharges;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            int   yClaims  = vm.GrandTotalByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.ClaimCount);
            decimal yCharges = vm.GrandTotalByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.BilledCharges);
            ws.Cell(row, gtCol).Value = yClaims;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        int   grandClaims  = vm.GrandTotalByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.ClaimCount);
        decimal grandCharges = vm.GrandTotalByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.BilledCharges);
        ws.Cell(row, gtCol).Value = grandClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = grandCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";
        row++;

        WriteFooterNote(ws, row, colCount,
            "*The above table is based on 'Date of Entry' and the total numbers include 'ALL' claims billed.");
        row++;

        ExcelTheme.AutoFitColumns(ws, colCount);

        // Append weekly section on the same sheet
        if (vm.WeeklyPanelRows.Count > 0)
            AppendWeeklySection(ws, vm, row + 2);

        FinishOutline(ws);
    }

    private static void AppendWeeklySection(IXLWorksheet ws, ProductionReportViewModel vm, int startRow)
    {
        var weeks    = vm.WeekColumns;
        int colCount = 1 + weeks.Count * 2 + 2;

        string weekTitle = "Weekly Breakdown | Date of Entry";
        if (weeks.Count > 0)
        {
            int firstYear = weeks[0].WeekStart.Year;
            int lastYear  = weeks[^1].WeekEnd.Year;
            weekTitle = firstYear == lastYear
                ? $"Weekly Breakdown | Date of Entry | {firstYear}"
                : $"Weekly Breakdown | Date of Entry | {firstYear}�{lastYear}";
        }

        int row = startRow;
        ExcelTheme.WriteTitleBar(ws, row, colCount, weekTitle);
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1,
            "Panel & Insurance", ExcelTheme.HeaderBg);

        int hCol = 2;
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + weeks.Count * 2 - 1,
            "Billed Week", ExcelTheme.HeaderBg);
        WriteMergedHeader(ws, hRow1, hRow1 + 1, hCol + weeks.Count * 2, hCol + weeks.Count * 2 + 1,
            "Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var w in weeks)
        {
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1,
                $"{w.WeekStart:MMM dd} � {w.WeekEnd:MMM dd}", ExcelTheme.SubHeaderBg);
            hCol += 2;
        }

        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var _ in weeks)
        {
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claim", ExcelTheme.SubHeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Total Billed",  ExcelTheme.SubHeaderBg);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claim",
            ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow3, hCol, "Total Billed",
            ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow3 + 1;

        int panelIdx = 0;
        foreach (var panel in vm.WeeklyPanelRows)
        {
            int col = 1;
            WriteCell(ws, row, col++,
                $"{PanelLabel(panelIdx)}  {panel.PanelName}", ExcelTheme.GroupRowBg, isText: true);
            foreach (var w in weeks)
            {
                var mc = GetMonthCell(panel.ByWeek, w.Key);
                WriteCell(ws, row, col++, mc.ClaimCount, ExcelTheme.GroupRowBg);
                WriteCurrencyCell(ws, row, col++, mc.BilledCharges, ExcelTheme.GroupRowBg);
            }
            WriteCell(ws, row, col++, panel.TotalClaims, ExcelTheme.GroupRowBg);
            WriteCurrencyCell(ws, row, col, panel.TotalCharges, ExcelTheme.GroupRowBg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            int firstChild = row;
            int payerIdx = 0;
            foreach (var payer in panel.TopPayers)
            {
                var bg = payerIdx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
                col = 1;
                WriteCell(ws, row, col++, $"    {payer.PayerName}", bg, isText: true);
                foreach (var w in weeks)
                {
                    var mc = GetMonthCell(payer.ByWeek, w.Key);
                    WriteCell(ws, row, col++, mc.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, mc.BilledCharges, bg);
                }
                WriteCell(ws, row, col++, payer.TotalClaims, bg);
                WriteCurrencyCell(ws, row, col, payer.TotalCharges, bg);
                row++;
                payerIdx++;
            }
            GroupChildRows(ws, firstChild, row - 1);
            panelIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Total";
        foreach (var w in weeks)
        {
            var mc = GetMonthCell(vm.WeeklyGrandTotalByWeek, w.Key);
            ws.Cell(row, gtCol).Value = mc.ClaimCount;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = mc.BilledCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.WeeklyGrandTotalClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.WeeklyGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";
        row++;

        WriteFooterNote(ws, row, colCount,
            "*The above table is based on 'Date of Entry' and the total numbers include 'ALL' claims billed.");

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Coding (Unbilled) ?????????????????????????????????????????????????????

    private static void BuildCodingSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.CodingPanelRows.Count == 0) return;

        var ws = wb.AddWorksheet("Coding");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        const int colCount = 3;
        int row = 1;

        ExcelTheme.WriteTitleBar(ws, row, colCount, "Coding (Unbilled)");
        row++;
        ExcelTheme.WriteHeaderRow(ws, row, 1,
            ["Panel Name", "Claim Count", "Total Charge"], ExcelTheme.HeaderBg);
        row++;

        int dataIdx = 0;
        foreach (var panel in vm.CodingPanelRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx, isGroupRow: true);
            WriteCell(ws, row, 1, panel.PanelName, bg, isText: true);
            WriteCell(ws, row, 2, panel.ClaimCount, bg);
            WriteCurrencyCell(ws, row, 3, panel.TotalCharges, bg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            int firstChild = row;
            foreach (var cpt in panel.CptRows)
            {
                dataIdx++;
                bg = ExcelTheme.GetRowBg(dataIdx);
                WriteCell(ws, row, 1, $"  {cpt.CptCodeUnitsModifier}", bg, isText: true);
                WriteCell(ws, row, 2, cpt.ClaimCount, bg);
                WriteCurrencyCell(ws, row, 3, cpt.TotalCharges, bg);
                row++;
            }
            GroupChildRows(ws, firstChild, row - 1);
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Grand Total";
        ws.Cell(row, 2).Value = vm.CodingGrandTotalClaims;
        ws.Cell(row, 2).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, 3).Value = vm.CodingGrandTotalCharges;
        ws.Cell(row, 3).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
        FinishOutline(ws);
    }

    // ?? Payer Breakdown ???????????????????????????????????????????????????????

    private static void BuildPayerBreakdownSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.PayerBreakdownRows.Count == 0) return;

        var ws = wb.AddWorksheet("Payer Breakdown");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var pbYears = vm.PayerBreakdownYears.Where(y => y > 1900).ToList();
        var pbMonths = vm.PayerBreakdownMonths.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var pbMonthsByYear = pbMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        const int metrics = 2;
        int colCount = 1;
        foreach (var year in pbYears)
            colCount += (pbMonthsByYear.GetValueOrDefault(year, []).Count + 1) * metrics;
        colCount += metrics;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Payer Breakdown (Charge Entered Date)");
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Payer", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            int span = (mons.Count + 1) * metrics;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1,
                year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + metrics - 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, MonthLabel(mk), ExcelTheme.SubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.SubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow3, hCol, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow3 + 1;

        int dataIdx = 0;
        foreach (var pr in vm.PayerBreakdownRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PayerName, bg, isText: true);
            foreach (var year in pbYears)
            {
                var mons = pbMonthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    WriteCell(ws, row, col++, pr.ByMonth.GetValueOrDefault(mk, 0), bg);
                    WriteCurrencyCell(ws, row, col++, pr.ByMonthCharges.GetValueOrDefault(mk, 0m), bg);
                }
                WriteCell(ws, row, col++, pr.ByYear.GetValueOrDefault(year, 0), bg);
                WriteCurrencyCell(ws, row, col++, pr.ByYearCharges.GetValueOrDefault(year, 0m), bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotal, bg);
            WriteCurrencyCell(ws, row, col++, pr.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandByMonth.GetValueOrDefault(mk, 0);
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandChargesByMonth.GetValueOrDefault(mk, 0m);
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            int yTotal = vm.PayerBreakdownGrandByMonth
                .Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            decimal yCharges = vm.PayerBreakdownGrandChargesByMonth
                .Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            ws.Cell(row, gtCol).Value = yTotal;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandTotal;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    private static void BuildPanelBreakdownSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.PanelBreakdownRows.Count == 0) return;

        var ws = wb.AddWorksheet("Panel Breakdown");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var years = vm.PanelBreakdownYears.Where(y => y > 1900).ToList();
        var months = vm.PanelBreakdownMonths.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var monthsByYear = months
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        const int metrics = 2;
        int colCount = 1;
        foreach (var year in years)
            colCount += (monthsByYear.GetValueOrDefault(year, []).Count + 1) * metrics;
        colCount += metrics;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Panel Breakdown (Charge Entered Date)");
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Panel", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            int span = (mons.Count + 1) * metrics;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1,
                year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + metrics - 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, MonthLabel(mk), ExcelTheme.SubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.SubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow3, hCol, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow3 + 1;

        int dataIdx = 0;
        foreach (var pr in vm.PanelBreakdownRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PayerName, bg, isText: true);
            foreach (var year in years)
            {
                var mons = monthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    WriteCell(ws, row, col++, pr.ByMonth.GetValueOrDefault(mk, 0), bg);
                    WriteCurrencyCell(ws, row, col++, pr.ByMonthCharges.GetValueOrDefault(mk, 0m), bg);
                }
                WriteCell(ws, row, col++, pr.ByYear.GetValueOrDefault(year, 0), bg);
                WriteCurrencyCell(ws, row, col++, pr.ByYearCharges.GetValueOrDefault(year, 0m), bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotal, bg);
            WriteCurrencyCell(ws, row, col++, pr.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                ws.Cell(row, gtCol).Value = vm.PanelBreakdownGrandByMonth.GetValueOrDefault(mk, 0);
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                ws.Cell(row, gtCol).Value = vm.PanelBreakdownGrandChargesByMonth.GetValueOrDefault(mk, 0m);
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            int yTotal = vm.PanelBreakdownGrandByMonth
                .Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            decimal yCharges = vm.PanelBreakdownGrandChargesByMonth
                .Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            ws.Cell(row, gtCol).Value = yTotal;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.PanelBreakdownGrandTotal;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.PanelBreakdownGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    private static void BuildPayerMonthBreakdownSheet(
        XLWorkbook wb,
        string sheetName,
        string title,
        string rowHeader,
        List<PayerBreakdownRow> rows,
        List<int> yearsAll,
        List<string> monthsAll,
        Dictionary<string, int> grandByMonth,
        Dictionary<string, decimal> grandChargesByMonth,
        int grandTotal,
        decimal grandTotalCharges)
    {
        if (rows.Count == 0) return;

        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var years = yearsAll.Where(y => y > 1900).ToList();
        var months = monthsAll.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var monthsByYear = months
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        const int metrics = 2;
        int colCount = 1;
        foreach (var year in years)
            colCount += (monthsByYear.GetValueOrDefault(year, []).Count + 1) * metrics;
        colCount += metrics;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, title);
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, rowHeader, ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            int span = (mons.Count + 1) * metrics;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1, year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + metrics - 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, MonthLabel(mk), ExcelTheme.SubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.SubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow3, hCol, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow3 + 1;
        int dataIdx = 0;
        foreach (var pr in rows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PayerName, bg, isText: true);
            foreach (var year in years)
            {
                var mons = monthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    WriteCell(ws, row, col++, pr.ByMonth.GetValueOrDefault(mk, 0), bg);
                    WriteCurrencyCell(ws, row, col++, pr.ByMonthCharges.GetValueOrDefault(mk, 0m), bg);
                }
                WriteCell(ws, row, col++, pr.ByYear.GetValueOrDefault(year, 0), bg);
                WriteCurrencyCell(ws, row, col++, pr.ByYearCharges.GetValueOrDefault(year, 0m), bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotal, bg);
            WriteCurrencyCell(ws, row, col++, pr.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                ws.Cell(row, gtCol).Value = grandByMonth.GetValueOrDefault(mk, 0);
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                ws.Cell(row, gtCol).Value = grandChargesByMonth.GetValueOrDefault(mk, 0m);
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            int yTotal = grandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            decimal yCharges = grandChargesByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            ws.Cell(row, gtCol).Value = yTotal;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = grandTotal;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = grandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    private static void BuildHighestPayerSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.HighestPayerRows.Count == 0) return;

        var ws = wb.AddWorksheet("Highest Payer Breakdown");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var years = vm.HighestPayerYears.Where(y => y > 1900).ToList();
        var months = vm.HighestPayerMonths.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var monthsByYear = months
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        const int metrics = 2;
        int colCount = 1;
        foreach (var year in years)
            colCount += (monthsByYear.GetValueOrDefault(year, []).Count + 1) * metrics;
        colCount += metrics;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Highest Payer Breakdown — Source / Payer (Charge Entered Date)");
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Source & Payer", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            int span = (mons.Count + 1) * metrics;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1, year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + metrics - 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, MonthLabel(mk), ExcelTheme.SubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.SubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            WriteHeaderCell(ws, hRow3, hCol++, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow3, hCol, "Charge Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow3 + 1;
        foreach (var src in vm.HighestPayerRows)
        {
            int col = 1;
            WriteCell(ws, row, col++, src.PanelName, ExcelTheme.GroupRowBg, isText: true);
            foreach (var year in years)
            {
                var mons = monthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    var mc = GetMonthCell(src.ByMonth, mk);
                    WriteCell(ws, row, col++, mc.ClaimCount, ExcelTheme.GroupRowBg);
                    WriteCurrencyCell(ws, row, col++, mc.BilledCharges, ExcelTheme.GroupRowBg);
                }
                var yt = GetYearTotal(src.ByYear, year);
                WriteCell(ws, row, col++, yt.ClaimCount, ExcelTheme.GroupRowBg);
                WriteCurrencyCell(ws, row, col++, yt.BilledCharges, ExcelTheme.GroupRowBg);
            }
            WriteCell(ws, row, col++, src.TotalClaims, ExcelTheme.GroupRowBg);
            WriteCurrencyCell(ws, row, col, src.TotalCharges, ExcelTheme.GroupRowBg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            int firstChild = row;
            int payerIdx = 0;
            foreach (var payer in src.TopPayers)
            {
                var bg = payerIdx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
                col = 1;
                WriteCell(ws, row, col++, $"    {payer.PayerName}", bg, isText: true);
                foreach (var year in years)
                {
                    var mons = monthsByYear.GetValueOrDefault(year, []);
                    foreach (var mk in mons)
                    {
                        var mc = GetMonthCell(payer.ByMonth, mk);
                        WriteCell(ws, row, col++, mc.ClaimCount, bg);
                        WriteCurrencyCell(ws, row, col++, mc.BilledCharges, bg);
                    }
                    var yt = GetYearTotal(payer.ByYear, year);
                    WriteCell(ws, row, col++, yt.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, yt.BilledCharges, bg);
                }
                WriteCell(ws, row, col++, payer.TotalClaims, bg);
                WriteCurrencyCell(ws, row, col, payer.TotalCharges, bg);
                row++;
                payerIdx++;
            }
            GroupChildRows(ws, firstChild, row - 1);
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in years)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                var mc = GetMonthCell(vm.HighestPayerGrandByMonth, mk);
                ws.Cell(row, gtCol).Value = mc.ClaimCount;
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                ws.Cell(row, gtCol).Value = mc.BilledCharges;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            int yClaims = vm.HighestPayerGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.ClaimCount);
            decimal yCharges = vm.HighestPayerGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.BilledCharges);
            ws.Cell(row, gtCol).Value = yClaims;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.HighestPayerGrandTotalClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.HighestPayerGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
        FinishOutline(ws);
    }

    // ?? Payer � Panel ?????????????????????????????????????????????????????????

    private static void BuildPayerPanelSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.PayerPanelRows.Count == 0) return;

        var ws = wb.AddWorksheet("Payer X Panel");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var panels   = vm.PayerPanelColumns;
        int colCount = 1 + panels.Count * 2 + 2;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Payer � Panel");
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Payer � Panel", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var p in panels)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, p, ExcelTheme.HeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1,
            "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in panels)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims",        ExcelTheme.SubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Total Billed Charges", ExcelTheme.SubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims",        ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow2, hCol,   "Total Billed Charges", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow2 + 1;

        int dataIdx = 0;
        foreach (var pr in vm.PayerPanelRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PayerName, bg, isText: true);
            foreach (var p in panels)
            {
                var mc = GetMonthCell(pr.ByPanel, p);
                WriteCell(ws, row, col++, mc.ClaimCount, bg);
                WriteCurrencyCell(ws, row, col++, mc.BilledCharges, bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotalClaims, bg);
            WriteCurrencyCell(ws, row, col++, pr.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var p in panels)
        {
            var mc = GetMonthCell(vm.PayerPanelGrandByPanel, p);
            ws.Cell(row, gtCol).Value = mc.ClaimCount;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = mc.BilledCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.PayerPanelGrandTotalClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.PayerPanelGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Unbilled � Aging ??????????????????????????????????????????????????????

    private static void BuildUnbilledAgingSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.UnbilledAgingRows.Count == 0) return;

        var ws = wb.AddWorksheet("Unbilled X Aging");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var buckets  = AgingBuckets.All;
        int colCount = 1 + buckets.Count * 2 + 2;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Unbilled � Aging");
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Unbilled � Aging", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var b in buckets)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, b, ExcelTheme.HeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1,
            "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in buckets)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims",        ExcelTheme.SubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Total Billed Charges", ExcelTheme.SubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims",        ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow2, hCol,   "Total Billed Charges", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow2 + 1;

        int dataIdx = 0;
        foreach (var pr in vm.UnbilledAgingRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, pr.PanelName, bg, isText: true);
            foreach (var b in buckets)
            {
                var mc = GetMonthCell(pr.ByBucket, b);
                WriteCell(ws, row, col++, mc.ClaimCount, bg);
                WriteCurrencyCell(ws, row, col++, mc.BilledCharges, bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotalClaims, bg);
            WriteCurrencyCell(ws, row, col++, pr.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var b in buckets)
        {
            var mc = GetMonthCell(vm.UnbilledAgingGrandByBucket, b);
            ws.Cell(row, gtCol).Value = mc.ClaimCount;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = mc.BilledCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        ws.Cell(row, gtCol).Value = vm.UnbilledAgingGrandTotalClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = vm.UnbilledAgingGrandTotalCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? CPT Breakdown ?????????????????????????????????????????????????????????

    private static void BuildCptBreakdownSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.CptBreakdownRows.Count == 0) return;

        var ws = wb.AddWorksheet("CPT Breakdown");
        ws.TabColor = ExcelTheme.TabGreen;
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
        ExcelTheme.WriteTitleBar(ws, row, colCount, "CPT Breakdown (Billed Date)");
        row++;

        // Header Row 1: year groups
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "CPT Codes", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            int span = mons.Count * 2 + 2;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1,
                year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1,
            "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // Header Row 2: month names + year totals
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1,
                    MonthLabel(mk), ExcelTheme.SubHeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1,
                $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // Header Row 3: Count of Units | Billed Amount
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "Count of Units", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Billed Amount", ExcelTheme.SubHeaderBg);
            }
            WriteHeaderCell(ws, hRow3, hCol++, "Count of Units", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            WriteHeaderCell(ws, hRow3, hCol++, "Billed Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        }
        WriteHeaderCell(ws, hRow3, hCol++, "Count of Units", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow3, hCol,   "Billed Amount", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow3 + 1;

        int dataIdx = 0;
        foreach (var cptRow in vm.CptBreakdownRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
            int col = 1;
            WriteCell(ws, row, col++, cptRow.CptCode, bg, isText: true);
            foreach (var year in cptYears)
            {
                var mons = cptMonthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    var mc = GetCptCell(cptRow.ByMonth, mk);
                    WriteCell(ws, row, col++, mc.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, mc.BilledCharges, bg);
                }
                var yt = GetCptCell(cptRow.ByYear, year);
                WriteCell(ws, row, col++, yt.ClaimCount, bg);
                WriteCurrencyCell(ws, row, col++, yt.BilledCharges, bg);
            }
            WriteCell(ws, row, col++, cptRow.GrandTotalClaims, bg);
            WriteCurrencyCell(ws, row, col++, cptRow.GrandTotalCharges, bg);
            row++;
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Grand Total";
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                var mc = GetCptCell(vm.CptBreakdownGrandByMonth, mk);
                ws.Cell(row, gtCol).Value = mc.ClaimCount;
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                ws.Cell(row, gtCol).Value = mc.BilledCharges;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            int yClaims = vm.CptBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.ClaimCount);
            decimal yCharges = vm.CptBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.BilledCharges);
            ws.Cell(row, gtCol).Value = yClaims;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        int grandClaims = vm.CptBreakdownGrandByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.ClaimCount);
        decimal grandCharges = vm.CptBreakdownGrandByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.BilledCharges);
        ws.Cell(row, gtCol).Value = grandClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = grandCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Filter footer ?????????????????????????????????????????????????????????

    private static void WriteFilterFooter(XLWorkbook wb, ProductionReportViewModel vm)
    {
        var ws      = wb.Worksheets.First();
        int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;

        var filters = new List<(string Label, IReadOnlyList<string>? Values)>
        {
            ("Payer Name",      vm.FilterPayerNames is { Count: > 0 } ? vm.FilterPayerNames : null),
            ("Panel Name",      vm.FilterPanelNames is { Count: > 0 } ? vm.FilterPanelNames : null),
            ("First Bill From", string.IsNullOrWhiteSpace(vm.FilterFirstBillFrom) ? null : [vm.FilterFirstBillFrom]),
            ("First Bill To",   string.IsNullOrWhiteSpace(vm.FilterFirstBillTo)   ? null : [vm.FilterFirstBillTo]),
        };

        ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 3, filters);
    }

    // ?? Shared helpers ????????????????????????????????????????????????????????

    /// <summary>Returns a letter label (A � Z, AA, AB �) for a zero-based panel index.</summary>
    private static string PanelLabel(int idx)
    {
        if (idx < 26) return ((char)('A' + idx)).ToString();
        return $"{(char)('A' + idx / 26 - 1)}{(char)('A' + idx % 26)}";
    }

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

    private static void WriteFooterNote(IXLWorksheet ws, int row, int colCount, string note)
    {
        var range = ws.Range(row, 1, row, colCount);
        range.Merge();
        var cell = ws.Cell(row, 1);
        cell.Value = note;
        cell.Style.Font.Italic = true;
        cell.Style.Font.FontSize = 8;
        cell.Style.Font.FontColor = XLColor.FromHtml("#595959");
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
        cell.Style.Alignment.WrapText = false;
    }

    private static void WriteMergedHeader(IXLWorksheet ws,
        int row1, int row2, int col1, int col2,
        string text, XLColor bg, XLColor? fontColor = null)
    {
        var range = ws.Range(row1, col1, row2, col2);
        range.Merge();
        var cell = ws.Cell(row1, col1);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = ExcelTheme.FontSizeHeader;
        cell.Style.Font.FontColor = fontColor ?? XLColor.White;
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        cell.Style.Alignment.WrapText = true;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorderColor = XLColor.White;
    }

    private static void WriteHeaderCell(IXLWorksheet ws, int row, int col,
        string text, XLColor bg, XLColor? fontColor = null)
    {
        var cell = ws.Cell(row, col);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = ExcelTheme.FontSizeHeader;
        cell.Style.Font.FontColor = fontColor ?? XLColor.White;
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        cell.Style.Alignment.WrapText = true;
        cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        cell.Style.Border.OutsideBorderColor = XLColor.White;
    }

    private static void WriteCell(IXLWorksheet ws, int row, int col,
        string value, XLColor bg, bool isText = false)
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
        cell.Style.NumberFormat.NumberFormatId = 3;
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

    // ?? Raw data sheets (ClaimLevelData / LineLevelData) ??????????????????????

    private static void BuildRawDataSheet(
        XLWorkbook wb, string sheetName,
        string[] columns, List<object?[]> rows, string labName, XLColor tabColor)
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

        int colCount     = columns.Length;
        bool truncated   = rows.Count > MaxRawDataRows;
        int rowsToWrite  = Math.Min(rows.Count, MaxRawDataRows);

        int row = 1;
        var titleText = truncated
            ? $"{sheetName} � {labName}  (showing {rowsToWrite:N0} of {rows.Count:N0} rows)"
            : $"{sheetName} � {labName}  ({rows.Count:N0} rows)";

        // Green title bar (NW brand colour)
        ExcelTheme.WriteTitleBar(ws, row, colCount, titleText);
        row++;

        ExcelTheme.WriteHeaderRow(ws, row, 1, columns, ExcelTheme.HeaderBg);
        row++;

        // Write raw values � skip per-cell styling on large datasets for performance
        for (int r = 0; r < rowsToWrite; r++)
        {
            var dataRow = rows[r];
            for (int c = 0; c < colCount; c++)
            {
                var val = dataRow[c];
                if (val is not null)
                    SetRawCellValue(ws.Cell(row, c + 1), val);
            }
            row++;
        }

        if (truncated)
        {
            var warnCell = ws.Cell(row, 1);
            warnCell.Value =
                $"? Export truncated at {MaxRawDataRows:N0} rows. " +
                $"Total rows: {rows.Count:N0}. Apply filters to reduce the dataset.";
            warnCell.Style.Font.Bold = true;
            warnCell.Style.Font.FontColor = ExcelTheme.BadFg;
            warnCell.Style.Fill.BackgroundColor = ExcelTheme.BadBg;
            ws.Range(row, 1, row, colCount).Merge();
        }

        // Light banding + borders only for smaller datasets to avoid OOM
        if (rowsToWrite > 0 && rowsToWrite <= 50_000)
        {
            int dataStart = 3;
            int dataEnd   = dataStart + rowsToWrite - 1;
            for (int r = dataStart + 1; r <= dataEnd; r += 2)
                ws.Range(r, 1, r, colCount).Style.Fill.BackgroundColor = ExcelTheme.BandedRowBg;

            var dataRange = ws.Range(dataStart, 1, dataEnd, colCount);
            dataRange.Style.Border.InsideBorder       = XLBorderStyleValues.Thin;
            dataRange.Style.Border.InsideBorderColor  = XLColor.FromHtml("#E2E8F0");
            dataRange.Style.Border.OutsideBorder      = XLBorderStyleValues.Thin;
            dataRange.Style.Border.OutsideBorderColor = XLColor.FromHtml("#E2E8F0");
        }

        // Materialize first: setting Width registers a column definition in the
        // worksheet's internal collection, which would invalidate a live
        // ColumnsUsed() enumerator ("Collection was modified…").
        foreach (var col in ws.ColumnsUsed().ToList())
            col.Width = 18;

        ws.SheetView.FreezeRows(2);
    }

    private static void SetRawCellValue(IXLCell cell, object val)
    {
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

    // ?? Split helpers (use ChargeEnteredDate � NW primary date column) ????????

    private static int GetChargeEnteredYear(string[] columns, object?[] row)
    {
        var idx = Array.IndexOf(columns, "ChargeEnteredDate");
        if (idx >= 0 && idx < row.Length)
        {
            var val = row[idx];
            if (val is DateTime dt) return dt.Year;
            if (val is string s && DateTime.TryParse(s, out var p)) return p.Year;
        }
        var fbIdx = Array.IndexOf(columns, "FirstBilledDate");
        if (fbIdx >= 0 && fbIdx < row.Length)
        {
            var fb = row[fbIdx];
            if (fb is DateTime dt2) return dt2.Year;
            if (fb is string s2 && DateTime.TryParse(s2, out var p2)) return p2.Year;
        }
        return 0;
    }

    private static int GetChargeEnteredMonth(string[] columns, object?[] row)
    {
        var idx = Array.IndexOf(columns, "ChargeEnteredDate");
        if (idx >= 0 && idx < row.Length)
        {
            var val = row[idx];
            if (val is DateTime dt) return dt.Month;
            if (val is string s && DateTime.TryParse(s, out var p)) return p.Month;
        }
        var fbIdx = Array.IndexOf(columns, "FirstBilledDate");
        if (fbIdx >= 0 && fbIdx < row.Length)
        {
            var fb = row[fbIdx];
            if (fb is DateTime dt2) return dt2.Month;
            if (fb is string s2 && DateTime.TryParse(s2, out var p2)) return p2.Month;
        }
        return 1;
    }

    private static string Truncate(string name) =>
        name.Length <= 31 ? name : name[..31];

    /// <summary>
    /// Outlines child rows under the parent row above them so Excel shows +/- grouping.
    /// </summary>
    private static void GroupChildRows(IXLWorksheet ws, int firstChildRow, int lastChildRow)
    {
        if (lastChildRow < firstChildRow) return;
        for (int r = firstChildRow; r <= lastChildRow; r++)
            ws.Row(r).OutlineLevel = 1;
    }

    private static void FinishOutline(IXLWorksheet ws)
    {
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;
        ws.CollapseRows();
    }
}
