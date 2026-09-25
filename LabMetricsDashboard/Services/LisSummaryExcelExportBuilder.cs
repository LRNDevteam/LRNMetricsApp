using System.Globalization;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

public static class LisSummaryExcelExportBuilder
{
    /// <summary>Sheet holding the filter snapshot, kept off the summary sheet itself.</summary>
    public const string FilterSheetName = "Filtered Values";

    // Cove client LIMS Report palette (same tokens as Collection / Executive).
    private static readonly XLColor HeaderGreen = ExcelTheme.Collection.HeaderBg;
    private static readonly XLColor YearGreen = ExcelTheme.Collection.HeaderBg;
    private static readonly XLColor MonthHeaderBg = ExcelTheme.Collection.MonthHeaderBg; // #E2EFDA
    private static readonly XLColor TotalGreen = ExcelTheme.Collection.TotalRowBg;
    private static readonly XLColor BorderColor = ExcelTheme.BorderColor;
    private static readonly XLColor ChildBg = ExcelTheme.Collection.ChildRowBg;

    public static XLWorkbook CreateWorkbook(
        LisSummaryResult result,
        LisLineDataResult? lineData,
        string labName,
        string dateType,
        DateOnly? dateFrom,
        DateOnly? dateTo,
        string? panel,
        string? clinic,
        string? refPhy,
        string? salesRep,
        string? collector)
    {
        // Sheet order: Filtered Values → LIS Summary → LIMS Master. The filters come first so a
        // reader sees what the numbers cover before the numbers.
        var workbook = new XLWorkbook();

        BuildFilterSheet(
            workbook.Worksheets.Add(FilterSheetName),
            result, labName, dateType, dateFrom, dateTo, panel, clinic, refPhy, salesRep, collector);
        BuildSummarySheet(workbook.Worksheets.Add("LIS Summary"), result, labName);
        BuildLineDataSheet(workbook.Worksheets.Add("LIMS Master"), lineData);

        workbook.Properties.Title = $"LIS Summary - {labName}";
        workbook.Properties.Subject = "LIS Summary";
        workbook.Properties.Author = "LabMetricsDashboard";
        return workbook;
    }

    /// <summary>
    /// The run's filter snapshot on its own sheet. It used to sit in rows 2–12 of the summary
    /// sheet, which pushed the pivot down and mixed metadata into the table.
    /// </summary>
    private static void BuildFilterSheet(
        IXLWorksheet sheet,
        LisSummaryResult result,
        string labName,
        string dateType,
        DateOnly? dateFrom,
        DateOnly? dateTo,
        string? panel,
        string? clinic,
        string? refPhy,
        string? salesRep,
        string? collector)
    {
        sheet.TabColor = ExcelTheme.Collection.TabYellow;
        sheet.ShowGridLines = false;
        ExcelTheme.ApplyDefaults(sheet);

        sheet.Cell(1, 1).Value = "Filtered Values";
        sheet.Range(1, 1, 1, 2).Merge();
        var title = sheet.Cell(1, 1);
        title.Style.Font.Bold = true;
        title.Style.Font.FontSize = ExcelTheme.FontSizeBody;
        title.Style.Font.FontColor = XLColor.White;
        title.Style.Fill.BackgroundColor = HeaderGreen;
        title.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        var values = new (string Label, string Value)[]
        {
            ("Lab", labName),
            ("Logic Sheet", result.LogicSheetName),
            ("Date Type", string.IsNullOrWhiteSpace(dateType) ? "Collected" : dateType),
            ("Date From", FormatDateFilter(dateFrom)),
            ("Date To", FormatDateFilter(dateTo)),
            ("Panel", FormatFilter(panel)),
            ("Clinic", FormatFilter(clinic)),
            ("Ref Phy", FormatFilter(refPhy)),
            ("Sales Rep", FormatFilter(salesRep)),
            ("Collector", FormatFilter(collector)),
            ("Top Source File name", string.IsNullOrWhiteSpace(result.SourceFileName) ? "-" : result.SourceFileName),
            ("Generated On", DateTime.Now.ToString("dd MMM yyyy HH:mm")),
        };

        var row = 3;
        foreach (var (label, value) in values)
        {
            var labelCell = sheet.Cell(row, 1);
            labelCell.Value = label;
            labelCell.Style.Font.Bold = true;
            labelCell.Style.Font.FontColor = XLColor.White;
            labelCell.Style.Fill.BackgroundColor = HeaderGreen;

            sheet.Cell(row, 2).Value = value;
            row++;
        }

        var table = sheet.Range(3, 1, row - 1, 2);
        table.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        table.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        table.Style.Border.OutsideBorderColor = BorderColor;
        table.Style.Border.InsideBorderColor = BorderColor;
        table.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

        sheet.Column(1).Width = 26;
        sheet.Column(2).Width = 62;
        sheet.Range(3, 2, row - 1, 2).Style.Alignment.WrapText = true;
    }

    private static void BuildSummarySheet(
        IXLWorksheet sheet,
        LisSummaryResult result,
        string labName)
    {
        var monthColumns = BuildMonthColumns(result.Months, result.Years);

        // Gridlines off: only the summary table below carries borders, so the sheet reads as
        // one bordered table on a clean page rather than a grid of empty cells.
        sheet.ShowGridLines = false;
        sheet.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(sheet);

        var includeLogicColumn = false;
        var firstDataColumn = 3;
        var titleRow = 1;
        var rowAfterTitle = titleRow + 1;

        if (result.KeyMetrics is { Months.Count: > 0 } keyMetrics)
        {
            // Key Metrics is # | Description | Responsible Party | Benchmark | Month1 … —
            // its own layout, not the summary pivot's S.No | Description columns.
            rowAfterTitle = BuildKeyMetricsSection(sheet, keyMetrics, rowAfterTitle);
            rowAfterTitle++;
        }

        var sampleNoteRow = rowAfterTitle;
        var yearHeaderRow = sampleNoteRow + 2;
        var monthHeaderRow = yearHeaderRow + 1;
        var dataStartRow = monthHeaderRow + 1;

        var lastColumn = firstDataColumn + monthColumns.Count;

        sheet.Cell(titleRow, 1).Value = $"LIS Summary — {labName}";
        sheet.Range(titleRow, 1, titleRow, lastColumn).Merge();
        sheet.Cell(titleRow, 1).Style.Font.Bold = true;
        sheet.Cell(titleRow, 1).Style.Font.FontSize = ExcelTheme.FontSizeBody;
        sheet.Cell(titleRow, 1).Style.Font.FontColor = XLColor.White;
        sheet.Cell(titleRow, 1).Style.Fill.BackgroundColor = HeaderGreen;
        sheet.Cell(titleRow, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        sheet.Cell(sampleNoteRow, 1).Value = "Sample Count = Count [Rows]";
        sheet.Range(sampleNoteRow, 1, sampleNoteRow, Math.Min(lastColumn, 6)).Merge();
        sheet.Cell(sampleNoteRow, 1).Style.Font.Italic = true;
        sheet.Cell(sampleNoteRow, 1).Style.Font.FontColor = XLColor.FromHtml("#5C738A");

        sheet.Cell(yearHeaderRow, 1).Value = "S.No";
        sheet.Cell(yearHeaderRow, 2).Value = "Description";
        sheet.Range(yearHeaderRow, 1, monthHeaderRow, 1).Merge();
        sheet.Range(yearHeaderRow, 2, monthHeaderRow, 2).Merge();
        if (includeLogicColumn)
        {
            sheet.Cell(yearHeaderRow, 3).Value = "Logic";
            sheet.Range(yearHeaderRow, 3, monthHeaderRow, 3).Merge();
        }

        var col = firstDataColumn;
        foreach (var year in result.Years.OrderBy(x => x))
        {
            var yearMonthColumns = monthColumns.Where(x => x.Year == year && !x.IsYearTotal).ToList();
            if (yearMonthColumns.Count == 0) continue;

            var yearStart = col;
            foreach (var monthColumn in yearMonthColumns)
            {
                sheet.Cell(monthHeaderRow, col).Value = monthColumn.Label;
                col++;
            }

            sheet.Cell(monthHeaderRow, col).Value = $"{year} Total";
            // Year must be text. A numeric 2025 plus CountNumberFormat becomes "2,025".
            var yearCell = sheet.Cell(yearHeaderRow, yearStart);
            yearCell.Value = year.ToString(CultureInfo.InvariantCulture);
            yearCell.Style.NumberFormat.Format = "@";
            sheet.Range(yearHeaderRow, yearStart, yearHeaderRow, col).Merge();
            col++;
        }

        sheet.Cell(yearHeaderRow, col).Value = "Total";
        sheet.Range(yearHeaderRow, col, monthHeaderRow, col).Merge();
        lastColumn = col;

        var headerRange = sheet.Range(yearHeaderRow, 1, monthHeaderRow, lastColumn);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerRange.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        headerRange.Style.Font.FontColor = XLColor.White;
        headerRange.Style.Fill.BackgroundColor = HeaderGreen;
        headerRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        headerRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        headerRange.Style.Border.OutsideBorderColor = BorderColor;
        headerRange.Style.Border.InsideBorderColor = BorderColor;

        sheet.Range(yearHeaderRow, firstDataColumn, yearHeaderRow, lastColumn).Style.Fill.BackgroundColor = YearGreen;
        sheet.Range(yearHeaderRow, firstDataColumn, yearHeaderRow, lastColumn).Style.Font.FontColor = XLColor.White;

        // Month names (JAN, FEB, …) are the table subheading — mint, not dark green.
        col = firstDataColumn;
        foreach (var year in result.Years.OrderBy(x => x))
        {
            var yearMonthColumns = monthColumns.Where(x => x.Year == year && !x.IsYearTotal).ToList();
            if (yearMonthColumns.Count == 0) continue;
            foreach (var _ in yearMonthColumns)
            {
                var monthCell = sheet.Cell(monthHeaderRow, col);
                monthCell.Style.Fill.BackgroundColor = MonthHeaderBg;
                monthCell.Style.Font.FontColor = ExcelTheme.Collection.ContrastOn(MonthHeaderBg);
                col++;
            }
            var yearTotalCell = sheet.Cell(monthHeaderRow, col);
            yearTotalCell.Style.Fill.BackgroundColor = HeaderGreen;
            yearTotalCell.Style.Font.FontColor = XLColor.White;
            col++;
        }

        var grandTotalHeader = sheet.Range(yearHeaderRow, lastColumn, monthHeaderRow, lastColumn);
        grandTotalHeader.Style.Fill.BackgroundColor = HeaderGreen;
        grandTotalHeader.Style.Font.FontColor = XLColor.White;

        // Re-assert year labels as text after header fills, so they cannot
        // pick up a numeric format from the data columns.
        col = firstDataColumn;
        foreach (var year in result.Years.OrderBy(x => x))
        {
            var yearMonthColumns = monthColumns.Where(x => x.Year == year && !x.IsYearTotal).ToList();
            if (yearMonthColumns.Count == 0) continue;
            var yearCell = sheet.Cell(yearHeaderRow, col);
            yearCell.Style.NumberFormat.Format = "@";
            yearCell.Value = year.ToString(CultureInfo.InvariantCulture);
            col += yearMonthColumns.Count + 1;
        }

        var rowNumber = dataStartRow;
        foreach (var row in result.Rows)
        {
            WriteDataRow(sheet, rowNumber, row, monthColumns, result.Years, firstDataColumn, includeLogicColumn);
            ApplyRowStyle(sheet, rowNumber, row.Level, lastColumn);
            if (row.Level > 0)
                sheet.Row(rowNumber).OutlineLevel = Math.Min(row.Level, 7);
            rowNumber++;
        }

        WriteGrandTotalRow(sheet, rowNumber, result, monthColumns, result.Years, firstDataColumn, lastColumn);
        ExcelTheme.FinishOutline(sheet);

        // ONLY the summary table is bordered — the title and note rows above it stay clean.
        var tableRange = sheet.Range(yearHeaderRow, 1, rowNumber, lastColumn);
        tableRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        tableRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        tableRange.Style.Border.OutsideBorderColor = BorderColor;
        tableRange.Style.Border.InsideBorderColor = BorderColor;

        // Freeze the label columns AND the two header rows, so months and row names both stay put.
        sheet.SheetView.Freeze(monthHeaderRow, 2);

        // Apply count format only to data cells — never the year header row.
        sheet.Range(dataStartRow, firstDataColumn, rowNumber, lastColumn)
            .Style.NumberFormat.Format = ExcelTheme.Collection.CountNumberFormat;
        sheet.Column(1).Width = 10;
        sheet.Column(2).Width = 36;
        if (includeLogicColumn)
        {
            sheet.Column(3).Width = 58;
            sheet.Range(dataStartRow, 3, rowNumber, 3).Style.Alignment.WrapText = true;
        }
        sheet.Columns(firstDataColumn, lastColumn).Width = 14;

        sheet.Range(dataStartRow, 2, rowNumber, 2).Style.Alignment.WrapText = true;
        sheet.Rows(1, rowNumber).Height = 20;
        sheet.Row(1).Height = 26;
        sheet.Row(yearHeaderRow).Height = 24;
        sheet.Row(monthHeaderRow).Height = 24;
        sheet.Range(1, 1, rowNumber, lastColumn).Style.Font.FontName = "Calibri";
        sheet.Range(1, 1, rowNumber, lastColumn).Style.Font.FontSize = 10;
        sheet.Range(dataStartRow, firstDataColumn, rowNumber, lastColumn).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        sheet.Range(dataStartRow, 1, rowNumber, 2).Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;

        sheet.PageSetup.PageOrientation = XLPageOrientation.Landscape;
        sheet.PageSetup.FitToPages(1, 0);
    }

    /// <summary>
    /// Recent 4 Months by Date of Collection — average Time to Result / Time to Bill.
    /// Layout matches the client template: # | Description | Responsible Party, then an
    /// "Average Days Taken" band over Benchmark | Month 1 … Month 4 (real month names).
    /// Filter note above the table. Rows come from <see cref="LisKeyMetricRow.All"/>.
    /// </summary>
    private static int BuildKeyMetricsSection(
        IXLWorksheet sheet,
        LisKeyMetricsBlock metrics,
        int startRow)
    {
        const int indexCol = 1;
        const int metricsCol = 2;
        const int partyCol = 3;
        const int benchmarkCol = 4;
        const int firstMonthCol = 5;
        var lastColumn = firstMonthCol + metrics.Months.Count - 1;

        var titleRange = sheet.Range(startRow, indexCol, startRow, lastColumn);
        titleRange.Merge();
        var titleCell = sheet.Cell(startRow, indexCol);
        titleCell.Value = $"Key Metrics — Recent 4 Months by {metrics.CollectionDateLabel}";
        titleCell.Style.Font.Bold = true;
        titleCell.Style.Font.FontColor = XLColor.White;
        titleCell.Style.Fill.BackgroundColor = HeaderGreen;
        titleCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        var filterRow = startRow + 1;
        sheet.Cell(filterRow, indexCol).Value =
            $"Filter: {metrics.CollectionDateLabel}. Exclude blank Time to Result / Time to Bill. Average per month.";
        sheet.Range(filterRow, indexCol, filterRow, lastColumn).Merge();
        sheet.Cell(filterRow, indexCol).Style.Font.Italic = true;
        sheet.Cell(filterRow, indexCol).Style.Font.FontColor = XLColor.FromHtml("#5C738A");

        // Two header rows: #, Description and Responsible Party span both; "Average Days Taken"
        // bands Benchmark and the months, as in the client template.
        var bandRow = filterRow + 1;
        var headerRow = bandRow + 1;
        foreach (var (column, label) in new[] { (indexCol, "#"), (metricsCol, "Description"), (partyCol, "Responsible Party") })
        {
            sheet.Cell(bandRow, column).Value = label;
            sheet.Range(bandRow, column, headerRow, column).Merge();
        }

        sheet.Cell(bandRow, benchmarkCol).Value = "Average Days Taken";
        sheet.Range(bandRow, benchmarkCol, bandRow, lastColumn).Merge();

        sheet.Cell(headerRow, benchmarkCol).Value = "Benchmark";
        var col = firstMonthCol;
        foreach (var month in metrics.Months)
        {
            sheet.Cell(headerRow, col).Value = month.Label;
            col++;
        }

        var row = headerRow;
        for (var i = 0; i < LisKeyMetricRow.All.Count; i++)
        {
            var metric = LisKeyMetricRow.All[i];
            row++;
            sheet.Cell(row, indexCol).Value = i + 1;
            sheet.Cell(row, metricsCol).Value = metric.Description;
            sheet.Cell(row, partyCol).Value = metric.ResponsibleParty;
            WriteMetricCell(sheet.Cell(row, benchmarkCol), metric.Benchmark);

            col = firstMonthCol;
            foreach (var month in metrics.Months)
            {
                WriteMetricCell(sheet.Cell(row, col), metric.Value(month));
                col++;
            }
        }

        var lastRow = row;
        var table = sheet.Range(bandRow, indexCol, lastRow, lastColumn);
        table.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        table.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        table.Style.Border.OutsideBorderColor = BorderColor;
        table.Style.Border.InsideBorderColor = BorderColor;

        var headerRange = sheet.Range(bandRow, indexCol, headerRow, lastColumn);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Font.FontColor = XLColor.White;
        headerRange.Style.Fill.BackgroundColor = HeaderGreen;
        headerRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerRange.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

        sheet.Range(headerRow + 1, indexCol, lastRow, indexCol)
            .Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        sheet.Range(headerRow + 1, benchmarkCol, lastRow, lastColumn)
            .Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;

        sheet.Column(indexCol).Width = Math.Max(sheet.Column(indexCol).Width, 5);
        sheet.Column(metricsCol).Width = Math.Max(sheet.Column(metricsCol).Width, 18);
        sheet.Column(partyCol).Width = Math.Max(sheet.Column(partyCol).Width, 18);
        for (var c = benchmarkCol; c <= lastColumn; c++)
            sheet.Column(c).Width = Math.Max(sheet.Column(c).Width, 12);

        return lastRow;
    }

    private static void WriteMetricCell(IXLCell cell, double? value)
    {
        if (!value.HasValue)
        {
            cell.Value = string.Empty;
            return;
        }

        cell.Value = Math.Round(value.Value, 2);
        cell.Style.NumberFormat.Format = "0.##";
    }

    private static void BuildLineDataSheet(IXLWorksheet sheet, LisLineDataResult? lineData)
    {
        sheet.TabColor = ExcelTheme.Collection.TabGold;
        ExcelTheme.ApplyDefaults(sheet);

        if (lineData is null || lineData.Columns.Count == 0)
        {
            sheet.Cell(1, 1).Value = "No LIMS Master data found for the selected filters.";
            sheet.Cell(1, 1).Style.Font.Bold = true;
            sheet.Cell(1, 1).Style.Font.FontColor = HeaderGreen;
            sheet.Column(1).Width = 52;
            return;
        }

        for (var col = 0; col < lineData.Columns.Count; col++)
        {
            sheet.Cell(1, col + 1).Value = lineData.Columns[col].Header;
        }

        var rowNumber = 2;
        foreach (var row in lineData.Rows)
        {
            for (var col = 0; col < lineData.Columns.Count; col++)
            {
                var column = lineData.Columns[col];
                sheet.Cell(rowNumber, col + 1).Value = row.TryGetValue(column.Key, out var value) ? value : string.Empty;
            }

            rowNumber++;
        }

        var lastRow = Math.Max(1, rowNumber - 1);
        var lastColumn = Math.Max(1, lineData.Columns.Count);
        var header = sheet.Range(1, 1, 1, lastColumn);
        header.Style.Font.Bold = true;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Fill.BackgroundColor = HeaderGreen;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        header.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        header.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        header.Style.Border.OutsideBorderColor = XLColor.White;
        header.Style.Border.InsideBorderColor = XLColor.White;

        var usedRange = sheet.Range(1, 1, lastRow, lastColumn);
        usedRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        usedRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        usedRange.Style.Border.OutsideBorderColor = BorderColor;
        usedRange.Style.Border.InsideBorderColor = BorderColor;

        // Header frozen and filterable; widths fixed to the content so nothing is clipped and
        // no column runs away on one long free-text value.
        sheet.SheetView.FreezeRows(1);
        sheet.Row(1).Height = 26;
        usedRange.SetAutoFilter();
        ApplyFixedColumnWidths(sheet, lastColumn, lastRow);
    }

    /// <summary>
    /// Sizes every column to its content once, then clamps to a fixed band. AdjustToContents is
    /// sampled over the first rows only — on a million-row sheet measuring every cell is far too
    /// slow, and the header plus the first screenful already determine a sensible width.
    /// </summary>
    private static void ApplyFixedColumnWidths(IXLWorksheet sheet, int lastColumn, int lastRow, double min = 12, double max = 42)
    {
        var sampleLastRow = Math.Min(lastRow, 500);

        // By index, not Columns(..): ClosedXML mutates its column collection while adjusting,
        // which throws "Collection was modified" when enumerating the live collection.
        for (var c = 1; c <= lastColumn; c++)
        {
            var column = sheet.Column(c);
            column.AdjustToContents(1, sampleLastRow);
            column.Width = Math.Clamp(column.Width, min, max);
        }
    }

    private static void WriteDataRow(IXLWorksheet sheet, int rowNumber, LisSummaryRow row, IReadOnlyList<MonthColumn> monthColumns, IReadOnlyList<int> years, int firstDataColumn, bool includeLogicColumn)
    {
        sheet.Cell(rowNumber, 1).Value = row.Code;
        sheet.Cell(rowNumber, 2).Value = row.Description;
        if (includeLogicColumn)
        {
            sheet.Cell(rowNumber, 3).Value = row.Logic;
        }

        var col = firstDataColumn;
        foreach (var year in years.OrderBy(x => x))
        {
            foreach (var monthColumn in monthColumns.Where(x => x.Year == year && !x.IsYearTotal))
            {
                sheet.Cell(rowNumber, col).Value = row.ByMonth.TryGetValue(monthColumn.Key, out var count) ? count : 0;
                col++;
            }

            sheet.Cell(rowNumber, col).Value = row.ByYear.TryGetValue(year, out var total) ? total : 0;
            col++;
        }

        sheet.Cell(rowNumber, col).Value = row.Total;
        sheet.Cell(rowNumber, col).Style.Fill.BackgroundColor = TotalGreen;
        sheet.Cell(rowNumber, col).Style.Font.Bold = true;
    }

    private static void WriteGrandTotalRow(IXLWorksheet sheet, int rowNumber, LisSummaryResult result, IReadOnlyList<MonthColumn> monthColumns, IReadOnlyList<int> years, int firstDataColumn, int lastColumn)
    {
        sheet.Cell(rowNumber, 1).Value = string.Empty;
        sheet.Cell(rowNumber, 2).Value = "Grand Total";
        if (firstDataColumn == 4)
        {
            sheet.Cell(rowNumber, 3).Value = string.Empty;
        }

        var col = firstDataColumn;
        foreach (var year in years.OrderBy(x => x))
        {
            foreach (var monthColumn in monthColumns.Where(x => x.Year == year && !x.IsYearTotal))
            {
                sheet.Cell(rowNumber, col).Value = result.GrandTotalByMonth.TryGetValue(monthColumn.Key, out var count) ? count : 0;
                col++;
            }

            sheet.Cell(rowNumber, col).Value = result.GrandTotalByYear.TryGetValue(year, out var total) ? total : 0;
            col++;
        }

        sheet.Cell(rowNumber, col).Value = result.GrandTotal;
        var range = sheet.Range(rowNumber, 1, rowNumber, lastColumn);
        range.Style.Font.Bold = true;
        range.Style.Font.FontColor = XLColor.White;
        range.Style.Fill.BackgroundColor = TotalGreen;
    }

    private static void ApplyRowStyle(IXLWorksheet sheet, int rowNumber, int level, int lastColumn)
    {
        var range = sheet.Range(rowNumber, 1, rowNumber, lastColumn);
        if (level <= 0)
        {
            range.Style.Font.Bold = true;
            range.Style.Fill.BackgroundColor = XLColor.White;
            range.Style.Font.FontColor = XLColor.Black;
        }
        else if (level == 1)
        {
            // Billed / Not Billed under Billable, Self-Pay, System Test, etc.
            range.Style.Fill.BackgroundColor = MonthHeaderBg;
            range.Style.Font.FontColor = ExcelTheme.Collection.ContrastOn(MonthHeaderBg);
            sheet.Cell(rowNumber, 2).Style.Font.Bold = true;
        }
        else
        {
            range.Style.Fill.BackgroundColor = ChildBg;
            range.Style.Font.FontColor = ExcelTheme.Collection.ContrastOn(ChildBg);
            sheet.Cell(rowNumber, 2).Style.Alignment.Indent = Math.Min(level, 4);
        }
    }

    private static List<MonthColumn> BuildMonthColumns(IReadOnlyList<string> months, IReadOnlyList<int> years)
    {
        var result = new List<MonthColumn>();
        foreach (var year in years.OrderBy(x => x))
        {
            var yearMonths = months
                .Where(x => x.StartsWith($"{year:D4}-", StringComparison.OrdinalIgnoreCase))
                .OrderBy(x => x)
                .ToList();

            foreach (var monthKey in yearMonths)
            {
                var month = int.Parse(monthKey[^2..]);
                result.Add(new MonthColumn(monthKey, year, new DateTime(year, month, 1).ToString("MMM-yyyy"), false));
            }

            if (yearMonths.Count > 0)
            {
                result.Add(new MonthColumn($"{year:D4}-TOTAL", year, $"{year} Total", true));
            }
        }

        return result;
    }

    private static string FormatDateFilter(DateOnly? value) => value?.ToString("MM/dd/yyyy") ?? "All";

    private static string FormatFilter(string? value)
        => string.IsNullOrWhiteSpace(value)
            ? "All"
            : string.Join(", ", value.Split(['|'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));

    private static string CleanSheetName(string value)
    {
        var invalid = new[] { ':', '\\', '/', '?', '*', '[', ']' };
        var clean = invalid.Aggregate(value, (current, ch) => current.Replace(ch, '-')).Trim();
        if (string.IsNullOrWhiteSpace(clean)) clean = "LIS Summary";
        return clean.Length > 31 ? clean[..31] : clean;
    }

    private sealed record MonthColumn(string Key, int Year, string Label, bool IsYearTotal);
}
