using ClosedXML.Excel;
using System.Diagnostics;
using LRN.ProductionReports.Models;
using Microsoft.Extensions.Logging;


namespace LRN.ProductionReports.Services;

/// <summary>
/// A named, pre-split slice of raw ClaimLevelData or LineLevelData rows
/// that maps 1-to-1 to a single Excel sheet.
/// </summary>
/// <param name="SheetName">The target worksheet name (max 31 characters, already truncated).</param>
/// <param name="Columns">Column names in ordinal order � shared across all rows.</param>
/// <param name="Rows">The data rows for this sheet; each element is a value array aligned to <paramref name="Columns"/>.</param>
public sealed record RawDataSegment(string SheetName, string[] Columns, List<object?[]> Rows);

/// <summary>
/// Builds a formatted Excel workbook from Production Report data
/// using the Office 2013�2022 green (Accent 6) colour palette with gold (Accent 4)
/// year/grand-total highlights � same theme and Calibri fonts as the Prediction
/// summary export (ExcelTheme green family, matching PredictionExcelExportBuilder).
/// Headers use merged cells mirroring the view table layout exactly.
/// </summary>
public static class ProductionReportExcelExportBuilder
{
    /// <summary>Row threshold above which data is split into multiple sheets (3 lakh).</summary>
    private const int SplitThreshold = 300_000;

    /// <summary>Maximum rows per raw data sheet to prevent out-of-memory on very large tables.</summary>
    private const int MaxRawDataRows = 500_000;

    // ?? Pre-splitting ????????????????????????????????????????????????????????

    /// <summary>
    /// Pre-computes the sheet segments for a raw data table (ClaimLevelData or LineLevelData)
    /// <b>before</b> the Excel workbook is created, so memory management and sheet naming
    /// are resolved independently of the ClosedXML object graph.
    /// <list type="bullet">
    ///   <item>Total rows ? 3 lakh  ? one segment named <paramref name="baseSheetName"/>.</item>
    ///   <item>Total rows &gt; 3 lakh ? split by year; each year that still exceeds 3 lakh
    ///         is further split by month.</item>
    /// </list>
    /// Sheet names follow the pattern <c>YYYY_BaseSheetName</c> (year) or
    /// <c>YYYY_MM_BaseSheetName</c> (year + month), truncated to 31 characters.
    /// </summary>
    public static List<RawDataSegment> PreSplitRawData(
        string baseSheetName, string[] columns, List<object?[]> rows,
        ILogger? logger = null)
    {
        var sw = Stopwatch.StartNew();
        var segments = new List<RawDataSegment>();

        logger?.LogInformation(
            "[ProdExcelExportSplit] In-memory split START Sheet={Sheet} Rows={Rows:N0} Threshold={Threshold:N0}",
            baseSheetName, rows.Count, SplitThreshold);

        if (rows.Count == 0)
        {
            segments.Add(new RawDataSegment(baseSheetName, columns, rows));
            logger?.LogInformation(
                "[ProdExcelExportSplit] In-memory split DONE Sheet={Sheet} Segments=1 Empty=true ElapsedMs={Ms}",
                baseSheetName, sw.ElapsedMilliseconds);
            return segments;
        }

        if (rows.Count <= SplitThreshold)
        {
            segments.Add(new RawDataSegment(baseSheetName, columns, rows));
            logger?.LogInformation(
                "[ProdExcelExportSplit] In-memory split DONE Sheet={Sheet} Segments=1 Rows={Rows:N0} ElapsedMs={Ms}",
                baseSheetName, rows.Count, sw.ElapsedMilliseconds);
            return segments;
        }

        // Group by year, ordered ascending
        var byYear = rows
            .GroupBy(r => GetFirstBillDateYear(columns, r))
            .OrderBy(g => g.Key)
            .ToList();

        foreach (var yearGroup in byYear)
        {
            int year = yearGroup.Key;
            string yearLabel = year > 0 ? year.ToString() : "Unknown";
            var yearRows = yearGroup.ToList();

            logger?.LogInformation(
                "[ProdExcelExportSplit] Year split Sheet={Sheet} Year={Year} Rows={Rows:N0}",
                baseSheetName, yearLabel, yearRows.Count);

            if (yearRows.Count <= SplitThreshold)
            {
                // Whole year fits in one sheet
                segments.Add(new RawDataSegment(
                    TruncateSheetName($"{yearLabel}_{baseSheetName}"),
                    columns,
                    yearRows));
            }
            else
            {
                // Split further by month
                var byMonth = yearRows
                    .GroupBy(r => GetFirstBillDateMonth(columns, r))
                    .OrderBy(g => g.Key);

                foreach (var monthGroup in byMonth)
                {
                    var monthRows = monthGroup.ToList();
                    if (monthRows.Count > 0)
                    {
                        logger?.LogInformation(
                            "[ProdExcelExportSplit] Month split Sheet={Sheet} Year={Year} Month={Month:D2} Rows={Rows:N0}",
                            baseSheetName, yearLabel, monthGroup.Key, monthRows.Count);

                        segments.Add(new RawDataSegment(
                            TruncateSheetName($"{yearLabel}_{monthGroup.Key:D2}_{baseSheetName}"),
                            columns,
                            monthRows));
                    }
                }
            }
        }

        logger?.LogInformation(
            "[ProdExcelExportSplit] In-memory split DONE Sheet={Sheet} Segments={Segments} ElapsedMs={Ms} Details=[{Details}]",
            baseSheetName,
            segments.Count,
            sw.ElapsedMilliseconds,
            string.Join(", ", segments.Select(s => $"'{s.SheetName}'({s.Rows.Count:N0})")));

        return segments;
    }

    // ?? Workbook creation ????????????????????????????????????????????????????

    /// <summary>Creates the workbook from the Production Report view model (summary data only).</summary>
    public static XLWorkbook CreateWorkbook(ProductionReportViewModel vm, string labName)
    {
        var wb = new XLWorkbook();

        BuildMonthlyAndWeeklySheet(wb, vm, labName, weekFolder: null, runId: null);
        BuildCodingSheet(wb, vm);
        BuildPayerBreakdownSheet(wb, vm);
        BuildPayerPanelSheet(wb, vm);
        BuildUnbilledAgingSheet(wb, vm);
        BuildCptBreakdownSheet(wb, vm);

        WriteFilterFooter(wb, vm);

        return wb;
    }

    /// <summary>
    /// Creates the workbook with summary tabs only (no raw ClaimLevel/LineLevel sheets).
    /// Use together with <see cref="SqlProductionReportRepository.WriteSpExportToWorkbookAsync"/>
    /// to stream the raw data sheets directly into the workbook from a SqlDataReader,
    /// avoiding the per-row Dictionary/array buffering that causes OOM on high-volume labs.
    /// </summary>
    public static XLWorkbook CreateWorkbookSummaryOnly(
        ProductionReportViewModel vm,
        string labName,
        string? weekFolder = null,
        string? runId = null)
    {
        var wb = new XLWorkbook();

        BuildMonthlyAndWeeklySheet(wb, vm, labName, weekFolder, runId);
        BuildCodingSheet(wb, vm);
        BuildPayerBreakdownSheet(wb, vm);
        BuildPayerPanelSheet(wb, vm);
        BuildUnbilledAgingSheet(wb, vm);
        BuildCptBreakdownSheet(wb, vm);

        WriteFilterFooter(wb, vm);

        return wb;
    }

    /// <summary>
    /// Creates the workbook using <b>pre-split</b> claim and line data segments.
    /// Call <see cref="PreSplitRawData"/> for each raw dataset before invoking this method
    /// so that the heavy split computation happens before the ClosedXML object graph is created.
    /// Pass a <paramref name="logger"/> to get per-sheet build timing written to the log.
    /// </summary>
    public static XLWorkbook CreateWorkbook(
        ProductionReportViewModel vm,
        string labName,
        IReadOnlyList<RawDataSegment> claimSegments,
        IReadOnlyList<RawDataSegment> lineSegments,
        string? weekFolder = null,
        string? runId = null,
        ILogger? logger = null)
    {
        var totalSw = Stopwatch.StartNew();
        var sw      = Stopwatch.StartNew();
        var wb      = new XLWorkbook();

        BuildMonthlyAndWeeklySheet(wb, vm, labName, weekFolder, runId);
        logger?.LogInformation(
            "[ProdExcelExport][Sheet] MonthlyAndWeeklyVolume built in {Ms}ms", sw.ElapsedMilliseconds);

        sw.Restart();
        BuildCodingSheet(wb, vm);
        logger?.LogInformation(
            "[ProdExcelExport][Sheet] Coding built in {Ms}ms ({Rows} panel rows)",
            sw.ElapsedMilliseconds, vm.CodingPanelRows.Count);

        sw.Restart();
        BuildPayerBreakdownSheet(wb, vm);
        logger?.LogInformation(
            "[ProdExcelExport][Sheet] PayerBreakdown built in {Ms}ms ({Rows} payer rows)",
            sw.ElapsedMilliseconds, vm.PayerBreakdownRows.Count);

        sw.Restart();
        BuildPayerPanelSheet(wb, vm);
        logger?.LogInformation(
            "[ProdExcelExport][Sheet] PayerXPanel built in {Ms}ms ({Rows} payer rows)",
            sw.ElapsedMilliseconds, vm.PayerPanelRows.Count);

        sw.Restart();
        BuildUnbilledAgingSheet(wb, vm);
        logger?.LogInformation(
            "[ProdExcelExport][Sheet] UnbilledXAging built in {Ms}ms ({Rows} panel rows)",
            sw.ElapsedMilliseconds, vm.UnbilledAgingRows.Count);

        sw.Restart();
        BuildCptBreakdownSheet(wb, vm);
        logger?.LogInformation(
            "[ProdExcelExport][Sheet] CPTBreakdown built in {Ms}ms ({Rows} CPT rows)",
            sw.ElapsedMilliseconds, vm.CptBreakdownRows.Count);

        int claimSheetIdx = 0;
        foreach (var seg in claimSegments)
        {
            sw.Restart();
            BuildRawDataSheet(wb, seg.SheetName, seg.Columns, seg.Rows, labName, ExcelTheme.TabGreen);
            claimSheetIdx++;
            logger?.LogInformation(
                "[ProdExcelExport][Sheet] ClaimLevel sheet {Idx}/{Total} '{Name}' " +
                "({Rows:N0} rows) built in {Ms}ms",
                claimSheetIdx, claimSegments.Count, seg.SheetName, seg.Rows.Count,
                sw.ElapsedMilliseconds);
        }

        int lineSheetIdx = 0;
        foreach (var seg in lineSegments)
        {
            sw.Restart();
            BuildRawDataSheet(wb, seg.SheetName, seg.Columns, seg.Rows, labName, ExcelTheme.TabGreen);
            lineSheetIdx++;
            logger?.LogInformation(
                "[ProdExcelExport][Sheet] LineLevel sheet {Idx}/{Total} '{Name}' " +
                "({Rows:N0} rows) built in {Ms}ms",
                lineSheetIdx, lineSegments.Count, seg.SheetName, seg.Rows.Count,
                sw.ElapsedMilliseconds);
        }

        WriteFilterFooter(wb, vm);

        totalSw.Stop();
        logger?.LogInformation(
            "[ProdExcelExport] Workbook fully built: {TotalSheets} sheets in {Ms}ms",
            wb.Worksheets.Count, totalSw.ElapsedMilliseconds);

        return wb;
    }

    /// <summary>
    /// Creates the workbook with raw ClaimLevelData and LineLevelData sheets.
    /// The raw lists are split internally via <see cref="PreSplitRawData"/>.
    /// Prefer the overload that accepts <see cref="RawDataSegment"/> lists when the
    /// pre-split step should be separated from workbook creation for memory control.
    /// </summary>
    public static XLWorkbook CreateWorkbook(
        ProductionReportViewModel vm,
        string labName,
        string[] claimColumns, List<object?[]> claimRows,
        string[] lineColumns,  List<object?[]> lineRows,
        string? weekFolder = null,
        string? runId = null,
        ILogger? logger = null)
    {
        var claimSegments = PreSplitRawData("ClaimLevel", claimColumns, claimRows, logger);
        var lineSegments  = PreSplitRawData("LineLevel",  lineColumns,  lineRows,  logger);
        return CreateWorkbook(vm, labName, claimSegments, lineSegments, weekFolder, runId, logger);
    }

    // ?? Monthly & Weekly Claim Volume (combined sheet) ?????????????????????

    private static void BuildMonthlyAndWeeklySheet(
        XLWorkbook wb, ProductionReportViewModel vm, string labName,
        string? weekFolder, string? runId)
    {
        var ws = wb.AddWorksheet("MonthlyAndWeeklyVolume");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        // Report metadata header (compact 2-row block)
        int metaRow = 1;
        var metaItems = new[]
        {
            ("Client Name",      labName),
            ("Report Type",      "Production Report | Coding Audit"),
            ("Analysis Range",   string.IsNullOrWhiteSpace(weekFolder)
                                     ? "Billed Date"
                                     : $"Billed Date  |  {weekFolder}"),
            ("ReportId (RunID)", string.IsNullOrWhiteSpace(runId) ? "N/A" : runId),
        };
        foreach (var (label, value) in metaItems)
        {
            var labelCell = ws.Cell(metaRow, 1);
            labelCell.Value = label + ":";
            labelCell.Style.Font.Bold = true;
            labelCell.Style.Font.FontSize = 9;
            labelCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
            var valueCell = ws.Cell(metaRow, 2);
            valueCell.Value = value;
            valueCell.Style.Font.FontSize = 9;
            valueCell.Style.Font.FontColor = ExcelTheme.TitleBg;
            valueCell.Style.Font.Bold = true;
            metaRow++;
        }
        metaRow++; // blank separator row

        var validYears = vm.Years.Where(y => y > 1900).ToList();
        var validMonths = vm.Months.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var monthsByYear = validMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        // Column count: 1 (panel) + per-year(months*2 + 2 year-total cols) + 2 grand-total cols
        int colCount = 1;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            colCount += mons.Count * 2 + 2;
        }
        colCount += 2;

        int row = metaRow;

        // Title bar: "Production | Date of Entry"
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Production | Date of Entry");
        row++;

        // Header Row 1: "Panel & Top Insurances" (spans 3) + year group spans + Grand Total
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

        // Header Row 2: month name spans + year-total cols
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

        // Header Row 3: "No. of Claim" / "Total Billed" sub-labels
        int hRow3 = hRow1 + 2;
        hCol = 2;
        foreach (var year in validYears)
        {
            var mons = monthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
            {
                WriteHeaderCell(ws, hRow3, hCol++, "No. of Claim", ExcelTheme.SubHeaderBg);
                WriteHeaderCell(ws, hRow3, hCol++, "Total Billed", ExcelTheme.SubHeaderBg);
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

        // Data rows
        int panelIdx = 0;
        foreach (var panel in vm.PanelRows)
        {
            string label = $"{PanelLabel(panelIdx)}  {panel.PanelName}";
            int col = 1;
            WriteCell(ws, row, col++, label, ExcelTheme.GroupRowBg, isText: true);
            foreach (var year in validYears)
            {
                var mons = monthsByYear.GetValueOrDefault(year, []);
                foreach (var mk in mons)
                {
                    var cell = GetMonthCell(panel.ByMonth, mk);
                    WriteCell(ws, row, col++, cell.ClaimCount, ExcelTheme.GroupRowBg);
                    WriteCurrencyCell(ws, row, col++, cell.BilledCharges, ExcelTheme.GroupRowBg);
                }
                var yt = GetYearTotal(panel.ByYear, year);
                WriteCell(ws, row, col++, yt.ClaimCount, ExcelTheme.GroupRowBg);
                WriteCurrencyCell(ws, row, col++, yt.BilledCharges, ExcelTheme.GroupRowBg);
            }
            WriteCell(ws, row, col++, panel.TotalClaims, ExcelTheme.GroupRowBg);
            WriteCurrencyCell(ws, row, col, panel.TotalCharges, ExcelTheme.GroupRowBg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

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
                        var cell = GetMonthCell(payer.ByMonth, mk);
                        WriteCell(ws, row, col++, cell.ClaimCount, bg);
                        WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
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
            panelIdx++;
        }

        // Total row (dark green, white text)
        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Total";
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
            int yClaims   = vm.GrandTotalByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.ClaimCount);
            decimal yCharges = vm.GrandTotalByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.BilledCharges);
            ws.Cell(row, gtCol).Value = yClaims;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        int grandClaims   = vm.GrandTotalByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.ClaimCount);
        decimal grandCharges = vm.GrandTotalByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.BilledCharges);
        ws.Cell(row, gtCol).Value = grandClaims;
        ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        ws.Cell(row, gtCol).Value = grandCharges;
        ws.Cell(row, gtCol).Style.NumberFormat.Format = "$#,##0";
        row++;

        // Footer note
        WriteFooterNote(ws, row, colCount,
            "*The above table is based on 'Date of Entry' and the total numbers include 'ALL' claims billed.");
        row++;

        ExcelTheme.AutoFitColumns(ws, colCount);

        // Weekly Claim Volume section (same sheet)
        if (vm.WeeklyPanelRows.Count > 0)
            AppendWeeklySection(ws, vm, row + 2);
    }

    /// <summary>Returns a letter label (A, B, � Z, AA, AB, �) for a zero-based panel index.</summary>
    private static string PanelLabel(int idx)
    {
        if (idx < 26)
            return ((char)('A' + idx)).ToString();
        int hi = idx / 26 - 1;
        int lo = idx % 26;
        return $"{(char)('A' + hi)}{(char)('A' + lo)}";
    }

    /// <summary>Writes an italic asterisk footer note spanning <paramref name="colCount"/> columns.</summary>
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

    private static void AppendWeeklySection(IXLWorksheet ws, ProductionReportViewModel vm, int startRow)
    {
        var weeks = vm.WeekColumns;
        int colCount = 1 + weeks.Count * 2 + 2;

        // Derive year range for the title
        string weekTitle = "Weekly Breakdown |Date of Entry|";
        if (weeks.Count > 0)
        {
            int firstYear = weeks[0].WeekStart.Year;
            int lastYear  = weeks[^1].WeekEnd.Year;
            weekTitle = firstYear == lastYear
                ? $"Weekly Breakdown |Date of Entry| {firstYear}"
                : $"Weekly Breakdown |Date of Entry| {firstYear}-{lastYear}";
        }

        int row = startRow;
        ExcelTheme.WriteTitleBar(ws, row, colCount, weekTitle);
        row++;

        // Header Row 1: "Panel & Insurance" spans 3, "Billed week" spans week cols, "Total" spans
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "Panel & Insurance", ExcelTheme.HeaderBg);
        int hCol = 2;
        int weekDataSpan = weeks.Count * 2;
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + weekDataSpan - 1,
            "Billed week", ExcelTheme.HeaderBg);
        hCol += weekDataSpan;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, hCol, hCol + 1,
            "Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // Header Row 2: week date ranges
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var w in weeks)
        {
            string label = $"{w.WeekStart:MMM dd} - {w.WeekEnd:MMM dd}";
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1,
                label, ExcelTheme.SubHeaderBg);
            hCol += 2;
        }

        // Header Row 3: sub-column labels
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

        // Data rows
        int panelIdx = 0;
        foreach (var panel in vm.WeeklyPanelRows)
        {
            string label = $"{PanelLabel(panelIdx)}  {panel.PanelName}";
            int col = 1;
            WriteCell(ws, row, col++, label, ExcelTheme.GroupRowBg, isText: true);
            foreach (var w in weeks)
            {
                var cell = GetMonthCell(panel.ByWeek, w.Key);
                WriteCell(ws, row, col++, cell.ClaimCount, ExcelTheme.GroupRowBg);
                WriteCurrencyCell(ws, row, col++, cell.BilledCharges, ExcelTheme.GroupRowBg);
            }
            WriteCell(ws, row, col++, panel.TotalClaims, ExcelTheme.GroupRowBg);
            WriteCurrencyCell(ws, row, col, panel.TotalCharges, ExcelTheme.GroupRowBg);
            ws.Row(row).Style.Font.Bold = true;
            row++;

            int payerIdx = 0;
            foreach (var payer in panel.TopPayers)
            {
                var bg = payerIdx % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
                col = 1;
                WriteCell(ws, row, col++, $"    {payer.PayerName}", bg, isText: true);
                foreach (var w in weeks)
                {
                    var cell = GetMonthCell(payer.ByWeek, w.Key);
                    WriteCell(ws, row, col++, cell.ClaimCount, bg);
                    WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
                }
                WriteCell(ws, row, col++, payer.TotalClaims, bg);
                WriteCurrencyCell(ws, row, col, payer.TotalCharges, bg);
                row++;
                payerIdx++;
            }
            panelIdx++;
        }

        // Total row (dark green, white text)
        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
        int gtCol = 1;
        ws.Cell(row, gtCol++).Value = "Total";
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
        row++;

        // Footer note
        WriteFooterNote(ws, row, colCount,
            "*The above table is based on 'Date of Entry' and the total numbers include 'ALL' claims billed.");
        row++;

        // Key Insights & Highlights template table
        AppendKeyInsightsTable(ws, row + 2, colCount);
    }

    private static void AppendKeyInsightsTable(IXLWorksheet ws, int startRow, int sheetColCount)
    {
        // Title bar for Insights section
        const int insightColCount = 14;
        int effectiveCols = Math.Max(sheetColCount, insightColCount);
        int row = startRow;

        ExcelTheme.WriteSectionTitle(ws, row, 1, effectiveCols,
            "Key Insights & Highlights", ExcelTheme.TitleBg);
        row++;

        // Header row
        string[] headers =
        [
            "#", "Risk", "Responsible Party", "Insights",
            "# of Claims", "Total Bill", "Data",
            "Action / Solution / Suggestions",
            "Feedback / Response", "Responsibility",
            "Discussion Date", "ETA", "Closed Date", "Status"
        ];
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        row++;

        // 5 empty template rows with borders
        for (int r = 0; r < 5; r++)
        {
            for (int c = 1; c <= headers.Length; c++)
            {
                var cell = ws.Cell(row, c);
                cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
                cell.Style.Border.OutsideBorderColor = ExcelTheme.BorderColor;
                cell.Style.Fill.BackgroundColor = r % 2 == 0 ? XLColor.White : ExcelTheme.BandedRowBg;
                cell.Style.Font.FontSize = 10;
            }
            row++;
        }
    }

    // ?? Coding ???????????????????????????????????????????????????????????

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
        ExcelTheme.WriteHeaderRow(ws, row, 1, ["Panel Name", "Claim Count", "Total Charge"], ExcelTheme.HeaderBg);
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

            foreach (var cpt in panel.CptRows)
            {
                dataIdx++;
                bg = ExcelTheme.GetRowBg(dataIdx);
                WriteCell(ws, row, 1, $"  {cpt.CptCodeUnitsModifier}", bg, isText: true);
                WriteCell(ws, row, 2, cpt.ClaimCount, bg);
                WriteCurrencyCell(ws, row, 3, cpt.TotalCharges, bg);
                row++;
            }
            dataIdx++;
        }

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
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
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var showCharges = vm.IsNorthWestLab
            || string.Equals(vm.ProductionSummaryRule, "Rule4", StringComparison.OrdinalIgnoreCase);
        var metrics = showCharges ? 2 : 1;
        var pbYears = vm.PayerBreakdownYears.Where(y => y > 1900).ToList();
        var pbMonths = vm.PayerBreakdownMonths.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var pbMonthsByYear = pbMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        int colCount = 1;
        foreach (var year in pbYears)
            colCount += (pbMonthsByYear.GetValueOrDefault(year, []).Count + 1) * metrics;
        colCount += metrics;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Payer Breakdown (Charge Entered Date)");
        row++;

        int headerRows = showCharges ? 2 : 1;
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + headerRows, 1, 1, "Payer", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            int span = (mons.Count + 1) * metrics;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1, year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, showCharges ? hRow1 : hRow1 + 1, hCol, hCol + metrics - 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in pbYears)
        {
            var mons = pbMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                if (showCharges)
                {
                    WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, MonthLabel(mk), ExcelTheme.SubHeaderBg);
                    hCol += 2;
                }
                else
                {
                    WriteHeaderCell(ws, hRow2, hCol++, MonthLabel(mk), ExcelTheme.SubHeaderBg);
                }
            }
            if (showCharges)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
                hCol += 2;
            }
            else
            {
                WriteHeaderCell(ws, hRow2, hCol++, $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            }
        }
        if (showCharges)
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        if (showCharges)
        {
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
        }
        else
        {
            row = hRow2 + 1;
        }

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
                    if (showCharges)
                        WriteCurrencyCell(ws, row, col++, pr.ByMonthCharges.GetValueOrDefault(mk, 0m), bg);
                }
                WriteCell(ws, row, col++, pr.ByYear.GetValueOrDefault(year, 0), bg);
                if (showCharges)
                    WriteCurrencyCell(ws, row, col++, pr.ByYearCharges.GetValueOrDefault(year, 0m), bg);
            }
            WriteCell(ws, row, col++, pr.GrandTotal, bg);
            if (showCharges)
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
                if (showCharges)
                {
                    ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandChargesByMonth.GetValueOrDefault(mk, 0m);
                    ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
                }
            }
            int yTotal = vm.PayerBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
            ws.Cell(row, gtCol).Value = yTotal;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            if (showCharges)
            {
                decimal yCharges = vm.PayerBreakdownGrandChargesByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value);
                ws.Cell(row, gtCol).Value = yCharges;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
        }
        ws.Cell(row, gtCol).Value = vm.PayerBreakdownGrandTotal;
        ws.Cell(row, gtCol).Style.NumberFormat.NumberFormatId = 3;
        if (showCharges)
        {
            ws.Cell(row, gtCol + 1).Value = vm.PayerBreakdownGrandTotalCharges;
            ws.Cell(row, gtCol + 1).Style.NumberFormat.Format = "$#,##0";
        }

        ExcelTheme.AutoFitColumns(ws, colCount);
    }

    // ?? Payer X Panel ????????????????????????????????????????????????????

    private static void BuildPayerPanelSheet(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (vm.PayerPanelRows.Count == 0) return;

        var ws = wb.AddWorksheet("Payer X Panel");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var panels = vm.PayerPanelColumns;
        int colCount = 1 + panels.Count * 2 + 2;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Payer X Panel");
        row++;

        // ?? Header Row 1 ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Payer x Panel", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var p in panels)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, p, ExcelTheme.HeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // ?? Header Row 2 ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in panels)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.SubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Total Billed Charges", ExcelTheme.SubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow2, hCol, "Total Billed Charges", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow2 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var pr in vm.PayerPanelRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
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

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
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
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var buckets = AgingBuckets.All;
        int colCount = 1 + buckets.Count * 2 + 2;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "Unbilled X Aging");
        row++;

        // ?? Header Row 1 ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Unbilled x Aging", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var b in buckets)
        {
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, b, ExcelTheme.HeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // ?? Header Row 2 ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var _ in buckets)
        {
            WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.SubHeaderBg);
            WriteHeaderCell(ws, hRow2, hCol++, "Total Billed Charges", ExcelTheme.SubHeaderBg);
        }
        WriteHeaderCell(ws, hRow2, hCol++, "No. of Claims", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
        WriteHeaderCell(ws, hRow2, hCol, "Total Billed Charges", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        row = hRow2 + 1;

        // ?? Data rows ??
        int dataIdx = 0;
        foreach (var pr in vm.UnbilledAgingRows)
        {
            var bg = ExcelTheme.GetRowBg(dataIdx);
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

        ExcelTheme.StyleGreenTotalRow(ws, row, 1, colCount);
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
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var cptYears = vm.CptBreakdownYears.Where(y => y > 1900).ToList();
        var cptMonths = vm.CptBreakdownMonths.Where(m => int.Parse(m[..4]) > 1900).ToList();
        var cptMonthsByYear = cptMonths
            .GroupBy(m => int.Parse(m[..4]))
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.OrderBy(m => m).ToList());

        var showCptCount = vm.IsNorthWestLab
            || string.Equals(vm.ProductionSummaryRule, "Rule4", StringComparison.OrdinalIgnoreCase);
        const int metrics = 2;
        int colCount = 1;
        foreach (var year in cptYears)
            colCount += cptMonthsByYear.GetValueOrDefault(year, []).Count * metrics + metrics;
        colCount += metrics;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, colCount, "CPT Breakdown (Billed Date)");
        row++;

        // ?? Header Row 1: year grouping ??
        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 2, 1, 1, "CPT Codes", ExcelTheme.HeaderBg);
        int hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            int span = mons.Count * metrics + metrics;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1, year.ToString(), ExcelTheme.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + metrics - 1, "Grand Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // ?? Header Row 2: month names + year total ??
        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var mk in mons)
            {
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + metrics - 1, MonthLabel(mk), ExcelTheme.SubHeaderBg);
                hCol += metrics;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + metrics - 1, $"Year {year} Total", ExcelTheme.GoldAccent, fontColor: XLColor.Black);
            hCol += metrics;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + metrics - 1, "", ExcelTheme.GoldAccent, fontColor: XLColor.Black);

        // ?? Header Row 3: metrics ??
        int hRow3 = hRow1 + 2;
        hCol = 2;
        void WriteCptMetricHeaders(XLColor bg, XLColor? font = null)
        {
            WriteHeaderCell(ws, hRow3, hCol++, showCptCount ? "Count of Units" : "Billed Units", bg, fontColor: font);
            WriteHeaderCell(ws, hRow3, hCol++, "Billed Amount", bg, fontColor: font);
        }
        foreach (var year in cptYears)
        {
            var mons = cptMonthsByYear.GetValueOrDefault(year, []);
            foreach (var _ in mons)
                WriteCptMetricHeaders(ExcelTheme.SubHeaderBg);
            WriteCptMetricHeaders(ExcelTheme.GoldAccent, XLColor.Black);
        }
        WriteCptMetricHeaders(ExcelTheme.GoldAccent, XLColor.Black);

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
                    var cell = GetCptCell(cptRow.ByMonth, mk);
                    if (showCptCount)
                        WriteCell(ws, row, col++, cell.ClaimCount, bg);
                    else
                        WriteDecimalCell(ws, row, col++, cell.Units, bg);
                    WriteCurrencyCell(ws, row, col++, cell.BilledCharges, bg);
                }
                var yt = GetCptCell(cptRow.ByYear, year);
                if (showCptCount)
                    WriteCell(ws, row, col++, yt.ClaimCount, bg);
                else
                    WriteDecimalCell(ws, row, col++, yt.Units, bg);
                WriteCurrencyCell(ws, row, col++, yt.BilledCharges, bg);
            }
            if (showCptCount)
                WriteCell(ws, row, col++, cptRow.GrandTotalClaims, bg);
            else
                WriteDecimalCell(ws, row, col++, cptRow.GrandTotalUnits, bg);
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
                var cell = GetCptCell(vm.CptBreakdownGrandByMonth, mk);
                if (showCptCount)
                {
                    ws.Cell(row, gtCol).Value = cell.ClaimCount;
                    ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
                }
                else
                {
                    ws.Cell(row, gtCol).Value = cell.Units;
                    ws.Cell(row, gtCol++).Style.NumberFormat.Format = "#,##0";
                }
                ws.Cell(row, gtCol).Value = cell.BilledCharges;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
            }
            if (showCptCount)
            {
                int yClaims = vm.CptBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.ClaimCount);
                ws.Cell(row, gtCol).Value = yClaims;
                ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
            }
            else
            {
                decimal yUnits = vm.CptBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.Units);
                ws.Cell(row, gtCol).Value = yUnits;
                ws.Cell(row, gtCol++).Style.NumberFormat.Format = "#,##0";
            }
            decimal yCharges = vm.CptBreakdownGrandByMonth.Where(kv => kv.Key.StartsWith($"{year:D4}")).Sum(kv => kv.Value.BilledCharges);
            ws.Cell(row, gtCol).Value = yCharges;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "$#,##0";
        }
        if (showCptCount)
        {
            int cptGrandClaims = vm.CptBreakdownGrandByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.ClaimCount);
            ws.Cell(row, gtCol).Value = cptGrandClaims;
            ws.Cell(row, gtCol++).Style.NumberFormat.NumberFormatId = 3;
        }
        else
        {
            decimal cptGrandUnits = vm.CptBreakdownGrandByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.Units);
            ws.Cell(row, gtCol).Value = cptGrandUnits;
            ws.Cell(row, gtCol++).Style.NumberFormat.Format = "#,##0";
        }
        decimal cptGrandCharges = vm.CptBreakdownGrandByMonth.Where(kv => int.Parse(kv.Key[..4]) > 1900).Sum(kv => kv.Value.BilledCharges);
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

    /// <summary>Writes a single (non-merged) header cell.</summary>
    private static void WriteHeaderCell(IXLWorksheet ws, int row, int col, string text, XLColor bg,
        XLColor? fontColor = null)
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

    // ?? Raw Data Sheets ?????????????????????????????????????????????

    private static int GetFirstBillDateYear(string[] columns, object?[] row)
    {
        return TryGetSplitDate(columns, row, out var date) ? date.Year : 0;
    }

    private static int GetFirstBillDateMonth(string[] columns, object?[] row)
    {
        return TryGetSplitDate(columns, row, out var date) ? date.Month : 1;
    }

    private static bool TryGetSplitDate(string[] columns, object?[] row, out DateTime date)
    {
        foreach (var key in new[] { "FirstBilledDate", "FirstBillDate", "ChargeEnteredDate", "DateofService", "DateOfService" })
        {
            var idx = Array.IndexOf(columns, key);
            if (idx < 0 || idx >= row.Length) continue;
            var val = row[idx];
            if (val is null) continue;

            if (val is DateTime dt)  { date = dt;     return true; }
            if (val is string s && DateTime.TryParse(s, out var parsed)) { date = parsed; return true; }
        }

        date = default;
        return false;
    }

    private static string TruncateSheetName(string name) =>
        name.Length <= 31 ? name : name[..31];

    private static void BuildRawDataSheet(
        XLWorkbook wb, string sheetName, string[] columns, List<object?[]> rows,
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

        int colCount = columns.Length;
        bool truncated = rows.Count > MaxRawDataRows;
        int rowsToWrite = Math.Min(rows.Count, MaxRawDataRows);

        int row = 1;
        var titleText = truncated
            ? $"{sheetName} \u2014 {labName} (showing {rowsToWrite:N0} of {rows.Count:N0} rows)"
            : $"{sheetName} \u2014 {labName} ({rows.Count:N0} rows)";
        ExcelTheme.WriteTitleBar(ws, row, colCount, titleText);
        row++;

        ExcelTheme.WriteHeaderRow(ws, row, 1, columns, ExcelTheme.HeaderBg);
        row++;

        // Write values only (no per-cell styling for performance on large datasets)
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
            warnCell.Value = $"\u26a0 Export truncated at {MaxRawDataRows:N0} rows. Total rows: {rows.Count:N0}. Apply filters to reduce the dataset.";
            warnCell.Style.Font.Bold = true;
            warnCell.Style.Font.FontColor = XLColor.FromHtml("#9C0006");
            warnCell.Style.Fill.BackgroundColor = XLColor.FromHtml("#FFC7CE");
            ws.Range(row, 1, row, colCount).Merge();
        }

        // Apply banded rows and borders only for smaller datasets to avoid OOM
        if (rowsToWrite > 0 && rowsToWrite <= 50_000)
        {
            int dataStart = 3;
            int dataEnd = dataStart + rowsToWrite - 1;
            for (int r = dataStart + 1; r <= dataEnd; r += 2)
                ws.Range(r, 1, r, colCount).Style.Fill.BackgroundColor = ExcelTheme.BandedRowBg;

            var dataRange = ws.Range(dataStart, 1, dataEnd, colCount);
            dataRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
            dataRange.Style.Border.InsideBorderColor = XLColor.FromHtml("#E2E8F0");
            dataRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
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
}
