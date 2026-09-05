using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using System.Data;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Creates an Excel workbook from an Executive Summary view model.
/// A metadata block (analysis / week range + applied filters) is written at
/// the top, followed by all categories (LIS, PMS, Cash, Avg) on a single
/// sheet, each preceded by a coloured section-heading row.
/// Uses the Office 2013–2022 green (Accent 6) palette with gold (Accent 4)
/// year/grand-total highlights — same theme and Calibri fonts as the
/// Prediction summary export (ExcelTheme green family).
/// </summary>
public sealed class ExecutiveSummaryExcelBuilder
{
    private static readonly string[] Sections = ["LIS", "PMS", "Cash", "Avg"];

    public byte[] Build(PhiExecutiveSummaryViewModel vm)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Executive Summary");
        sheet.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(sheet);

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

        // Header date basis: matches the SP's @UseBilledDate rule — FirstBilledDate
        // when a Billed range is set and no DOS range is set; otherwise DOS.
        bool useBilled = (vm.BilledFrom.HasValue || vm.BilledTo.HasValue)
                         && !vm.DosFrom.HasValue && !vm.DosTo.HasValue;
        string dateBasis = useBilled ? "Billed Date" : "DOS";

        BuildSheet(sheet, vm.Rows, vm.YearMonthColumns, startRow, dateBasis);

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
        var darkGreen = ExcelTheme.TitleBg; // Accent 6 Darker 50% — matches Prediction summary
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
                cell.Style.Font.FontSize  = ExcelTheme.FontSizeTitle;
                cell.Style.Font.FontColor = darkGreen;
            }
            if (sectionHead)
            {
                cell.Style.Font.FontColor = darkGreen;
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
        if (vm.ReportInsertedDateTime.HasValue)
            Line($"Inserted Date:  {vm.ReportInsertedDateTime.Value:MMM d, yyyy h:mm tt}", bold: false);
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
        List<(int Year, int Month)> columns, int startRow, string dateBasis = "DOS")
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

        // Green (Accent 6) theme with gold (Accent 4) totals — same palette as the
        // Prediction summary / Production Report exports (ExcelTheme green family).
        var headerGreen = ExcelTheme.HeaderBg;      // #548235 — header rows
        var monthGreen  = ExcelTheme.SubHeaderBg;   // #70AD47 — month header cells
        var gold        = ExcelTheme.GoldAccent;    // #FFC000 — year/grand total headers (black text)
        var yearTint    = XLColor.FromHtml("#FFF2CC");  // Accent 4 Lighter 80% — year total data cells
        var grandTint   = XLColor.FromHtml("#FFE699");  // Accent 4 Lighter 60% — grand total data cells
        var catGreen    = ExcelTheme.BandedRowBg;   // #E2EFDA — parent/category rows

        // Section heading rows — dark green across every section (single-theme workbook).
        var sectionHeadingBg = ExcelTheme.TitleBg;  // #385723

        // ── Header rows (written once at the top of the table) ───────────────

        sheet.Cell(hr1, 1).Value = "Description";
        sheet.Range(hr1, 1, hr2, 1).Merge();

        var colIdx = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1;
            sheet.Cell(hr1, colIdx).Value = $"Data Based on {dateBasis} — {year}";
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
            yt.Style.Font.FontColor = XLColor.Black;
            colIdx++;
        }

        // Style the two header rows
        var headerRange = sheet.Range(hr1, 1, hr2, grandCol);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerRange.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;

        for (int r = hr1; r <= hr2; r++)
        {
            sheet.Cell(r, 1).Style.Fill.BackgroundColor = headerGreen;
            sheet.Cell(r, 1).Style.Font.FontColor       = XLColor.White;
            sheet.Cell(r, grandCol).Style.Fill.BackgroundColor = gold;
            sheet.Cell(r, grandCol).Style.Font.FontColor       = XLColor.Black;
        }
        colIdx = 2;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1;
            sheet.Cell(hr1, colIdx).Style.Fill.BackgroundColor = headerGreen;
            sheet.Cell(hr1, colIdx).Style.Font.FontColor       = XLColor.White;
            for (int i = 0; i < mons.Count; i++)
            {
                sheet.Cell(hr2, colIdx + i).Style.Fill.BackgroundColor = monthGreen;
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
            var headingCell  = sheet.Cell(rowIdx, 1);
            headingCell.Value = SectionLabel(section);
            headingCell.Style.Fill.BackgroundColor = sectionHeadingBg;
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
                    // Year total. "Avg" rows are weighted averages, not additive —
                    // prefer the SP's per-year (year, 0) sentinel when present;
                    // otherwise fall back to summing the monthly values.
                    decimal ytVal;
                    if (row.Category == "Avg" && row.ValuesByYearMonth.TryGetValue((year, 0), out var ytSentinel))
                        ytVal = ytSentinel;
                    else
                        ytVal = row.ValuesByYearMonth
                            .Where(kv => kv.Key.Year == year && kv.Key.Month != 0)
                            .Sum(kv => kv.Value);
                    var ytCell = sheet.Cell(rowIdx, colIdx);
                    if (ytVal != 0) ytCell.Value = (double)ytVal;
                    SetNumberFormat(ytCell, row.Category);
                    ytCell.Style.Fill.BackgroundColor = yearTint;
                    ytCell.Style.Font.Bold = true;
                    colIdx++;
                }

                // Grand total.
                // Mirror the web view's RowGrandTotal: "Avg" rows are averages,
                // NOT additive — summing the monthly averages produced inflated
                // totals (e.g. ~$600) that disagreed with the web. Use the SP's
                // precomputed (0,0) weighted-average sentinel instead. Rows that
                // carry only a (0,0) filtered total (no monthly buckets) also use
                // the sentinel.
                bool hasMonthlyBuckets = row.ValuesByYearMonth.Keys.Any(k => k.Year != 0 && k.Month != 0);
                decimal grandVal;
                if (row.Category == "Avg" || !hasMonthlyBuckets)
                    row.ValuesByYearMonth.TryGetValue((0, 0), out grandVal);
                else
                    grandVal = row.ValuesByYearMonth
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

        sheet.Columns().AdjustToContents();

        // Keep the Description column from being over-widened by the long
        // merged filter/banner lines at the top of the sheet.
        if (sheet.Column(1).Width > 60) sheet.Column(1).Width = 60;
    }

    private void SetNumberFormat(IXLCell cell, string category)
    {
        cell.Style.NumberFormat.Format = IsDollar(category) ? ExcelTheme.AccountingNumberFormat : "#,##0";
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
