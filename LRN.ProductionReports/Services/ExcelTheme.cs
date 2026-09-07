using ClosedXML.Excel;


namespace LRN.ProductionReports.Services;

/// <summary>
/// Shared Excel styling for Production Report workbooks.
/// Palette matches the Cove Insights Production Report:
/// dark green titles/year headers, mild mint-green month headers,
/// light-gray metric headers, Calibri.
/// </summary>
public static class ExcelTheme
{
    /// <summary>Dark forest green — title bars, period headers, and total rows.</summary>
    public static readonly XLColor TitleBg = XLColor.FromHtml("#385624");

    /// <summary>Same forest green — year / column-group headers.</summary>
    public static readonly XLColor HeaderBg = XLColor.FromHtml("#385624");

    /// <summary>
    /// Insights title / year headers — Office Accent 6 Darker 50% (#70AD47 @ tint -0.5).
    /// </summary>
    public static readonly XLColor InsightsHeaderBg = XLColor.FromHtml("#385624");

    /// <summary>
    /// Insights month / week headers — Office Accent 6 Lighter 80% (mild mint green, black text).
    /// </summary>
    public static readonly XLColor MonthHeaderBg = XLColor.FromHtml("#E2EFDA");

    /// <summary>
    /// Insights metric sub-headers — theme Light 2 Darker 10% (No. of Claims / Total Billed).
    /// </summary>
    public static readonly XLColor InsightsMetricHeaderBg = XLColor.FromHtml("#D0CFCF");

    /// <summary>Light gray — period headers on sheets not yet switched to Insights mild green.</summary>
    public static readonly XLColor SubHeaderBg = XLColor.FromHtml("#D9D9D9");

    /// <summary>Light gray — metric sub-headers (No. of Claims, Total Billed) with black text.</summary>
    public static readonly XLColor MetricHeaderBg = XLColor.FromHtml("#E7E7E7");

    /// <summary>Kept for call-site compatibility; Production totals use the same forest green as headers (not gold).</summary>
    public static readonly XLColor GoldAccent = XLColor.FromHtml("#385624");

    /// <summary>
    /// Insights claim-count format: thousands separator, minus for negatives, dash for zero.
    /// </summary>
    public const string CountNumberFormat = @"#,##0;-#,##0;""-"";@";

    /// <summary>
    /// Excel Accounting (USD, 0 decimals) matching Insights: $ aligned left, value right,
    /// negatives in parentheses, zero as a dash. Not Currency (<c>$#,##0</c>).
    /// </summary>
    public const string AccountingNumberFormat = @"_(""$""* #,##0_);_(""$""* \(#,##0\);_(""$""* ""-""_);_(@_)";

    /// <summary>Excel Accounting (USD, 2 decimals).</summary>
    public const string AccountingNumberFormat2 = @"_($* #,##0.00_);_($* (#,##0.00);_($* ""-""??_);_(@_)";

    /// <summary>Parent / group rows (e.g. A UTI) — Insights uses no fill (white), bold black text.</summary>
    public static readonly XLColor GroupRowBg = XLColor.White;

    /// <summary>Child / subcategory rows (e.g. Medicare FL) — Office Light 2 #E7E6E6, no zebra.</summary>
    public static readonly XLColor ChildRowBg = XLColor.FromHtml("#E7E6E6");

    /// <summary>Same as child rows — kept so older call sites do not zebra-stripe payers.</summary>
    public static readonly XLColor BandedRowBg = XLColor.FromHtml("#E7E6E6");

    /// <summary>Light gray — metric / sub-header labels (black text).</summary>
    public static readonly XLColor SubLabelBg = XLColor.FromHtml("#D9D9D9");

    /// <summary>Top Client Name…Source block — Office Light 2.</summary>
    public static readonly XLColor MetaHeaderBg = XLColor.FromHtml("#E7E6E6");

    /// <summary>Total row — same forest green as title bars.</summary>
    public static readonly XLColor TotalRowBg = XLColor.FromHtml("#385624");

    /// <summary>Thin gridline colour.</summary>
    public static readonly XLColor BorderColor = XLColor.FromHtml("#CCCCCC");

    /// <summary>Dark red — Insights / Active Priorities section headers.</summary>
    public static readonly XLColor ActionHeaderBg = XLColor.FromHtml("#C00000");

    // ── Blue family (Accent 1 #4472C4) — Production Report headers ─────
    //   Darker 50 %  #203864        Darker 25 %  #2F5597
    //   Base          #4472C4
    //   Lighter 40 % #8FAADC        Lighter 60 % #B4C7E7
    //   Lighter 80 % #D6DCE4

    /// <summary>Accent 1 Darker 50 % — dark navy title bar for blue-themed sheets.</summary>
    public static readonly XLColor BlueTitleBg = XLColor.FromHtml("#203864");

    /// <summary>Accent 1 Darker 25 % — column-group / year header rows.</summary>
    public static readonly XLColor BlueHeaderBg = XLColor.FromHtml("#2F5597");

    /// <summary>Accent 1 base — period / sub-section headers.</summary>
    public static readonly XLColor BlueSubHeaderBg = XLColor.FromHtml("#4472C4");

    /// <summary>Accent 1 Lighter 60 % — group / category rows (bold parent rows).</summary>
    public static readonly XLColor BlueGroupRowBg = XLColor.FromHtml("#B4C7E7");

    /// <summary>Accent 1 Lighter 80 % — alternating banded rows.</summary>
    public static readonly XLColor BlueBandedRowBg = XLColor.FromHtml("#D6DCE4");

    /// <summary>Accent 1 Lighter 40 % — total row background.</summary>
    public static readonly XLColor BlueTotalRowBg = XLColor.FromHtml("#8FAADC");

    // ── Amber family (Accent 2 #ED7D31) — year / grand total highlights ─
    //   Darker 50 %  #843C0C        Darker 25 %  #C55A11
    //   Base          #ED7D31
    //   Lighter 40 % #F4B183        Lighter 60 % #F8CBAD
    //   Lighter 80 % #FCE4D6

    /// <summary>Accent 2 Darker 25 % — year-total header columns.</summary>
    public static readonly XLColor AmberHeaderBg = XLColor.FromHtml("#C55A11");

    /// <summary>Accent 2 Darker 50 % — grand-total header columns.</summary>
    public static readonly XLColor AmberDarkBg = XLColor.FromHtml("#843C0C");

    // ── Conditional formatting (Office 2013+ semantic colours) ───────────
    public static readonly XLColor GoodBg = XLColor.FromHtml("#C6EFCE");
    public static readonly XLColor GoodFg = XLColor.FromHtml("#006100");
    public static readonly XLColor NeutralBg = XLColor.FromHtml("#FFEB9C");
    public static readonly XLColor NeutralFg = XLColor.FromHtml("#9C5700");
    public static readonly XLColor BadBg = XLColor.FromHtml("#FFC7CE");
    public static readonly XLColor BadFg = XLColor.FromHtml("#9C0006");

    // ── Tab colours (Cove source workbook) ────────────────────────────────
    /// <summary>Insights / MonthlyAndWeeklyVolume — source Insights tab.</summary>
    public static readonly XLColor TabRed = XLColor.FromHtml("#C00000");

    /// <summary>CPT / Payer / Payor x Panel / Panel Breakdown — source gold.</summary>
    public static readonly XLColor TabYellow = XLColor.FromHtml("#FFC000");

    /// <summary>Master / Line Level equivalent sheets — Office Accent 2.</summary>
    public static readonly XLColor TabGold = XLColor.FromHtml("#ED7D31");

    public static readonly XLColor TabGreen = XLColor.FromHtml("#385624");
    public static readonly XLColor TabBlue = XLColor.FromHtml("#4472C4");

    // ── Font defaults ────────────────────────────────────────────────────
    public const string FontName = "Calibri";
    public const double FontSizeBody = 10;
    public const double FontSizeHeader = 10;
    public const double FontSizeTitle = 10;
    public const double FontSizeSectionTitle = 11;

    // ── Worksheet initialisation ─────────────────────────────────────────

    /// <summary>
    /// White text on dark fills; black text on light gray metric headers.
    /// </summary>
    public static XLColor ContrastOn(XLColor background)
    {
        if (background.Equals(MetricHeaderBg) || background.Equals(SubLabelBg)
            || background.Equals(BandedRowBg) || background.Equals(ChildRowBg)
            || background.Equals(GroupRowBg) || background.Equals(MetaHeaderBg)
            || background.Equals(SubHeaderBg) || background.Equals(MonthHeaderBg)
            || background.Equals(InsightsMetricHeaderBg)
            || background.Equals(XLColor.White))
            return XLColor.Black;

        try
        {
            var c = background.Color;
            var luminance = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
            return luminance > 160 ? XLColor.Black : XLColor.White;
        }
        catch
        {
            return XLColor.White;
        }
    }

    /// <summary>Sets the default font for the entire worksheet.</summary>
    public static void ApplyDefaults(IXLWorksheet ws)
    {
        ws.Style.Font.FontName = FontName;
        ws.Style.Font.FontSize = FontSizeBody;
    }

    public const string ConfidentialityNotice =
        "The information in this report is confidential and intended solely for the use of the intended recipient. If you are not the intended recipient, please inform the sender immediately and delete this report.";

    /// <summary>
    /// Writes the Client Name…Source block with a solid light-gray fill across
    /// every column, including the blank row after the last field.
    /// Returns the first row after the block (title bar).
    /// </summary>
    public static int WriteReportMetaHeader(
        IXLWorksheet ws, int colCount,
        IReadOnlyList<(string Label, string? Value)> items)
    {
        int rows = Math.Max(items.Count, 1);
        int span = Math.Max(colCount, 2);
        // Include the blank row after Source so it is not left white.
        var fill = ws.Range(1, 1, rows + 1, span);
        fill.Style.Fill.BackgroundColor = MetaHeaderBg;
        fill.Style.Font.FontName = FontName;
        fill.Style.Font.FontSize = FontSizeBody;
        fill.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

        int row = 1;
        foreach (var (label, value) in items)
        {
            var labelCell = ws.Cell(row, 1);
            labelCell.Value = label.EndsWith(":", StringComparison.Ordinal) ? label : label + ":";
            labelCell.Style.Font.Bold = true;
            labelCell.Style.Font.FontColor = XLColor.Black;
            labelCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;

            var valueCell = ws.Cell(row, 2);
            valueCell.Value = value ?? "";
            valueCell.Style.Font.Bold = true;
            valueCell.Style.Font.FontColor = XLColor.Black;
            row++;
        }

        if (span >= 5)
        {
            int discCol = Math.Max(4, span - 2);
            var disc = ws.Range(1, discCol, rows, span);
            disc.Merge();
            var dcell = ws.Cell(1, discCol);
            dcell.Value = ConfidentialityNotice;
            dcell.Style.Font.FontSize = 7;
            dcell.Style.Font.Italic = true;
            dcell.Style.Font.FontColor = XLColor.FromHtml("#595959");
            dcell.Style.Alignment.WrapText = true;
            dcell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
            dcell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            dcell.Style.Fill.BackgroundColor = MetaHeaderBg;
        }

        for (int r = 1; r <= rows + 1; r++)
            ws.Row(r).Height = 16;

        return rows + 2;
    }

    // ── Cell / range styling helpers ─────────────────────────────────────

    /// <summary>Styles a merged title bar spanning <paramref name="colCount"/> columns.</summary>
    public static void WriteTitleBar(IXLWorksheet ws, int row, int colCount, string text,
        XLColor? background = null)
    {
        var bg = background ?? TitleBg;
        var range = ws.Range(row, 1, row, colCount);
        range.Merge();
        var cell = ws.Cell(row, 1);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = FontSizeTitle;
        cell.Style.Font.FontColor = ContrastOn(bg);
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorderColor = BorderColor;
        ws.Row(row).Height = 20;
    }

    /// <summary>Styles a blue-themed merged title bar spanning <paramref name="colCount"/> columns.</summary>
    public static void WriteBlueTitleBar(IXLWorksheet ws, int row, int colCount, string text)
    {
        var range = ws.Range(row, 1, row, colCount);
        range.Merge();
        var cell = ws.Cell(row, 1);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = FontSizeTitle;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = BlueTitleBg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorderColor = BlueTitleBg;
    }

    /// <summary>Styles a section title bar (e.g. "Top Collected — Clinics").</summary>
    public static void WriteSectionTitle(IXLWorksheet ws, int row, int startCol, int endCol,
        string text, XLColor? background = null)
    {
        var range = ws.Range(row, startCol, row, endCol);
        range.Merge();
        var cell = ws.Cell(row, startCol);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = FontSizeSectionTitle;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = background ?? HeaderBg;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorderColor = background ?? HeaderBg;
    }

    /// <summary>Writes a row of column headers. Light fills use black text; dark fills use white.</summary>
    public static void WriteHeaderRow(IXLWorksheet ws, int row, int startCol,
        string[] headers, XLColor? background = null)
    {
        var bg = background ?? HeaderBg;
        var fg = ContrastOn(bg);
        for (int c = 0; c < headers.Length; c++)
        {
            var cell = ws.Cell(row, startCol + c);
            cell.Value = headers[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontSize = FontSizeHeader;
            cell.Style.Font.FontColor = fg;
            cell.Style.Fill.BackgroundColor = bg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            cell.Style.Alignment.WrapText = true;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.OutsideBorderColor = BorderColor;
        }
    }

    /// <summary>Applies standard data-cell styling to a range.</summary>
    public static void StyleDataCell(IXLCell cell, XLColor bg)
    {
        cell.Style.Font.FontName = FontName;
        cell.Style.Font.FontSize = FontSizeBody;
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        cell.Style.Border.OutsideBorderColor = BorderColor;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
    }

    /// <summary>Applies total-row styling to a range of cells.</summary>
    public static void StyleTotalRow(IXLWorksheet ws, int row, int startCol, int endCol)
    {
        for (int c = startCol; c <= endCol; c++)
        {
            var cell = ws.Cell(row, c);
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = TotalRowBg;
            cell.Style.Border.TopBorder = XLBorderStyleValues.Medium;
            cell.Style.Border.TopBorderColor = TitleBg;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.OutsideBorderColor = BorderColor;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        }
    }

    /// <summary>Applies dark-green total-row styling (dark forest green background, white bold text).</summary>
    public static void StyleGreenTotalRow(IXLWorksheet ws, int row, int startCol, int endCol)
    {
        for (int c = startCol; c <= endCol; c++)
        {
            var cell = ws.Cell(row, c);
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontName = FontName;
            cell.Style.Font.FontSize = FontSizeBody;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = TitleBg;
            cell.Style.Border.TopBorder = XLBorderStyleValues.Medium;
            cell.Style.Border.TopBorderColor = TitleBg;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.OutsideBorderColor = BorderColor;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        }
    }

    /// <summary>Applies blue-themed total-row styling (dark navy background, white text).</summary>
    public static void StyleBlueTotalRow(IXLWorksheet ws, int row, int startCol, int endCol)
    {
        for (int c = startCol; c <= endCol; c++)
        {
            var cell = ws.Cell(row, c);
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = BlueTitleBg;
            cell.Style.Border.TopBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.TopBorderColor = BlueTitleBg;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.OutsideBorderColor = BorderColor;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        }
    }

    /// <summary>Returns group gray for parent rows; uniform child gray for all other data rows (no zebra).</summary>
    public static XLColor GetRowBg(int rowIndex, bool isGroupRow = false)
    {
        if (isGroupRow) return GroupRowBg;
        return ChildRowBg;
    }

    /// <summary>Returns the blue-themed banded-row background for the given index.</summary>
    public static XLColor GetBlueRowBg(int rowIndex, bool isGroupRow = false)
    {
        if (isGroupRow) return BlueGroupRowBg;
        return rowIndex % 2 != 0 ? BlueBandedRowBg : XLColor.White;
    }

    /// <summary>Auto-fits columns and enforces minimum widths.</summary>
    public static void AutoFitColumns(IXLWorksheet ws, int colCount, double minWidth = 14,
        double firstColMinWidth = 30)
    {
        // Adjust by column index only. Columns().AdjustToContents() enumerates the
        // live column collection while ClosedXML mutates it (registers column defs),
        // which throws "Collection was modified; enumeration operation may not execute."
        for (int c = 1; c <= colCount; c++)
            ws.Column(c).AdjustToContents();

        ws.Column(1).Width = Math.Max(ws.Column(1).Width, firstColMinWidth);
        for (int c = 2; c <= colCount; c++)
            ws.Column(c).Width = Math.Max(ws.Column(c).Width, minWidth);
    }

    // ── Filter summary footer ────────────────────────────────────────────

    /// <summary>
    /// Writes a "Filtered By" summary section at the bottom of the given worksheet.
    /// Only active (non-empty) filters are included. Skipped entirely when no filters are active.
    /// </summary>
    /// <param name="ws">Target worksheet.</param>
    /// <param name="startRow">First row to write the filter summary (should be below all data).</param>
    /// <param name="colCount">Number of columns to span for the header bar.</param>
    /// <param name="filters">Filter label/value pairs; null or empty values are skipped.</param>
    /// <returns>The next available row after the filter summary.</returns>
    public static int WriteFilterSummary(IXLWorksheet ws, int startRow, int colCount,
        IReadOnlyList<(string Label, string? Value)> filters)
    {
        var active = filters.Where(f => !string.IsNullOrWhiteSpace(f.Value)).ToList();
        if (active.Count == 0)
            return startRow;

        int row = startRow + 1; // leave a blank row gap

        // Section header
        WriteSectionTitle(ws, row, 1, Math.Max(colCount, 2), "Filtered By");
        row++;

        foreach (var (label, value) in active)
        {
            var labelCell = ws.Cell(row, 1);
            labelCell.Value = label;
            labelCell.Style.Font.Bold = true;
            labelCell.Style.Font.FontColor = TitleBg;
            labelCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

            var valueCell = ws.Cell(row, 2);
            valueCell.Value = value;
            valueCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

            row++;
        }

        return row;
    }

    /// <summary>
    /// Overload that accepts multi-value filters (e.g. multi-select dropdowns)
    /// by joining them with ", ".
    /// </summary>
    public static int WriteFilterSummary(IXLWorksheet ws, int startRow, int colCount,
        IReadOnlyList<(string Label, IReadOnlyList<string>? Values)> filters)
    {
        var flat = filters
            .Select(f => (f.Label, Value: f.Values is { Count: > 0 } ? string.Join(", ", f.Values) : (string?)null))
            .ToList();
        return WriteFilterSummary(ws, startRow, colCount, flat);
    }

    /// <summary>Marks subcategory rows so Excel shows a +/- outline control on the parent.</summary>
    public static void GroupChildRows(IXLWorksheet ws, int firstChildRow, int lastChildRow, int level = 1)
    {
        if (lastChildRow < firstChildRow) return;
        for (int r = firstChildRow; r <= lastChildRow; r++)
            ws.Row(r).OutlineLevel = level;
    }

    /// <summary>Puts the +/- control on the parent row and collapses child groups by default.</summary>
    public static void FinishOutline(IXLWorksheet ws)
    {
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;
        ws.CollapseRows();
    }
}
