using ClosedXML.Excel;

namespace LRN.ReportsApi.Services;

/// <summary>
/// The Production Report workbook palette, so every LRN download looks like one product.
///
/// These are the Office 2013-2022 theme's Accent 6 green family at Excel's standard tint steps —
/// the same values as <c>LabMetricsDashboard/Services/ExcelTheme.cs</c>, which is the canonical
/// copy and the one to change if the house style moves. This API does not reference the web
/// application (and should not: nothing here needs an ASP.NET MVC project in its build graph), so
/// the constants are mirrored rather than shared.
///
/// Before this, the denial workflow downloads each picked their own colours — a pale blue
/// (#D9EAF7) header on the claims export, blue/green stripes on the upload template, and a navy
/// (#16325C) on the RPT-01 export — none of them theme colours and none matching the Production
/// Report.
/// </summary>
internal static class DenialExcelTheme
{
    /// <summary>Accent 6 Darker 50% — top-level title bars.</summary>
    public const string TitleBgHex = "#385723";

    /// <summary>Accent 6 Darker 25% — column headers and section headers.</summary>
    public const string HeaderBgHex = "#548235";

    /// <summary>Accent 6 base — period / sub-section headers.</summary>
    public const string SubHeaderBgHex = "#70AD47";

    /// <summary>Accent 6 Lighter 60% — group / parent rows.</summary>
    public const string GroupRowBgHex = "#C5E0B4";

    /// <summary>Accent 6 Lighter 80% — alternating banded rows.</summary>
    public const string BandedRowBgHex = "#E2EFDA";

    /// <summary>Accent 6 Lighter 40% — total rows.</summary>
    public const string TotalRowBgHex = "#A9D18E";

    /// <summary>Light 2 (Background 2) — sub-labels and secondary header bands.</summary>
    public const string SubLabelBgHex = "#E7E6E6";

    /// <summary>Accent 3 (Gray) — standard thin-border colour.</summary>
    public const string BorderHex = "#A5A5A5";

    public static readonly XLColor TitleBg = XLColor.FromHtml(TitleBgHex);
    public static readonly XLColor HeaderBg = XLColor.FromHtml(HeaderBgHex);
    public static readonly XLColor SubHeaderBg = XLColor.FromHtml(SubHeaderBgHex);
    public static readonly XLColor GroupRowBg = XLColor.FromHtml(GroupRowBgHex);
    public static readonly XLColor BandedRowBg = XLColor.FromHtml(BandedRowBgHex);
    public static readonly XLColor TotalRowBg = XLColor.FromHtml(TotalRowBgHex);
    public static readonly XLColor SubLabelBg = XLColor.FromHtml(SubLabelBgHex);
    public static readonly XLColor BorderColor = XLColor.FromHtml(BorderHex);

    /// <summary>Accent 6 base — primary sheet tab colour.</summary>
    public static readonly XLColor TabGreen = XLColor.FromHtml("#70AD47");

    /// <summary>Accent 2 — raw-data / reference sheet tabs, as on the Production Report.</summary>
    public static readonly XLColor TabGold = XLColor.FromHtml("#ED7D31");

    /// <summary>
    /// Excel Accounting (USD, 2 decimals): symbol flush left, figure right, negatives in
    /// parentheses, zero as a dash. Not Currency (<c>$#,##0.00</c>).
    /// </summary>
    public const string AccountingNumberFormat2 = @"_($* #,##0.00_);_($* (#,##0.00);_($* ""-""??_);_(@_)";

    public const string FontName = "Calibri";
    public const double FontSizeBody = 10;
    public const double FontSizeHeader = 10;
    public const double FontSizeTitle = 14;

    public static void ApplyDefaults(IXLWorksheet ws)
    {
        ws.Style.Font.FontName = FontName;
        ws.Style.Font.FontSize = FontSizeBody;
    }

    /// <summary>Column-header styling: dark green fill, white bold, centred, wrapped.</summary>
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

    /// <summary>
    /// True when a column header names a money column, so it can take the Accounting format.
    /// Name-based rather than CLR-type-based: a decimal column is not necessarily currency
    /// (percentages and rates are decimals too, and must not grow a dollar sign).
    /// </summary>
    public static bool IsMoneyColumn(string? header)
    {
        if (string.IsNullOrWhiteSpace(header)) return false;
        var h = header.Trim();
        if (h.Contains('%') || h.Contains("Percent", StringComparison.OrdinalIgnoreCase)) return false;
        return h.Contains("Balance", StringComparison.OrdinalIgnoreCase)
            || h.Contains("Amount", StringComparison.OrdinalIgnoreCase)
            || h.Contains("Charge", StringComparison.OrdinalIgnoreCase)
            || h.Contains("Payment", StringComparison.OrdinalIgnoreCase)
            || h.Contains("Adjustment", StringComparison.OrdinalIgnoreCase)
            || h.Contains("Paid", StringComparison.OrdinalIgnoreCase)
            || h.Contains("Fee", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The Accounting format escaped for a SpreadsheetML <c>ss:Format</c> attribute — the streamed
    /// claims export writes XML directly rather than building a ClosedXML workbook, because it has
    /// to stream millions of rows without holding one in memory.
    /// </summary>
    public const string AccountingNumberFormatXml =
        "_($* #,##0.00_);_($* (#,##0.00);_($* &quot;-&quot;??_);_(@_)";
}
