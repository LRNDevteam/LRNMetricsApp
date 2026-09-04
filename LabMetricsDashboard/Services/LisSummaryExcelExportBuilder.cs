using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

public static class LisSummaryExcelExportBuilder
{
    /// <summary>Sheet holding the filter snapshot, kept off the summary sheet itself.</summary>
    public const string FilterSheetName = "Filtered Values";

    // Green family, shared with the Denial Dashboard workbook via ExcelTheme.
    private static readonly XLColor HeaderGreen = ExcelTheme.HeaderBg;      // #548235 month headers
    private static readonly XLColor YearGreen = ExcelTheme.TitleBg;         // #385723 year band
    private static readonly XLColor TotalGreen = ExcelTheme.GroupRowBg;     // #C5E0B4 total columns
    private static readonly XLColor BorderColor = ExcelTheme.BorderColor;
    private static readonly XLColor SectionGreen = ExcelTheme.BandedRowBg;  // #E2EFDA section rows

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
        sheet.TabColor = ExcelTheme.TabGreen;
        sheet.ShowGridLines = false;
        ExcelTheme.ApplyDefaults(sheet);

        sheet.Cell(1, 1).Value = "Filtered Values";
        sheet.Range(1, 1, 1, 2).Merge();
        var title = sheet.Cell(1, 1);
        title.Style.Font.Bold = true;
        title.Style.Font.FontSize = ExcelTheme.FontSizeTitle;
        title.Style.Font.FontColor = XLColor.White;
        title.Style.Fill.BackgroundColor = ExcelTheme.TitleBg;
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
        sheet.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(sheet);

        var includeLogicColumn = false;
        var firstDataColumn = 3;
        var titleRow = 1;

        // Filters now live on their own "Filtered Values" sheet, so the pivot starts near the
        // top instead of below eleven rows of metadata.
        var sampleNoteRow = 2;
        var yearHeaderRow = 4;
        var monthHeaderRow = 5;
        var dataStartRow = 6;

        var lastColumn = firstDataColumn + monthColumns.Count;

        sheet.Cell(titleRow, 1).Value = $"LIS Summary — {labName}";
        sheet.Range(titleRow, 1, titleRow, lastColumn).Merge();
        sheet.Cell(titleRow, 1).Style.Font.Bold = true;
        sheet.Cell(titleRow, 1).Style.Font.FontSize = ExcelTheme.FontSizeTitle;
        sheet.Cell(titleRow, 1).Style.Font.FontColor = ExcelTheme.TitleBg;

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
            sheet.Cell(yearHeaderRow, yearStart).Value = year;
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
        var grandTotalHeader = sheet.Range(yearHeaderRow, lastColumn, monthHeaderRow, lastColumn);
        grandTotalHeader.Style.Fill.BackgroundColor = ExcelTheme.GoldAccent;
        grandTotalHeader.Style.Font.FontColor = XLColor.Black;

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

        sheet.Columns(firstDataColumn, lastColumn).Style.NumberFormat.Format = "#,##0";
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

    private static void BuildLineDataSheet(IXLWorksheet sheet, LisLineDataResult? lineData)
    {
        sheet.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(sheet);

        if (lineData is null || lineData.Columns.Count == 0)
        {
            sheet.Cell(1, 1).Value = "No LIMS Master data found for the selected filters.";
            sheet.Cell(1, 1).Style.Font.Bold = true;
            sheet.Cell(1, 1).Style.Font.FontColor = ExcelTheme.TitleBg;
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
        header.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
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
            sheet.Cell(rowNumber, col).Style.Fill.BackgroundColor = XLColor.FromHtml("#F8FBFF");
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
        range.Style.Fill.BackgroundColor = TotalGreen;
    }

    private static void ApplyRowStyle(IXLWorksheet sheet, int rowNumber, int level, int lastColumn)
    {
        var range = sheet.Range(rowNumber, 1, rowNumber, lastColumn);
        if (level <= 0)
        {
            range.Style.Font.Bold = true;
            range.Style.Fill.BackgroundColor = XLColor.FromHtml("#F6F9FC");
        }
        else if (level == 1)
        {
            sheet.Cell(rowNumber, 2).Style.Font.Bold = true;
        }
        else
        {
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
