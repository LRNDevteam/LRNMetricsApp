using ClosedXML.Excel;


namespace LabMetricsDashboard.Services;

/// <summary>
/// Shared Excel styling constants and helper methods using the
/// Office 2013–2022 color theme — green family (Accent 6 <c>#70AD47</c>).
/// All page-specific Excel builders should reference this class
/// for consistent branding.
/// </summary>
public static class ExcelTheme
{
    // ── Office 2013–2022 theme palette (Page Layout > Colors > Office 2013 - 2022)
    //
    //   Dark 1  (Text 1)        #000000
    //   Light 1 (Background 1)  #FFFFFF
    //   Dark 2  (Text 2)        #44546A
    //   Light 2 (Background 2)  #E7E6E6
    //   Accent 1  #4472C4   Accent 2  #ED7D31   Accent 3  #A5A5A5
    //   Accent 4  #FFC000   Accent 5  #5B9BD5   Accent 6  #70AD47
    //
    // Green family derived from Accent 6 using Excel's standard tint percentages:
    //   Darker 50 %  #385723        Darker 25 %  #548235
    //   Base          #70AD47
    //   Lighter 40 % #A9D18E        Lighter 60 % #C5E0B4
    //   Lighter 80 % #E2EFDA

    /// <summary>Accent 6 Darker 50 % — used for top-level title bars.</summary>
    public static readonly XLColor TitleBg = XLColor.FromHtml("#385723");

    /// <summary>Accent 6 Darker 25 % — used for section headers and column group headers.</summary>
    public static readonly XLColor HeaderBg = XLColor.FromHtml("#548235");

    /// <summary>Accent 6 base green — used for period / sub-section headers.</summary>
    public static readonly XLColor SubHeaderBg = XLColor.FromHtml("#70AD47");

    /// <summary>Accent 4 (Gold) — used for "Total" column headers and highlights.</summary>
    public static readonly XLColor GoldAccent = XLColor.FromHtml("#FFC000");

    /// <summary>Accent 6 Lighter 60 % — used for group / category rows (bold parent rows).</summary>
    public static readonly XLColor GroupRowBg = XLColor.FromHtml("#C5E0B4");

    /// <summary>Accent 6 Lighter 80 % — used for alternating banded rows.</summary>
    public static readonly XLColor BandedRowBg = XLColor.FromHtml("#E2EFDA");

    /// <summary>Light 2 (Background 2) — used for sub-header labels.</summary>
    public static readonly XLColor SubLabelBg = XLColor.FromHtml("#E7E6E6");

    /// <summary>Accent 6 Lighter 40 % — used for total row background.</summary>
    public static readonly XLColor TotalRowBg = XLColor.FromHtml("#A9D18E");

    /// <summary>Accent 3 (Gray) — standard thin-border colour.</summary>
    public static readonly XLColor BorderColor = XLColor.FromHtml("#A5A5A5");

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

    // ── Tab colours for sheet tabs ───────────────────────────────────────
    public static readonly XLColor TabGreen = XLColor.FromHtml("#70AD47");
    public static readonly XLColor TabBlue = XLColor.FromHtml("#4472C4");
    public static readonly XLColor TabRed = XLColor.FromHtml("#C00000");
    public static readonly XLColor TabGold = XLColor.FromHtml("#ED7D31");

    // ── Font defaults ────────────────────────────────────────────────────
    public const string FontName = "Calibri";
    public const double FontSizeBody = 10;
    public const double FontSizeHeader = 10;
    public const double FontSizeTitle = 14;
    public const double FontSizeSectionTitle = 12;

    // ── Worksheet initialisation ─────────────────────────────────────────

    /// <summary>Sets the default font for the entire worksheet.</summary>
    public static void ApplyDefaults(IXLWorksheet ws)
    {
        ws.Style.Font.FontName = FontName;
        ws.Style.Font.FontSize = FontSizeBody;
    }

    // ── Cell / range styling helpers ─────────────────────────────────────

    /// <summary>Styles a merged title bar spanning <paramref name="colCount"/> columns.</summary>
    public static void WriteTitleBar(IXLWorksheet ws, int row, int colCount, string text)
    {
        var range = ws.Range(row, 1, row, colCount);
        range.Merge();
        var cell = ws.Cell(row, 1);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = FontSizeTitle;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = TitleBg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorderColor = TitleBg;
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

    /// <summary>Writes a row of column headers using the dark-green style.</summary>
    public static void WriteHeaderRow(IXLWorksheet ws, int row, int startCol,
        string[] headers, XLColor? background = null)
    {
        var bg = background ?? HeaderBg;
        for (int c = 0; c < headers.Length; c++)
        {
            var cell = ws.Cell(row, startCol + c);
            cell.Value = headers[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontSize = FontSizeHeader;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = bg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            cell.Style.Alignment.WrapText = true;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.OutsideBorderColor = XLColor.White;
        }
    }

    /// <summary>Applies standard data-cell styling to a range.</summary>
    public static void StyleDataCell(IXLCell cell, XLColor bg)
    {
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
            cell.Style.Fill.BackgroundColor = TotalRowBg;
            cell.Style.Border.TopBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.TopBorderColor = HeaderBg;
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

    /// <summary>Returns the standard banded-row background for the given index.</summary>
    public static XLColor GetRowBg(int rowIndex, bool isGroupRow = false)
    {
        if (isGroupRow) return GroupRowBg;
        return rowIndex % 2 != 0 ? BandedRowBg : XLColor.White;
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
        ws.Columns().AdjustToContents();
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
}
