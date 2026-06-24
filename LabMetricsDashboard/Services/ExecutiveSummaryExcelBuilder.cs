using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using System.Data;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Creates an Excel workbook from an Executive Summary view model.
/// All categories (LIS, PMS, Cash, Avg) are written to a single sheet,
/// one after another, each preceded by a coloured section-heading row.
/// </summary>
public sealed class ExecutiveSummaryExcelBuilder
{
    private static readonly string[] Sections = ["LIS", "PMS", "Cash", "Avg"];

    public byte[] Build(PhiExecutiveSummaryViewModel vm)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Executive Summary");
        BuildSheet(sheet, vm.Rows, vm.YearMonthColumns);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private void BuildSheet(IXLWorksheet sheet, List<ExecSummaryRow> allRows,
        List<(int Year, int Month)> columns)
    {
        var years = columns.Where(c => c.Year != 0).Select(c => c.Year).Distinct().OrderBy(y => y).ToList();
        var monthsByYear = columns.Where(c => c.Year != 0)
            .GroupBy(c => c.Year)
            .ToDictionary(g => g.Key, g => g.Select(c => c.Month).OrderBy(m => m).ToList());

        // Total number of data columns
        int totalDataCols = years.Sum(y => monthsByYear[y].Count + 1); // months + year total per year
        var grandCol = 2 + totalDataCols;

        var darkBlue  = XLColor.FromHtml("#0e3460");
        var gold      = XLColor.FromHtml("#a16207");
        var grandBrown= XLColor.FromHtml("#92400e");
        var yearTint  = XLColor.FromHtml("#fefce8");
        var grandTint = XLColor.FromHtml("#fef3c7");
        var catGreen  = XLColor.FromHtml("#f0fdf4");

        // Section heading colours (one per category, in order)
        var sectionColors = new Dictionary<string, XLColor>
        {
            ["LIS"]  = XLColor.FromHtml("#1e3a5f"),
            ["PMS"]  = XLColor.FromHtml("#1a4731"),
            ["Cash"] = XLColor.FromHtml("#4a1942"),
            ["Avg"]  = XLColor.FromHtml("#7c2d12"),
        };

        // ── Header rows 1-2 (written once at the top) ────────────────────────

        sheet.Cell(1, 1).Value = "Description";
        sheet.Range(1, 1, 2, 1).Merge();

        var colIdx = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1;
            sheet.Cell(1, colIdx).Value = $"Data Based on DOS — {year}";
            sheet.Range(1, colIdx, 1, colIdx + span - 1).Merge();
            colIdx += span;
        }

        sheet.Cell(1, grandCol).Value = "Grand Total";
        sheet.Range(1, grandCol, 2, grandCol).Merge();

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

        // Style the two header rows
        var headerRange = sheet.Range(1, 1, 2, grandCol);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerRange.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;

        for (int r = 1; r <= 2; r++)
        {
            sheet.Cell(r, 1).Style.Fill.BackgroundColor = darkBlue;
            sheet.Cell(r, 1).Style.Font.FontColor       = XLColor.White;
            sheet.Cell(r, grandCol).Style.Fill.BackgroundColor = grandBrown;
            sheet.Cell(r, grandCol).Style.Font.FontColor       = XLColor.White;
        }
        colIdx = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1;
            sheet.Cell(1, colIdx).Style.Fill.BackgroundColor = darkBlue;
            sheet.Cell(1, colIdx).Style.Font.FontColor       = XLColor.White;
            for (int i = 0; i < mons.Count; i++)
            {
                sheet.Cell(2, colIdx + i).Style.Fill.BackgroundColor = darkBlue;
                sheet.Cell(2, colIdx + i).Style.Font.FontColor       = XLColor.White;
            }
            colIdx += span;
        }

        // Outline summaries above their group
        sheet.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        // ── Data sections ─────────────────────────────────────────────────────

        var rowIdx = 3;

        foreach (var section in Sections)
        {
            var rows = allRows.Where(r => r.Category == section).ToList();
            if (rows.Count == 0) continue;

            // Section heading row (spans all columns)
            var headingColor = sectionColors.GetValueOrDefault(section, darkBlue);
            var headingCell  = sheet.Cell(rowIdx, 1);
            headingCell.Value = SectionLabel(section);
            headingCell.Style.Fill.BackgroundColor = headingColor;
            headingCell.Style.Font.FontColor       = XLColor.White;
            headingCell.Style.Font.Bold            = true;
            headingCell.Style.Font.FontSize        = 12;
            headingCell.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
            if (grandCol > 1)
                sheet.Range(rowIdx, 1, rowIdx, grandCol).Merge();
            sheet.Row(rowIdx).Height = 20;
            rowIdx++;

            // Data rows for this section
            foreach (var row in rows)
            {
                int leadingSpaces = row.Description.Length - row.Description.TrimStart().Length;
                int outlineLevel  = leadingSpaces / 2;

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
                    // Year total
                    var ytVal = row.ValuesByYearMonth
                        .Where(kv => kv.Key.Year == year && kv.Key.Month != 0)
                        .Sum(kv => kv.Value);
                    var ytCell = sheet.Cell(rowIdx, colIdx);
                    if (ytVal != 0) ytCell.Value = (double)ytVal;
                    SetNumberFormat(ytCell, row.Category);
                    ytCell.Style.Fill.BackgroundColor = yearTint;
                    ytCell.Style.Font.Bold = true;
                    colIdx++;
                }

                // Grand total
                var grandVal = row.ValuesByYearMonth
                    .Where(kv => kv.Key.Year != 0 && kv.Key.Month != 0)
                    .Sum(kv => kv.Value);
                var grandCell = sheet.Cell(rowIdx, grandCol);
                if (grandVal != 0) grandCell.Value = (double)grandVal;
                SetNumberFormat(grandCell, row.Category);
                grandCell.Style.Fill.BackgroundColor = grandTint;
                grandCell.Style.Font.Bold = true;

                if (outlineLevel > 0)
                {
                    sheet.Row(rowIdx).Group(outlineLevel);
                    sheet.Cell(rowIdx, 1).Style.Alignment.Indent = outlineLevel * 2;
                }
                else
                {
                    sheet.Cell(rowIdx, 1).Style.Fill.BackgroundColor = catGreen;
                    sheet.Cell(rowIdx, 1).Style.Font.Bold = true;
                }

                rowIdx++;
            }

            // Blank separator row between sections (skip after last)
            if (section != Sections.Last(s => allRows.Any(r => r.Category == s)))
                rowIdx++;
        }

        sheet.SheetView.FreezeRows(2);
        sheet.SheetView.FreezeColumns(1);
        sheet.Columns().AdjustToContents();
    }

    private void SetNumberFormat(IXLCell cell, string category)
    {
        cell.Style.NumberFormat.Format = IsDollar(category) ? "$#,##0" : "#,##0";
    }

    private static bool IsDollar(string cat) => cat is "Cash" or "Avg";

    private static string MonthName(int m) =>
        System.Globalization.CultureInfo.InvariantCulture.DateTimeFormat.GetAbbreviatedMonthName(m);

    private static string SectionLabel(string cat) => cat switch
    {
        "LIS"  => "LIS Breakdown",
        "PMS"  => "PMS Breakdown",
        "Cash" => "Cash Breakdown",
        "Avg"  => "Averages",
        _      => cat
    };
}
