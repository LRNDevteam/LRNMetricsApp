using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using System.Data;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Creates an Excel workbook from an Executive Summary view model.
/// A metadata block (analysis / week range + applied filters) is written at
/// the top, followed by all categories (LIS, PMS, Cash, Avg) on a single
/// sheet, each preceded by a coloured section-heading row.
/// </summary>
public sealed class ExecutiveSummaryExcelBuilder
{
    private static readonly string[] Sections = ["LIS", "PMS", "Cash", "Avg"];

    public byte[] Build(PhiExecutiveSummaryViewModel vm)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Executive Summary");

        // Work out how wide the table is so the info block can span it.
        var columns = vm.YearMonthColumns;
        var years = columns.Where(c => c.Year != 0).Select(c => c.Year).Distinct().OrderBy(y => y).ToList();
        var monthsByYear = columns.Where(c => c.Year != 0)
            .GroupBy(c => c.Year)
            .ToDictionary(g => g.Key, g => g.Select(c => c.Month).OrderBy(m => m).ToList());
        int totalDataCols = years.Sum(y => monthsByYear[y].Count + 1);
        int grandCol = 2 + totalDataCols;

        // Top metadata block; returns the first row for the data table header.
        int startRow = WriteInfoBlock(sheet, vm, grandCol);

        BuildSheet(sheet, vm.Rows, vm.YearMonthColumns, startRow);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    /// <summary>
    /// Writes the title, analysis/week range banner and the applied filter
    /// details at the top of the sheet. Returns the next free row (where the
    /// data-table header should begin).
    /// </summary>
    private int WriteInfoBlock(IXLWorksheet sheet, PhiExecutiveSummaryViewModel vm, int grandCol)
    {
        var darkBlue = XLColor.FromHtml("#0e3460");
        int lastCol  = Math.Max(grandCol, 2);
        int r = 1;

        void Line(string text, bool bold, bool title = false, bool sectionHead = false)
        {
            var cell = sheet.Cell(r, 1);
            cell.Value = text;
            cell.Style.Font.Bold = bold;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
            cell.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
            if (title)
            {
                cell.Style.Font.FontSize  = 14;
                cell.Style.Font.FontColor = darkBlue;
            }
            if (sectionHead)
            {
                cell.Style.Font.FontColor = darkBlue;
                cell.Style.Font.FontSize  = 11;
            }
            sheet.Range(r, 1, r, lastCol).Merge();
            r++;
        }

        // ── Title + analysis / week range banner ─────────────────────────────
        Line($"Executive Summary — {Blank(vm.SelectedLab, "All Labs")}", bold: true, title: true);

        if (!string.IsNullOrWhiteSpace(vm.ReportWeekFolder))
            Line($"Analysis Range:  Billed Week Range — {vm.ReportWeekFolder}", bold: true);
        if (!string.IsNullOrWhiteSpace(vm.ReportRunId))
            Line($"ReportId (RunID):  {vm.ReportRunId}", bold: false);
        if (!string.IsNullOrWhiteSpace(vm.LimsRunId))
            Line($"LIMSMaster RunID:  {vm.LimsRunId}", bold: false);

        Line($"Generated:  {DateTime.Now:MM/dd/yyyy hh:mm tt}", bold: false);

        r++; // blank spacer

        // ── Applied filters ──────────────────────────────────────────────────
        Line("Applied Filters", bold: true, sectionHead: true);
        Line($"Date of Service:  {DateRange(vm.DosFrom, vm.DosTo)}", bold: false);
        Line($"First Billed Date:  {DateRange(vm.BilledFrom, vm.BilledTo)}", bold: false);
        if (vm.SelectedYearFrom.HasValue || vm.SelectedYearTo.HasValue
            || vm.SelectedMonthFrom.HasValue || vm.SelectedMonthTo.HasValue)
        {
            Line($"Year Range:  {NumRange(vm.SelectedYearFrom, vm.SelectedYearTo)}", bold: false);
            Line($"Month Range:  {NumRange(vm.SelectedMonthFrom, vm.SelectedMonthTo)}", bold: false);
        }
        Line($"Panel:  {ListOrAll(vm.SelectedPanels)}", bold: false);
        Line($"Clinics:  {ListOrAll(vm.SelectedClinics)}", bold: false);
        Line($"Referring Provider:  {ListOrAll(vm.SelectedProviders)}", bold: false);
        Line($"Sales Rep:  {ListOrAll(vm.SelectedReps)}", bold: false);

        r++; // blank spacer before the data table

        return r;
    }

    private void BuildSheet(IXLWorksheet sheet, List<ExecSummaryRow> allRows,
        List<(int Year, int Month)> columns, int startRow)
    {
        var years = columns.Where(c => c.Year != 0).Select(c => c.Year).Distinct().OrderBy(y => y).ToList();
        var monthsByYear = columns.Where(c => c.Year != 0)
            .GroupBy(c => c.Year)
            .ToDictionary(g => g.Key, g => g.Select(c => c.Month).OrderBy(m => m).ToList());

        // Total number of data columns
        int totalDataCols = years.Sum(y => monthsByYear[y].Count + 1); // months + year total per year
        var grandCol = 2 + totalDataCols;

        // Header occupies two rows starting at startRow; data begins after.
        int hr1 = startRow;
        int hr2 = startRow + 1;

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

        // ── Header rows (written once at the top of the table) ───────────────

        sheet.Cell(hr1, 1).Value = "Description";
        sheet.Range(hr1, 1, hr2, 1).Merge();

        var colIdx = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1;
            sheet.Cell(hr1, colIdx).Value = $"Data Based on DOS — {year}";
            sheet.Range(hr1, colIdx, hr1, colIdx + span - 1).Merge();
            colIdx += span;
        }

        sheet.Cell(hr1, grandCol).Value = "Grand Total";
        sheet.Range(hr1, grandCol, hr2, grandCol).Merge();

        colIdx = 2;
        foreach (var year in years)
        {
            foreach (var m in monthsByYear[year])
            {
                sheet.Cell(hr2, colIdx).Value = MonthName(m).ToUpper();
                colIdx++;
            }
            var yt = sheet.Cell(hr2, colIdx);
            yt.Value = $"{year} Total";
            yt.Style.Fill.BackgroundColor = gold;
            yt.Style.Font.FontColor = XLColor.White;
            colIdx++;
        }

        // Style the two header rows
        var headerRange = sheet.Range(hr1, 1, hr2, grandCol);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerRange.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;

        for (int r = hr1; r <= hr2; r++)
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
            sheet.Cell(hr1, colIdx).Style.Fill.BackgroundColor = darkBlue;
            sheet.Cell(hr1, colIdx).Style.Font.FontColor       = XLColor.White;
            for (int i = 0; i < mons.Count; i++)
            {
                sheet.Cell(hr2, colIdx + i).Style.Fill.BackgroundColor = darkBlue;
                sheet.Cell(hr2, colIdx + i).Style.Font.FontColor       = XLColor.White;
            }
            colIdx += span;
        }

        // Outline summaries above their group
        sheet.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        // ── Data sections ─────────────────────────────────────────────────────

        var rowIdx = startRow + 2;

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

        sheet.SheetView.FreezeRows(hr2);
        sheet.SheetView.FreezeColumns(1);
        sheet.Columns().AdjustToContents();

        // Keep the Description column from being over-widened by the long
        // merged filter/banner lines at the top of the sheet.
        if (sheet.Column(1).Width > 60) sheet.Column(1).Width = 60;
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

    // ── Filter-formatting helpers ───────────────────────────────────────────

    private static string Blank(string? s, string fallback) =>
        string.IsNullOrWhiteSpace(s) ? fallback : s;

    private static string DateRange(DateTime? from, DateTime? to)
    {
        if (from is null && to is null) return "All";
        string f = from?.ToString("MM/dd/yyyy") ?? "(any)";
        string t = to?.ToString("MM/dd/yyyy")   ?? "(any)";
        return $"{f}  to  {t}";
    }

    private static string NumRange(int? from, int? to)
    {
        if (from is null && to is null) return "All";
        string f = from?.ToString() ?? "(any)";
        string t = to?.ToString()   ?? "(any)";
        return $"{f}  to  {t}";
    }

    private static string ListOrAll(List<string>? xs) =>
        xs is { Count: > 0 } ? string.Join(", ", xs) : "All";
}
