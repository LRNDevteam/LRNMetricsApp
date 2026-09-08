using ClosedXML.Excel;

namespace DenialDatabaseProcessorWorker.Services;

/// <summary>
/// The Production Report workbook palette, so every LRN download looks like one product.
///
/// These are the Office 2013-2022 theme's Accent 6 green family at Excel's standard tint steps —
/// the same values as <c>LabMetricsDashboard/Services/ExcelTheme.cs</c>, which is the canonical
/// copy and the one to change if the house style ever moves. This worker is a standalone project
/// with no reference to the web app (and its own solution), so the constants are mirrored here
/// rather than shared; there is nothing to share them through without dragging an ASP.NET
/// application into a background worker's build graph.
///
/// Before this, each denial sheet had picked its own greens and greys by hand — #34495E,
/// #1E3D2F, #6B8E23, #1F5E16, #245B14, #E8F5E9, #DDE8D2, #E7ECE3, #E1E9D9 — none of which were
/// theme colours and none of which matched each other, let alone the Production Report.
/// </summary>
internal static class DenialExcelTheme
{
    /// <summary>Accent 6 Darker 50% — top-level title bars.</summary>
    public static readonly XLColor TitleBg = XLColor.FromHtml("#385723");

    /// <summary>Accent 6 Darker 25% — column headers and section headers.</summary>
    public static readonly XLColor HeaderBg = XLColor.FromHtml("#548235");

    /// <summary>Accent 6 base — period / sub-section headers.</summary>
    public static readonly XLColor SubHeaderBg = XLColor.FromHtml("#70AD47");

    /// <summary>Accent 6 Lighter 60% — group / parent rows.</summary>
    public static readonly XLColor GroupRowBg = XLColor.FromHtml("#C5E0B4");

    /// <summary>Accent 6 Lighter 80% — alternating banded rows.</summary>
    public static readonly XLColor BandedRowBg = XLColor.FromHtml("#E2EFDA");

    /// <summary>Accent 6 Lighter 40% — total rows.</summary>
    public static readonly XLColor TotalRowBg = XLColor.FromHtml("#A9D18E");

    /// <summary>Light 2 (Background 2) — metric sub-labels.</summary>
    public static readonly XLColor SubLabelBg = XLColor.FromHtml("#E7E6E6");

    /// <summary>Accent 3 (Gray) — standard thin-border colour.</summary>
    public static readonly XLColor BorderColor = XLColor.FromHtml("#A5A5A5");

    /// <summary>Accent 6 base — sheet tab colour.</summary>
    public static readonly XLColor TabGreen = XLColor.FromHtml("#70AD47");

    /// <summary>Accent 2 — raw-data sheet tab colour, as on the Production Report.</summary>
    public static readonly XLColor TabGold = XLColor.FromHtml("#ED7D31");

    /// <summary>
    /// Excel Accounting (USD, 2 decimals): symbol flush left, figure right, negatives in
    /// parentheses, zero as a dash. Not Currency (<c>$#,##0.00</c>), which signs negatives and
    /// prints a zero as "$0.00".
    /// </summary>
    public const string AccountingNumberFormat2 = @"_($* #,##0.00_);_($* (#,##0.00);_($* ""-""??_);_(@_)";

    /// <summary>Counts with a dash for zero, matching the Accounting column beside them.</summary>
    public const string CountNumberFormat = @"#,##0;-#,##0;""-""";

    public const string FontName = "Calibri";
    public const double FontSizeBody = 10;
    public const double FontSizeHeader = 10;
    public const double FontSizeTitle = 14;

    /// <summary>Sets the workbook-wide default font, as ExcelTheme.ApplyDefaults does.</summary>
    public static void ApplyDefaults(IXLWorksheet ws)
    {
        ws.Style.Font.FontName = FontName;
        ws.Style.Font.FontSize = FontSizeBody;
    }

    /// <summary>Alternating row background: banded on odd rows, white on even.</summary>
    public static XLColor GetRowBg(int rowIndex) =>
        rowIndex % 2 != 0 ? BandedRowBg : XLColor.White;

    /// <summary>Styles a run of cells as a column-header row (dark green, white bold, centred).</summary>
    public static void StyleHeaderCell(IXLCell cell, XLColor? background = null)
    {
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = FontSizeHeader;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = background ?? HeaderBg;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        cell.Style.Alignment.WrapText = true;
        cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        cell.Style.Border.OutsideBorderColor = XLColor.White;
    }
}
