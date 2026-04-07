using ClosedXML.Excel;
using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

/// <summary>
/// Writes the "Denial Code Analysis" sheet — one row per unique denial code,
/// sorted by line-item count descending.
///
/// Columns: Denial Code | Denial Description | Line Item Count (#) |
///          % of All Denials | # Unique Payers | Allowed Amt ($) |
///          Payers (list of unique payers for the denial code)
/// </summary>
public static class DenialCodeAnalysisSheetWriter
{
    // ?? Professional colour palette — matches Payer / Panel Breakdown ?????????

    private static readonly XLColor TitleBg      = XLColor.FromArgb(0x1C, 0x28, 0x33); // charcoal slate
    private static readonly XLColor TitleAccent  = XLColor.FromArgb(0x2E, 0x40, 0x57); // steel-blue stripe
    private static readonly XLColor SubtitleFg   = XLColor.FromArgb(0xAE, 0xC6, 0xCF); // muted powder blue
    private static readonly XLColor HeaderBg     = XLColor.FromArgb(0x34, 0x49, 0x5E); // professional slate-blue
    private static readonly XLColor TotalRowBg   = XLColor.FromArgb(0x1C, 0x28, 0x33); // matches title
    private static readonly XLColor White        = XLColor.White;
    private static readonly XLColor BodyText     = XLColor.FromArgb(0x2C, 0x2C, 0x2C); // near-black
    private static readonly XLColor AltRowBg     = XLColor.FromArgb(0xF4, 0xF6, 0xF7); // very light warm grey
    private static readonly XLColor SourceNote   = XLColor.FromArgb(0x5D, 0x6D, 0x7E); // muted slate

    // % of all denials heat-map — professional, not loud
    private static readonly XLColor PctHighBg    = XLColor.FromArgb(0xFD, 0xEE, 0xEE); // faint blush   ? 20 %
    private static readonly XLColor PctHighFg    = XLColor.FromArgb(0xC0, 0x39, 0x2B); // professional crimson
    private static readonly XLColor PctMidBg     = XLColor.FromArgb(0xFE, 0xF9, 0xEE); // faint cream   5–19 %
    private static readonly XLColor PctMidFg     = XLColor.FromArgb(0xD3, 0x54, 0x00); // burnt orange
    private static readonly XLColor PctLowBg     = XLColor.FromArgb(0xEE, 0xF7, 0xEE); // faint sage    < 5 %
    private static readonly XLColor PctLowFg     = XLColor.FromArgb(0x1E, 0x6F, 0x3E); // dark green

    private const int ColCount      = 7;
    private const int ColCode       = 1;
    private const int ColDesc       = 2;
    private const int ColCount_     = 3;  // Line Item Count
    private const int ColPct        = 4;  // % of All Denials
    private const int ColPayers     = 5;  // # Unique Payers
    private const int ColAllowed    = 6;  // Allowed Amt ($)
    private const int ColPayerList  = 7;  // Payer list

    // ?? Entry point ???????????????????????????????????????????????????????????

    /// <summary>
    /// Writes the "Denial Code Analysis" worksheet into <paramref name="wb"/>.
    /// </summary>
    /// <param name="wb">Target workbook.</param>
    /// <param name="rows">Pre-built analysis rows from <see cref="AnalysisService.BuildDenialCodeAnalysis"/>.</param>
    /// <param name="labName">Lab name shown in the title block.</param>
    /// <param name="weekFolderName">Period label shown in the subtitle.</param>
    /// <param name="weekStart">Start of the reporting week.</param>
    public static void Write(
        XLWorkbook wb,
        List<DenialCodeAnalysisRow> rows,
        string labName,
        string weekFolderName,
        DateTime weekStart)
    {
        var ws = wb.Worksheets.Add("Denial Code Analysis");
        ws.ShowGridLines = false;

        SetColumnWidths(ws);

        int totalDeniedLineItems = rows.Sum(r => r.LineItemCount);
        int row = WriteTitleBlock(ws, labName, weekFolderName, weekStart, totalDeniedLineItems);

        // Source note row
        var srcCell = ws.Cell(row, 1);
        ws.Range(row, 1, row, ColCount).Merge();
        srcCell.Value                        = "Source : Predicted To Pay - Unpaid Sheet";
        srcCell.Style.Font.Italic            = true;
        srcCell.Style.Font.FontSize          = 9;
        srcCell.Style.Font.FontColor         = SourceNote;
        srcCell.Style.Fill.BackgroundColor   = White;
        ws.Row(row).Height                   = 16;
        row++;

        row++; // blank spacer

        WriteHeaderRow(ws, row);
        row++;

        for (int i = 0; i < rows.Count; i++)
        {
            WriteDataRow(ws, row, rows[i], i);
            row++;
        }

        WriteTotalRow(ws, row, rows);

        ws.SheetView.FreezeRows(4); // freeze title + source note + spacer + header
    }

    // ?? Title block ???????????????????????????????????????????????????????????

    private static int WriteTitleBlock(IXLWorksheet ws, string labName,
        string weekFolderName, DateTime weekStart, int totalDeniedLineItems)
    {
        // Row 1 — deep navy title
        ws.Range(1, 1, 1, ColCount).Merge().Style.Fill.BackgroundColor = TitleBg;
        var titleCell = ws.Cell(1, 1);
        titleCell.Value = $"{labName} \u2014 Denial Code Analysis (Line Item Level)";
        titleCell.Style.Font.Bold            = true;
        titleCell.Style.Font.FontSize        = 15;
        titleCell.Style.Font.FontColor       = White;
        titleCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        titleCell.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
        ws.Row(1).Height = 34;

        // Row 2 — accent-stripe subtitle with total denied line items + period
        ws.Range(2, 1, 2, ColCount).Merge().Style.Fill.BackgroundColor = TitleAccent;
        var subCell = ws.Cell(2, 1);
        var weekEnd = weekStart.AddDays(6);
        subCell.Value =
            $"Total Denied Line Items: {totalDeniedLineItems:N0}  \u2502  " +
            $"Period: {weekStart:MM/dd/yyyy} \u2013 {weekEnd:MM/dd/yyyy}";
        subCell.Style.Font.FontSize          = 10;
        subCell.Style.Font.Italic            = true;
        subCell.Style.Font.FontColor         = SubtitleFg;
        subCell.Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Center;
        subCell.Style.Alignment.Vertical     = XLAlignmentVerticalValues.Center;
        ws.Row(2).Height = 20;

        return 3;
    }

    // ?? Header row ????????????????????????????????????????????????????????????

    private static void WriteHeaderRow(IXLWorksheet ws, int row)
    {
        string[] headers =
        [
            "Denial Code", "Denial Description", "Line Item Count (#)",
            "% of All Denials", "# Unique Payers", "Allowed Amt ($)",
            "Payers"
        ];

        for (int i = 0; i < headers.Length; i++)
        {
            var cell = ws.Cell(row, i + 1);
            cell.Value                          = headers[i];
            cell.Style.Fill.BackgroundColor     = HeaderBg;
            cell.Style.Font.Bold                = true;
            cell.Style.Font.FontColor           = White;
            cell.Style.Font.FontSize            = 10;
            cell.Style.Alignment.Horizontal     = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical       = XLAlignmentVerticalValues.Center;
            cell.Style.Alignment.WrapText       = true;
            cell.Style.Border.BottomBorder      = XLBorderStyleValues.Medium;
            cell.Style.Border.BottomBorderColor = White;
        }

        ws.Row(row).Height = 36;
    }

    // ?? Data rows ?????????????????????????????????????????????????????????????

    private static void WriteDataRow(IXLWorksheet ws, int row, DenialCodeAnalysisRow r, int index)
    {
        var rowBg = index % 2 == 0 ? White : AltRowBg;
        ws.Range(row, 1, row, ColCount).Style.Fill.BackgroundColor     = rowBg;
        ws.Range(row, 1, row, ColCount).Style.Border.BottomBorder      = XLBorderStyleValues.Thin;
        ws.Range(row, 1, row, ColCount).Style.Border.BottomBorderColor = XLColor.FromArgb(0xDC, 0xDC, 0xDC);

        // Denial Code — professional navy text
        var codeCell = ws.Cell(row, ColCode);
        codeCell.Value                      = r.DenialCode;
        codeCell.Style.Font.Bold            = true;
        codeCell.Style.Font.FontSize        = 10;
        codeCell.Style.Font.FontColor       = XLColor.FromArgb(0x1F, 0x3A, 0x6E); // professional navy
        codeCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;

        // Denial Description
        var descCell = ws.Cell(row, ColDesc);
        descCell.Value                      = r.DenialDescription;
        descCell.Style.Font.FontSize        = 10;
        descCell.Style.Font.FontColor       = BodyText;
        descCell.Style.Alignment.WrapText   = true;

        // Line Item Count
        var cntCell = ws.Cell(row, ColCount_);
        cntCell.Value                       = r.LineItemCount;
        cntCell.Style.Font.Bold             = true;
        cntCell.Style.Font.FontSize         = 10;
        cntCell.Style.Font.FontColor        = BodyText;
        cntCell.Style.Alignment.Horizontal  = XLAlignmentHorizontalValues.Center;

        // % of All Denials — subtle heat-map on the cell only
        var pctCell = ws.Cell(row, ColPct);
        pctCell.Value                       = $"{r.PctOfAllDenials:N1}%";
        pctCell.Style.Font.Bold             = true;
        pctCell.Style.Font.FontSize         = 10;
        pctCell.Style.Alignment.Horizontal  = XLAlignmentHorizontalValues.Center;
        (pctCell.Style.Fill.BackgroundColor,
         pctCell.Style.Font.FontColor)      = r.PctOfAllDenials >= 20m
                                             ? (PctHighBg, PctHighFg)
                                             : r.PctOfAllDenials >= 5m
                                             ? (PctMidBg,  PctMidFg)
                                             : (PctLowBg,  PctLowFg);

        // # Unique Payers
        var upCell = ws.Cell(row, ColPayers);
        upCell.Value                        = r.UniquePayers;
        upCell.Style.Font.FontSize          = 10;
        upCell.Style.Font.FontColor         = BodyText;
        upCell.Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Center;

        // Allowed Amt ($)
        var amtCell = ws.Cell(row, ColAllowed);
        amtCell.Value                       = r.AllowedAmount;
        amtCell.Style.NumberFormat.Format   = "$#,##0.00";
        amtCell.Style.Font.FontSize         = 10;
        amtCell.Style.Font.FontColor        = BodyText;
        amtCell.Style.Alignment.Horizontal  = XLAlignmentHorizontalValues.Right;

        // Payer list — italic, muted slate
        var plCell = ws.Cell(row, ColPayerList);
        plCell.Value                        = r.PayerList;
        plCell.Style.Font.Italic            = true;
        plCell.Style.Font.FontSize          = 9;
        plCell.Style.Font.FontColor         = XLColor.FromArgb(0x5D, 0x6D, 0x7E); // muted slate
        plCell.Style.Alignment.WrapText     = true;
        plCell.Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Left;

        ws.Row(row).Height = 18;
    }

    // ?? Total row ?????????????????????????????????????????????????????????????

    private static void WriteTotalRow(IXLWorksheet ws, int row, List<DenialCodeAnalysisRow> rows)
    {
        ws.Range(row, 1, row, ColCount).Style.Fill.BackgroundColor   = TotalRowBg;
        ws.Range(row, 1, row, ColCount).Style.Border.TopBorder       = XLBorderStyleValues.Medium;
        ws.Range(row, 1, row, ColCount).Style.Border.TopBorderColor  = HeaderBg;

        var lbl = ws.Cell(row, ColCode);
        lbl.Value                      = "TOTAL";
        lbl.Style.Font.Bold            = true;
        lbl.Style.Font.FontSize        = 11;
        lbl.Style.Font.FontColor       = White;

        // Total line items
        var totalCnt = ws.Cell(row, ColCount_);
        totalCnt.Value                         = rows.Sum(r => r.LineItemCount);
        totalCnt.Style.Font.Bold               = true;
        totalCnt.Style.Font.FontColor          = White;
        totalCnt.Style.Alignment.Horizontal    = XLAlignmentHorizontalValues.Center;

        // Total % — always 100.0%
        var totalPct = ws.Cell(row, ColPct);
        totalPct.Value                         = "100.0%";
        totalPct.Style.Font.Bold               = true;
        totalPct.Style.Font.FontColor          = White;
        totalPct.Style.Alignment.Horizontal    = XLAlignmentHorizontalValues.Center;

        // Total allowed
        var totalAmt = ws.Cell(row, ColAllowed);
        totalAmt.Value                         = rows.Sum(r => r.AllowedAmount);
        totalAmt.Style.NumberFormat.Format     = "$#,##0.00";
        totalAmt.Style.Font.Bold               = true;
        totalAmt.Style.Font.FontColor          = White;
        totalAmt.Style.Alignment.Horizontal    = XLAlignmentHorizontalValues.Center;

        ws.Row(row).Height = 22;
    }

    // ?? Column widths ?????????????????????????????????????????????????????????

    private static void SetColumnWidths(IXLWorksheet ws)
    {
        ws.Column(ColCode).Width      = 18;
        ws.Column(ColDesc).Width      = 30;
        ws.Column(ColCount_).Width    = 16;
        ws.Column(ColPct).Width       = 16;
        ws.Column(ColPayers).Width    = 14;
        ws.Column(ColAllowed).Width   = 16;
        ws.Column(ColPayerList).Width = 55;
    }
}
