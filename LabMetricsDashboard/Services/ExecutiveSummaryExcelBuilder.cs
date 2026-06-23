using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using System.Data;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Creates an Excel workbook from an Executive Summary view model.
/// The layout mirrors the on-screen report, with tabs for each category
/// (LIS, PMS, Cash, Avg) and consistent styling.
/// </summary>
public sealed class ExecutiveSummaryExcelBuilder
{
    public byte[] Build(PhiExecutiveSummaryViewModel vm)
    {
        using var workbook = new XLWorkbook();
        var tabs = new[] { "LIS", "PMS", "Cash", "Avg" };

        foreach (var tab in tabs)
        {
            var rows = vm.Rows.Where(r => r.Category == tab).ToList();
            if (rows.Count == 0) continue;

            var sheet = workbook.Worksheets.Add(TabLabel(tab));
            CreateSheet(sheet, rows, vm.YearMonthColumns);
        }

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private void CreateSheet(IXLWorksheet sheet, List<ExecSummaryRow> rows,
        List<(int Year, int Month)> columns)
    {
        var years = columns.Where(c => c.Year != 0).Select(c => c.Year).Distinct().OrderBy(y => y).ToList();
        var monthsByYear = columns.Where(c => c.Year != 0)
            .GroupBy(c => c.Year)
            .ToDictionary(g => g.Key, g => g.Select(c => c.Month).OrderBy(m => m).ToList());

        var darkBlue = XLColor.FromHtml("#0e3460");
        var gold = XLColor.FromHtml("#a16207");
        var grandBrown = XLColor.FromHtml("#92400e");
        var yearTint = XLColor.FromHtml("#fefce8");
        var grandTint = XLColor.FromHtml("#fef3c7");
        var catGreen = XLColor.FromHtml("#f0fdf4");

        // ── Header row 1: year group bands + Grand Total ──
        sheet.Cell(1, 1).Value = "Description";
        sheet.Range(1, 1, 2, 1).Merge();
        var colIdx = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1; // months + {year} Total
            var bandStart = colIdx;
            sheet.Cell(1, colIdx).Value = $"Data Based on DOS — {year}";
            sheet.Range(1, bandStart, 1, bandStart + span - 1).Merge();
            colIdx += span;
        }
        var grandCol = colIdx;
        sheet.Cell(1, grandCol).Value = "Grand Total";
        sheet.Range(1, grandCol, 2, grandCol).Merge();

        // ── Header row 2: month names + {year} Total ──
        colIdx = 2;
        foreach (var year in years)
        {
            foreach (var m in monthsByYear[year])
            {
                sheet.Cell(2, colIdx).Value = MonthName(m).ToUpper();
                colIdx++;
            }
            var yt = sheet.Cell(2, colIdx);
            yt.Value = $"{year} Total";
            yt.Style.Fill.BackgroundColor = gold;
            yt.Style.Font.FontColor = XLColor.White;
            colIdx++;
        }

        // Style header band
        var header = sheet.Range(1, 1, 2, grandCol);
        header.Style.Font.Bold = true;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        for (int r = 1; r <= 2; r++)
        {
            sheet.Cell(r, 1).Style.Fill.BackgroundColor = darkBlue;
            sheet.Cell(r, 1).Style.Font.FontColor = XLColor.White;
            sheet.Cell(r, grandCol).Style.Fill.BackgroundColor = grandBrown;
            sheet.Cell(r, grandCol).Style.Font.FontColor = XLColor.White;
        }
        // Year band cells (row 1) default blue except the merged Grand Total
        colIdx = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1;
            sheet.Cell(1, colIdx).Style.Fill.BackgroundColor = darkBlue;
            sheet.Cell(1, colIdx).Style.Font.FontColor = XLColor.White;
            // month name cells (row 2) blue
            for (int i = 0; i < mons.Count; i++)
            {
                sheet.Cell(2, colIdx + i).Style.Fill.BackgroundColor = darkBlue;
                sheet.Cell(2, colIdx + i).Style.Font.FontColor = XLColor.White;
            }
            colIdx += span;
        }

        // ── Data rows ──
        var rowIdx = 3;
        foreach (var row in rows)
        {
            sheet.Cell(rowIdx, 1).Value = row.Description.TrimStart();
            colIdx = 2;
            foreach (var year in years)
            {
                foreach (var m in monthsByYear[year])
                {
                    row.ValuesByYearMonth.TryGetValue((year, m), out var val);
                    var cell = sheet.Cell(rowIdx, colIdx);
                    if (val != 0) cell.Value = (double)val;
                    SetNumberFormat(cell, row.Category);
                    colIdx++;
                }
                // {year} total
                var ytVal = row.ValuesByYearMonth.Where(kv => kv.Key.Year == year && kv.Key.Month != 0).Sum(kv => kv.Value);
                var ytCell = sheet.Cell(rowIdx, colIdx);
                if (ytVal != 0) ytCell.Value = (double)ytVal;
                SetNumberFormat(ytCell, row.Category);
                ytCell.Style.Fill.BackgroundColor = yearTint;
                ytCell.Style.Font.Bold = true;
                colIdx++;
            }
            // grand total
            var grandVal = row.ValuesByYearMonth.Where(kv => kv.Key.Year != 0 && kv.Key.Month != 0).Sum(kv => kv.Value);
            var grandCell = sheet.Cell(rowIdx, grandCol);
            if (grandVal != 0) grandCell.Value = (double)grandVal;
            SetNumberFormat(grandCell, row.Category);
            grandCell.Style.Fill.BackgroundColor = grandTint;
            grandCell.Style.Font.Bold = true;

            if (row.IsSubRow)
            {
                sheet.Cell(rowIdx, 1).Style.Alignment.Indent = 2;
            }
            else
            {
                sheet.Cell(rowIdx, 1).Style.Fill.BackgroundColor = catGreen;
                sheet.Cell(rowIdx, 1).Style.Font.Bold = true;
            }

            rowIdx++;
        }

        sheet.SheetView.FreezeRows(2);
        sheet.SheetView.FreezeColumns(1);
        sheet.Columns().AdjustToContents();
    }

    private void SetNumberFormat(IXLCell cell, string category)
    {
        if (IsDollar(category))
            cell.Style.NumberFormat.Format = "$#,##0";
        else
            cell.Style.NumberFormat.Format = "#,##0";
    }

    private static bool IsDollar(string cat) => cat is "Cash" or "Avg";
    private static string MonthName(int m) => m == 0 ? "Total" :
        System.Globalization.CultureInfo.InvariantCulture.DateTimeFormat.GetAbbreviatedMonthName(m);
    private static string TabLabel(string cat) => cat switch
    {
        "LIS" => "LIS Breakdown",
        "PMS" => "PMS Breakdown",
        "Cash" => "Cash Breakdown",
        "Avg" => "Averages",
        _ => cat
    };
}
