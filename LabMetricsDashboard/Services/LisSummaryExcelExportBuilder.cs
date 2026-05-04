using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

public static class LisSummaryExcelExportBuilder
{
    private static readonly XLColor HeaderBlue = XLColor.FromHtml("#DCE8F6");
    private static readonly XLColor YearBlue = XLColor.FromHtml("#BFD5EE");
    private static readonly XLColor TotalYellow = XLColor.FromHtml("#FFF2CC");
    private static readonly XLColor BorderColor = XLColor.FromHtml("#AFC4DF");
    private static readonly XLColor SectionBlue = XLColor.FromHtml("#EAF3FF");

    public static XLWorkbook CreateWorkbook(LisSummaryResult result, string labName, DateOnly? collectedFrom, DateOnly? collectedTo)
    {
        var workbook = new XLWorkbook();
        var worksheetName = CleanSheetName(string.IsNullOrWhiteSpace(result.LogicSheetName) ? "LIS Summary" : result.LogicSheetName);
        var sheet = workbook.Worksheets.Add(worksheetName);

        BuildSummarySheet(sheet, result, labName, collectedFrom, collectedTo);

        workbook.Properties.Title = $"LIS Summary - {labName}";
        workbook.Properties.Subject = "LIS Summary";
        workbook.Properties.Author = "LabMetricsDashboard";
        return workbook;
    }

    private static void BuildSummarySheet(IXLWorksheet sheet, LisSummaryResult result, string labName, DateOnly? collectedFrom, DateOnly? collectedTo)
    {
        var monthColumns = BuildMonthColumns(result.Months, result.Years);

        var includeLogicColumn = ShouldUseUploadedLogicTemplate(result.LogicSheetName);
        // Default export keeps previous compact format: Code, Description, months.
        // Augustus and Certus use the uploaded workbook template: S.No, Description, Logic, months.
        var firstDataColumn = includeLogicColumn ? 4 : 3;
        var titleRow = 1;
        var metaStartRow = 2;
        var sampleNoteRow = 6;
        var yearHeaderRow = 7;
        var monthHeaderRow = 8;
        var dataStartRow = 9;

        var lastColumn = firstDataColumn + monthColumns.Count;

        sheet.Cell(titleRow, 1).Value = "LIS Summary";
        sheet.Range(titleRow, 1, titleRow, lastColumn).Merge();
        sheet.Cell(titleRow, 1).Style.Font.Bold = true;
        sheet.Cell(titleRow, 1).Style.Font.FontSize = 16;
        sheet.Cell(titleRow, 1).Style.Font.FontColor = XLColor.FromHtml("#1B3A5C");

        sheet.Cell(2, 1).Value = "Lab";
        sheet.Cell(2, 2).Value = labName;
        sheet.Cell(3, 1).Value = "Logic Sheet";
        sheet.Cell(3, 2).Value = result.LogicSheetName;
        sheet.Cell(4, 1).Value = "Collected Date";
        sheet.Cell(4, 2).Value = BuildDateRangeLabel(collectedFrom, collectedTo);

        sheet.Range(metaStartRow, 1, 4, 1).Style.Font.Bold = true;
        sheet.Range(metaStartRow, 1, 4, 2).Style.Fill.BackgroundColor = SectionBlue;
        sheet.Range(metaStartRow, 1, 4, 2).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        sheet.Range(metaStartRow, 1, 4, 2).Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        sheet.Range(metaStartRow, 1, 4, 2).Style.Border.OutsideBorderColor = BorderColor;
        sheet.Range(metaStartRow, 1, 4, 2).Style.Border.InsideBorderColor = BorderColor;

        sheet.Cell(sampleNoteRow, 1).Value = "Sample Count = Count [Unique Accession / Order ID]";
        sheet.Range(sampleNoteRow, 1, sampleNoteRow, Math.Min(lastColumn, 6)).Merge();
        sheet.Cell(sampleNoteRow, 1).Style.Font.Italic = true;
        sheet.Cell(sampleNoteRow, 1).Style.Font.FontColor = XLColor.FromHtml("#5C738A");

        sheet.Cell(yearHeaderRow, 1).Value = includeLogicColumn ? "S.No" : "Logic";
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
        headerRange.Style.Fill.BackgroundColor = HeaderBlue;
        headerRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        headerRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        headerRange.Style.Border.OutsideBorderColor = BorderColor;
        headerRange.Style.Border.InsideBorderColor = BorderColor;

        sheet.Range(yearHeaderRow, firstDataColumn, yearHeaderRow, lastColumn).Style.Fill.BackgroundColor = YearBlue;
        sheet.Range(yearHeaderRow, lastColumn, monthHeaderRow, lastColumn).Style.Fill.BackgroundColor = TotalYellow;

        var rowNumber = dataStartRow;
        foreach (var row in result.Rows)
        {
            WriteDataRow(sheet, rowNumber, row, monthColumns, result.Years, firstDataColumn, includeLogicColumn);
            ApplyRowStyle(sheet, rowNumber, row.Level, lastColumn);
            rowNumber++;
        }

        WriteGrandTotalRow(sheet, rowNumber, result, monthColumns, result.Years, firstDataColumn, lastColumn);

        // Border for all used cells including title/meta/sample note/table.
        var fullRange = sheet.Range(1, 1, rowNumber, lastColumn);
        fullRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        fullRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        fullRange.Style.Border.OutsideBorderColor = BorderColor;
        fullRange.Style.Border.InsideBorderColor = XLColor.FromHtml("#DDE7F0");

        // Stronger table borders.
        var tableRange = sheet.Range(yearHeaderRow, 1, rowNumber, lastColumn);
        tableRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        tableRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        tableRange.Style.Border.OutsideBorderColor = BorderColor;
        tableRange.Style.Border.InsideBorderColor = BorderColor;

        sheet.SheetView.FreezeRows(monthHeaderRow);
        sheet.SheetView.FreezeColumns(includeLogicColumn ? 3 : 2);

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
        sheet.Range(dataStartRow, 1, rowNumber, includeLogicColumn ? 3 : 2).Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;

        sheet.PageSetup.PageOrientation = XLPageOrientation.Landscape;
        sheet.PageSetup.FitToPages(1, 0);
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
        sheet.Cell(rowNumber, col).Style.Fill.BackgroundColor = TotalYellow;
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
        range.Style.Fill.BackgroundColor = TotalYellow;
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
            sheet.Cell(rowNumber, 2).Style.Alignment.Indent = 2;
        }
    }

    private static bool ShouldUseUploadedLogicTemplate(string logicSheetName)
        => true;

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

    private static string BuildDateRangeLabel(DateOnly? from, DateOnly? to)
    {
        if (from.HasValue && to.HasValue) return $"{from:MM/dd/yyyy} to {to:MM/dd/yyyy}";
        if (from.HasValue) return $"From {from:MM/dd/yyyy}";
        if (to.HasValue) return $"Until {to:MM/dd/yyyy}";
        return "All collected dates";
    }

    private static string CleanSheetName(string value)
    {
        var invalid = new[] { ':', '\\', '/', '?', '*', '[', ']' };
        var clean = invalid.Aggregate(value, (current, ch) => current.Replace(ch, '-')).Trim();
        if (string.IsNullOrWhiteSpace(clean)) clean = "LIS Summary";
        return clean.Length > 31 ? clean[..31] : clean;
    }

    private sealed record MonthColumn(string Key, int Year, string Label, bool IsYearTotal);
}
