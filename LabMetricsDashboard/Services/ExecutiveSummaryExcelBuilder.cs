using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Creates an Excel workbook from an Executive Summary view model.
/// Palette matches the Cove client Executive Summary: Calibri 10, dark green
/// year headers, mint month headers, white parent / gray child rows, red tab.
/// LIS / PMS / Cash / Averages sit on one "Executive Summary" sheet.
/// </summary>
public sealed class ExecutiveSummaryExcelBuilder
{
    private static readonly string[] Sections = ["LIS", "PMS", "Cash", "Avg"];
    private static readonly XLColor HeaderBg = ExcelTheme.Collection.HeaderBg;
    private static readonly XLColor MonthBg = ExcelTheme.Collection.MonthHeaderBg;
    private static readonly XLColor ChildBg = ExcelTheme.Collection.ChildRowBg;
    private static readonly XLColor MetaBg = ExcelTheme.Collection.ChildRowBg;
    private static readonly XLColor BorderColor = ExcelTheme.BorderColor;
    private static readonly XLColor CpExceptionBg = ExcelTheme.Collection.CpExceptionBg; // #FFF2CC
    private static readonly XLColor CpExceptionChildBg = ExcelTheme.Collection.MonthHeaderBg; // #E2EFDA

    public byte[] Build(PhiExecutiveSummaryViewModel vm)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Executive Summary");
        sheet.TabColor = ExcelTheme.Collection.TabRed;
        sheet.ShowGridLines = false;
        ExcelTheme.ApplyDefaults(sheet);

        var columns = vm.YearMonthColumns;
        var years = columns.Where(c => c.Year != 0).Select(c => c.Year).Distinct().OrderBy(y => y).ToList();
        var monthsByYear = columns.Where(c => c.Year != 0)
            .GroupBy(c => c.Year)
            .ToDictionary(g => g.Key, g => g.Select(c => c.Month).OrderBy(m => m).ToList());
        int totalDataCols = years.Sum(y => monthsByYear.TryGetValue(y, out var mons) ? mons.Count + 1 : 1);
        // # | Category | Description | (months + year totals) | Grand Total
        int grandCol = 4 + totalDataCols;

        bool useBilled = (vm.BilledFrom.HasValue || vm.BilledTo.HasValue)
                         && !vm.DosFrom.HasValue && !vm.DosTo.HasValue;
        string dateBasis = useBilled ? "Billed Date" : "DOS";

        int startRow = WriteInfoBlock(sheet, vm, grandCol);
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
        var darkGreen = HeaderBg; // Accent 6 Darker 50% — Cove client
        int lastCol  = Math.Max(grandCol, 2);
        int r = 1;
        int blockStart = 1;

        void Line(string text, bool bold, bool title = false, bool sectionHead = false)
        {
            var cell = sheet.Cell(r, 1);
            cell.Value = text;
            cell.Style.Font.Bold = bold;
            cell.Style.Font.FontName = ExcelTheme.FontName;
            cell.Style.Font.FontSize = ExcelTheme.FontSizeBody;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
            cell.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
            if (title)
            {
                cell.Style.Font.FontColor = darkGreen;
            }
            if (sectionHead)
            {
                cell.Style.Font.FontColor = darkGreen;
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

        if (HasAppliedFilters(vm))
        {
            r++; // blank spacer
            Line("Applied Filters", bold: true, sectionHead: true);
            Line($"Date of Service:  {DateRange(vm.DosFrom, vm.DosTo)}", bold: false);
            Line($"First Billed Date:  {DateRange(vm.BilledFrom, vm.BilledTo)}", bold: false);
            if (vm.SelectedYearFrom.HasValue || vm.SelectedYearTo.HasValue
                || vm.SelectedMonthFrom.HasValue || vm.SelectedMonthTo.HasValue)
            {
                Line($"Year Range:  {NumRange(vm.SelectedYearFrom, vm.SelectedYearTo)}", bold: false);
                Line($"Month Range:  {NumRange(vm.SelectedMonthFrom, vm.SelectedMonthTo)}", bold: false);
            }
            if (vm.SelectedPanels is { Count: > 0 })
                Line($"Panel:  {ListOrAll(vm.SelectedPanels)}", bold: false);
            if (vm.SelectedClinics is { Count: > 0 })
                Line($"Clinics:  {ListOrAll(vm.SelectedClinics)}", bold: false);
            if (vm.SelectedProviders is { Count: > 0 })
                Line($"Referring Provider:  {ListOrAll(vm.SelectedProviders)}", bold: false);
            if (vm.SelectedReps is { Count: > 0 })
                Line($"Sales Rep:  {ListOrAll(vm.SelectedReps)}", bold: false);
        }

        r++; // blank spacer before the data table

        sheet.Range(blockStart, 1, r - 1, lastCol).Style.Fill.BackgroundColor = MetaBg;
        sheet.Range(blockStart, 1, r - 1, lastCol).Style.Font.FontName = ExcelTheme.FontName;
        sheet.Range(blockStart, 1, r - 1, lastCol).Style.Font.FontSize = ExcelTheme.FontSizeBody;

        return r;
    }

    private void BuildSheet(IXLWorksheet sheet, List<ExecSummaryRow> allRows,
        List<(int Year, int Month)> columns, int startRow, string dateBasis = "DOS")
    {
        var years = columns.Where(c => c.Year != 0).Select(c => c.Year).Distinct().OrderBy(y => y).ToList();
        var monthsByYear = columns.Where(c => c.Year != 0)
            .GroupBy(c => c.Year)
            .ToDictionary(g => g.Key, g => g.Select(c => c.Month).OrderBy(m => m).ToList());

        int totalDataCols = years.Sum(y => monthsByYear[y].Count + 1);
        const int firstDataCol = 4;
        var grandCol = firstDataCol + totalDataCols;

        int hr1 = startRow;
        int hr2 = startRow + 1;

        var headerGreen = HeaderBg;
        var monthGreen  = MonthBg;

        sheet.Cell(hr1, 1).Value = "#";
        sheet.Range(hr1, 1, hr2, 1).Merge();
        sheet.Cell(hr1, 2).Value = "Category";
        sheet.Range(hr1, 2, hr2, 2).Merge();
        sheet.Cell(hr1, 3).Value = "Description";
        sheet.Range(hr1, 3, hr2, 3).Merge();

        var colIdx = firstDataCol;
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

        colIdx = firstDataCol;
        foreach (var year in years)
        {
            foreach (var m in monthsByYear[year])
            {
                sheet.Cell(hr2, colIdx).Value = MonthName(m).ToUpper();
                colIdx++;
            }
            sheet.Cell(hr2, colIdx).Value = $"{year} Total";
            colIdx++;
        }

        var headerRange = sheet.Range(hr1, 1, hr2, grandCol);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Font.FontName = ExcelTheme.FontName;
        headerRange.Style.Font.FontSize = ExcelTheme.FontSizeBody;
        headerRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerRange.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
        headerRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        headerRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        headerRange.Style.Border.OutsideBorderColor = BorderColor;
        headerRange.Style.Border.InsideBorderColor = BorderColor;

        for (int r = hr1; r <= hr2; r++)
        {
            for (int c = 1; c <= 3; c++)
            {
                sheet.Cell(r, c).Style.Fill.BackgroundColor = headerGreen;
                sheet.Cell(r, c).Style.Font.FontColor       = XLColor.White;
            }
            sheet.Cell(r, grandCol).Style.Fill.BackgroundColor = headerGreen;
            sheet.Cell(r, grandCol).Style.Font.FontColor       = XLColor.White;
        }
        colIdx = firstDataCol;
        foreach (var year in years)
        {
            var mons = monthsByYear[year];
            int span = mons.Count + 1;
            var yearHeader = sheet.Range(hr1, colIdx, hr1, colIdx + span - 1);
            yearHeader.Style.Fill.BackgroundColor = headerGreen;
            yearHeader.Style.Font.FontColor       = XLColor.White;
            for (int i = 0; i < mons.Count; i++)
            {
                sheet.Cell(hr2, colIdx + i).Style.Fill.BackgroundColor = monthGreen;
                sheet.Cell(hr2, colIdx + i).Style.Font.FontColor =
                    ExcelTheme.Collection.ContrastOn(monthGreen);
            }
            sheet.Cell(hr2, colIdx + mons.Count).Style.Fill.BackgroundColor = headerGreen;
            sheet.Cell(hr2, colIdx + mons.Count).Style.Font.FontColor = XLColor.White;
            colIdx += span;
        }

        sheet.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        var rowIdx = startRow + 2;
        var categoryMerges = new List<(int Start, int End)>();
        var cpParentCode = CpExceptionParentCode(allRows);

        foreach (var section in Sections)
        {
            var rows = FilterRowsWithValues(allRows.Where(r => r.Category == section).ToList(), cpParentCode);
            if (rows.Count == 0) continue;

            int sectionStart = rowIdx;
            int childNum = 0;
            sheet.Cell(rowIdx, 2).Value = CategoryLabel(section);
            sheet.Cell(rowIdx, 2).Style.Font.Bold = true;
            sheet.Cell(rowIdx, 2).Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            sheet.Cell(rowIdx, 2).Style.Alignment.WrapText = true;

            foreach (var row in rows)
            {
                int outlineLevel = RowOutlineLevel(row, cpParentCode);
                bool cpFamily = IsCpExceptionFamily(row, cpParentCode);

                if (outlineLevel == 0) childNum = 0;
                sheet.Cell(rowIdx, 1).Value = HashLabel(row, outlineLevel, ref childNum, cpParentCode);
                sheet.Cell(rowIdx, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
                sheet.Cell(rowIdx, 3).Value = row.Description.TrimStart();
                colIdx = firstDataCol;

                foreach (var year in years)
                {
                    foreach (var m in monthsByYear[year])
                    {
                        row.ValuesByYearMonth.TryGetValue((year, m), out var val);
                        var cell = sheet.Cell(rowIdx, colIdx);
                        cell.Value = (double)val;
                        SetNumberFormat(cell, row.Category);
                        colIdx++;
                    }
                    decimal ytVal;
                    if (row.Category == "Avg" && row.ValuesByYearMonth.TryGetValue((year, 0), out var ytSentinel))
                        ytVal = ytSentinel;
                    else
                        ytVal = row.ValuesByYearMonth
                            .Where(kv => kv.Key.Year == year && kv.Key.Month != 0)
                            .Sum(kv => kv.Value);
                    var ytCell = sheet.Cell(rowIdx, colIdx);
                    ytCell.Value = (double)ytVal;
                    SetNumberFormat(ytCell, row.Category);
                    ytCell.Style.Font.Bold = true;
                    colIdx++;
                }

                bool hasMonthlyBuckets = row.ValuesByYearMonth.Keys.Any(k => k.Year != 0 && k.Month != 0);
                decimal grandVal;
                if (row.Category == "Avg" || !hasMonthlyBuckets)
                    row.ValuesByYearMonth.TryGetValue((0, 0), out grandVal);
                else
                    grandVal = row.ValuesByYearMonth
                        .Where(kv => kv.Key.Year != 0 && kv.Key.Month != 0)
                        .Sum(kv => kv.Value);
                var grandCell = sheet.Cell(rowIdx, grandCol);
                grandCell.Value = (double)grandVal;
                SetNumberFormat(grandCell, row.Category);
                grandCell.Style.Font.Bold = true;

                XLColor rowFill;
                bool cpChild = IsCpExceptionChild(row, cpParentCode);
                if (cpChild) rowFill = CpExceptionChildBg;
                else if (cpFamily) rowFill = CpExceptionBg;
                else if (outlineLevel > 0) rowFill = ChildBg;
                else rowFill = XLColor.White;

                var rowRange = sheet.Range(rowIdx, 1, rowIdx, 1);
                rowRange.Style.Fill.BackgroundColor = rowFill;
                rowRange.Style.Font.FontColor = ExcelTheme.Collection.ContrastOn(rowFill);
                var descRange = sheet.Range(rowIdx, 3, rowIdx, grandCol);
                descRange.Style.Fill.BackgroundColor = rowFill;
                descRange.Style.Font.FontColor = ExcelTheme.Collection.ContrastOn(rowFill);
                descRange.Style.Font.FontName = ExcelTheme.FontName;
                descRange.Style.Font.FontSize = ExcelTheme.FontSizeBody;
                if (cpChild) descRange.Style.Font.Italic = true;
                sheet.Cell(rowIdx, 1).Style.Font.FontName = ExcelTheme.FontName;
                sheet.Cell(rowIdx, 1).Style.Font.FontSize = ExcelTheme.FontSizeBody;

                if (outlineLevel > 0)
                {
                    sheet.Row(rowIdx).OutlineLevel = Math.Min(outlineLevel, 7);
                    sheet.Cell(rowIdx, 3).Style.Alignment.Indent = outlineLevel * 2;
                }
                else
                {
                    sheet.Cell(rowIdx, 1).Style.Font.Bold = true;
                    sheet.Cell(rowIdx, 3).Style.Font.Bold = true;
                }

                rowIdx++;
            }

            if (rowIdx - 1 >= sectionStart)
                categoryMerges.Add((sectionStart, rowIdx - 1));
        }

        foreach (var (start, end) in categoryMerges)
        {
            if (end > start)
                sheet.Range(start, 2, end, 2).Merge();
            var catRange = sheet.Range(start, 2, end, 2);
            catRange.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            catRange.Style.Alignment.WrapText = true;
            catRange.Style.Fill.BackgroundColor = XLColor.White;
            catRange.Style.Font.Bold = true;
            catRange.Style.Font.FontName = ExcelTheme.FontName;
            catRange.Style.Font.FontSize = ExcelTheme.FontSizeBody;
        }

        int lastDataRow = Math.Max(hr2, rowIdx - 1);
        var tableRange = sheet.Range(hr1, 1, lastDataRow, grandCol);
        tableRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        tableRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        tableRange.Style.Border.OutsideBorderColor = BorderColor;
        tableRange.Style.Border.InsideBorderColor = BorderColor;

        sheet.Column(1).Width = 8;
        sheet.Column(2).Width = 22;
        sheet.Column(3).Width = 42;
        for (int c = firstDataCol; c <= grandCol; c++)
            sheet.Column(c).Width = 14;
        sheet.Row(hr1).Height = 22;
        sheet.Row(hr2).Height = 20;
    }

    private void SetNumberFormat(IXLCell cell, string category)
    {
        cell.Style.NumberFormat.Format = IsDollar(category)
            ? ExcelTheme.Collection.AccountingNumberFormat
            : ExcelTheme.Collection.CountNumberFormat;
    }

    private static bool IsDollar(string cat) => cat is "Cash" or "Avg";

    private static string MonthName(int m) =>
        System.Globalization.CultureInfo.InvariantCulture.DateTimeFormat.GetAbbreviatedMonthName(m);

    private static string CategoryLabel(string cat) => cat switch
    {
        "LIS"  => "LIS Breakdown",
        "PMS"  => "Billable Samples - PMS Breakdown",
        "Cash" => "Cash Breakdown",
        "Avg"  => "Average Payment Per Claim",
        _      => cat
    };

    private static string HashLabel(ExecSummaryRow row, int outlineLevel, ref int childNum, string? cpParentCode)
    {
        if (outlineLevel >= 2 || IsCpExceptionChild(row, cpParentCode))
            return "•";
        var code = row.RowCode ?? "";
        if (outlineLevel == 0 && code.Length > 0 && !code.Contains('.'))
            return code;
        childNum++;
        return childNum.ToString();
    }

    private static string? CpExceptionParentCode(IEnumerable<ExecSummaryRow> rows)
        => rows.FirstOrDefault(r =>
                (r.Description ?? "").Trim().Equals("CP Exception", StringComparison.OrdinalIgnoreCase))
            ?.RowCode;

    /// <summary>
    /// CP Exception parent and its PanelType children (Billable + Not Billed +
    /// SubStatus = CP Exception, grouped by PanelType). Live Cove uses D.8;
    /// some labs/scripts use D.6 — match by description then RoleID prefix.
    /// </summary>
    private static bool IsCpExceptionFamily(ExecSummaryRow row, string? cpParentCode)
    {
        var desc = (row.Description ?? "").Trim();
        if (desc.Equals("CP Exception", StringComparison.OrdinalIgnoreCase))
            return true;
        return IsCpExceptionChild(row, cpParentCode);
    }

    private static bool IsCpExceptionChild(ExecSummaryRow row, string? cpParentCode)
    {
        if (string.IsNullOrEmpty(cpParentCode)) return false;
        var code = row.RowCode ?? "";
        return code.StartsWith(cpParentCode + ".", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Indent from leading spaces, with RowCode as fallback so nested panel
    /// rows under CP Exception stay children even when the description was
    /// stored without padding.
    /// </summary>
    private static int RowOutlineLevel(ExecSummaryRow row, string? cpParentCode = null)
    {
        if (row.IsSubSubRow) return 2;
        if (IsCpExceptionChild(row, cpParentCode)) return 2;
        if (row.IsSubRow) return 1;

        var code = row.RowCode ?? "";
        var dots = 0;
        foreach (var ch in code)
            if (ch == '.') dots++;
        if (dots >= 2) return 2;
        if (dots == 1) return 1;
        return 0;
    }

    private static bool HasActualValues(ExecSummaryRow row)
        => row.ValuesByYearMonth.Values.Any(v => v != 0m);

    /// <summary>
    /// Drop zero-only breakdown rows. CP Exception PanelType children are
    /// kept only when they have values (DISTINCT PanelType from LIMSMaster
    /// where SubStatus = CP Exception).
    /// </summary>
    private static List<ExecSummaryRow> FilterRowsWithValues(List<ExecSummaryRow> rows, string? cpParentCode)
    {
        if (rows.Count == 0) return rows;

        var keep = new bool[rows.Count];
        var levels = new int[rows.Count];
        for (int i = 0; i < rows.Count; i++)
            levels[i] = RowOutlineLevel(rows[i], cpParentCode);

        for (int i = 0; i < rows.Count; i++)
        {
            if (IsCpExceptionChild(rows[i], cpParentCode))
            {
                if (HasActualValues(rows[i]))
                    keep[i] = true;
                else
                    continue;
            }
            else if (HasActualValues(rows[i])
                     || (IsCpExceptionFamily(rows[i], cpParentCode) && !IsCpExceptionChild(rows[i], cpParentCode)))
            {
                keep[i] = true;
            }
            else
                continue;

            var indent = levels[i];
            for (int j = i - 1; j >= 0 && indent > 0; j--)
            {
                if (levels[j] < indent)
                {
                    keep[j] = true;
                    indent = levels[j];
                }
            }
        }

        var filtered = new List<ExecSummaryRow>(rows.Count);
        for (int i = 0; i < rows.Count; i++)
        {
            if (keep[i]) filtered.Add(rows[i]);
        }
        return filtered;
    }

    // ── Filter-formatting helpers ───────────────────────────────────────────

    private static bool HasAppliedFilters(PhiExecutiveSummaryViewModel vm)
        => vm.DosFrom.HasValue || vm.DosTo.HasValue
        || vm.BilledFrom.HasValue || vm.BilledTo.HasValue
        || vm.SelectedYearFrom.HasValue || vm.SelectedYearTo.HasValue
        || vm.SelectedMonthFrom.HasValue || vm.SelectedMonthTo.HasValue
        || vm.SelectedPanels is { Count: > 0 }
        || vm.SelectedClinics is { Count: > 0 }
        || vm.SelectedProviders is { Count: > 0 }
        || vm.SelectedReps is { Count: > 0 };

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
