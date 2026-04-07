using ClosedXML.Excel;
using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

/// <summary>
/// Writes the "Panel Breakdown" sheet — claim breakdown grouped by
/// Forecasting Payability panel (Payable / Potentially Payable / etc.).
///
/// Same colour scheme and column layout as PayerValidationSheetWriter;
/// rows are grouped by ForecastingP instead of PayerName.
///
/// Columns: Panel Name | Total Claims | Paid | Denied | No Response |
///          Adjusted | Unpaid | Payment Rate (%) |
///          Predicted Allowed | Predicted Insurance Payment |
///          Allowed ($) | Actual Insurance Payment | Variance ($)
/// </summary>
public static class PanelBreakdownSheetWriter
{
    // ?? Professional colour palette — matches Payer Breakdown ????????????????

    private static readonly XLColor TitleBg       = XLColor.FromArgb(0x1C, 0x28, 0x33);
    private static readonly XLColor TitleAccent   = XLColor.FromArgb(0x2E, 0x40, 0x57);
    private static readonly XLColor SubtitleFg    = XLColor.FromArgb(0xAE, 0xC6, 0xCF);
    private static readonly XLColor HeaderBg      = XLColor.FromArgb(0x34, 0x49, 0x5E);
    private static readonly XLColor HeaderBg2     = XLColor.FromArgb(0x2C, 0x3E, 0x50);
    private static readonly XLColor TotalRowBg    = XLColor.FromArgb(0x1C, 0x28, 0x33);
    private static readonly XLColor White         = XLColor.White;
    private static readonly XLColor BodyText      = XLColor.FromArgb(0x2C, 0x2C, 0x2C);
    private static readonly XLColor AltRowBg      = XLColor.FromArgb(0xF4, 0xF6, 0xF7);

    private static readonly XLColor BadBg         = XLColor.FromArgb(0xFD, 0xEE, 0xEE);
    private static readonly XLColor WarnBg        = XLColor.FromArgb(0xFE, 0xF9, 0xEE);
    private static readonly XLColor GoodBg        = XLColor.FromArgb(0xEE, 0xF7, 0xEE);
    private static readonly XLColor NeutralBg     = XLColor.FromArgb(0xF4, 0xF6, 0xF7);

    private static readonly XLColor BadRate       = XLColor.FromArgb(0xC0, 0x39, 0x2B);
    private static readonly XLColor WarnRate      = XLColor.FromArgb(0xD3, 0x54, 0x00);
    private static readonly XLColor GoodRate      = XLColor.FromArgb(0x1E, 0x6F, 0x3E);

    private static readonly XLColor PositiveVar   = XLColor.FromArgb(0x1E, 0x6F, 0x3E);
    private static readonly XLColor NegativeVar   = XLColor.FromArgb(0xC0, 0x39, 0x2B);

    // Panel-type badge — understated tones
    private static readonly XLColor PayableBg     = XLColor.FromArgb(0xEB, 0xF5, 0xF3);
    private static readonly XLColor PayableFg     = XLColor.FromArgb(0x0E, 0x5E, 0x4A);
    private static readonly XLColor PotPayableBg  = XLColor.FromArgb(0xFE, 0xF5, 0xE7);
    private static readonly XLColor PotPayableFg  = XLColor.FromArgb(0xD3, 0x54, 0x00);
    private static readonly XLColor NeedActionBg  = XLColor.FromArgb(0xF6, 0xEB, 0xF3);
    private static readonly XLColor NeedActionFg  = XLColor.FromArgb(0x6C, 0x17, 0x4E);
    private static readonly XLColor OtherPanelBg  = XLColor.FromArgb(0xEB, 0xF0, 0xF7);
    private static readonly XLColor OtherPanelFg  = XLColor.FromArgb(0x1F, 0x3A, 0x6E);

    private const int ColCount       = 13;
    private const int ColPanelName   = 1;
    private const int ColTotalClaims = 2;
    private const int ColPaid        = 3;
    private const int ColDenied      = 4;
    private const int ColNoResponse  = 5;
    private const int ColAdjusted    = 6;
    private const int ColUnpaid      = 7;
    private const int ColPayRate     = 8;
    private const int ColPredAllowed = 9;
    private const int ColPredIns     = 10;
    private const int ColActAllowed  = 11;
    private const int ColActIns      = 12;
    private const int ColVariance    = 13;

    // ?? Entry point ???????????????????????????????????????????????????????????

    /// <summary>
    /// Writes the "Panel Breakdown" worksheet into <paramref name="wb"/>.
    /// </summary>
    /// <param name="wb">Target workbook.</param>
    /// <param name="predicted">All records that passed the ForecastingP + cutoff filter (includes Paid).</param>
    /// <param name="working">Unpaid subset (Denied + No Response + Adjusted).</param>
    /// <param name="settings">Analysis settings used to classify PayStatus values.</param>
    /// <param name="labName">Lab name shown in the title block.</param>
    /// <param name="weekFolderName">Period label shown in the subtitle.</param>
    /// <param name="weekStart">Cutoff date shown in the subtitle.</param>
    public static void Write(
        XLWorkbook wb,
        List<ClaimRecord> predicted,
        List<ClaimRecord> working,
        AnalysisSettings settings,
        string labName,
        string weekFolderName,
        DateTime weekStart)
    {
        var ws = wb.Worksheets.Add("Panel Breakdown");
        ws.ShowGridLines = false;

        SetColumnWidths(ws);

        int row = WriteTitleBlock(ws, labName, weekFolderName, weekStart);
        row++; // blank spacer row

        WriteHeaderRow(ws, row);
        row++;

        var rows = BuildPanelRows(predicted, working, settings);
        for (int i = 0; i < rows.Count; i++)
        {
            WriteDataRow(ws, row, rows[i], i);
            row++;
        }

        WriteTotalRow(ws, row, rows);
    }

    // ?? Title block ???????????????????????????????????????????????????????????

    private static int WriteTitleBlock(IXLWorksheet ws, string labName,
        string weekFolderName, DateTime weekStart)
    {
        ws.Range(1, 1, 1, ColCount).Merge().Style.Fill.BackgroundColor = TitleBg;
        var titleCell = ws.Cell(1, 1);
        titleCell.Value = $"{labName} \u2014 Prediction Validation by Panel (Claim Level)";
        titleCell.Style.Font.Bold            = true;
        titleCell.Style.Font.FontSize        = 15;
        titleCell.Style.Font.FontColor       = White;
        titleCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        titleCell.Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
        ws.Row(1).Height = 34;

        ws.Range(2, 1, 2, ColCount).Merge().Style.Fill.BackgroundColor = TitleAccent;
        var subCell = ws.Cell(2, 1);
        var weekEnd = weekStart.AddDays(6);
        subCell.Value =
            $"Period: {weekStart:MM/dd/yyyy} \u2013 {weekEnd:MM/dd/yyyy}  \u2502  Sorted by Total Claims Descending";
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
            "Panel Name", "Total Claims", "Paid", "Denied",
            "No Response", "Adjusted", "Unpaid", "Payment Rate (%)",
            "Predicted Allowed", "Predicted Insurance Payment",
            "Allowed ($)", "Actual Insurance Payment", "Variance ($)"
        ];

        for (int i = 0; i < headers.Length; i++)
        {
            int col  = i + 1;
            var cell = ws.Cell(row, col);
            cell.Value                          = headers[i];
            cell.Style.Fill.BackgroundColor     = col <= ColPayRate ? HeaderBg : HeaderBg2;
            cell.Style.Font.Bold                = true;
            cell.Style.Font.FontColor           = White;
            cell.Style.Font.FontSize            = 10;
            cell.Style.Alignment.Horizontal     = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical       = XLAlignmentVerticalValues.Center;
            cell.Style.Alignment.WrapText       = true;
            cell.Style.Border.BottomBorder      = XLBorderStyleValues.Medium;
            cell.Style.Border.BottomBorderColor = White;
        }

        ws.Row(row).Height = 40;
    }

    // ?? Data rows ?????????????????????????????????????????????????????????????

    private static void WriteDataRow(IXLWorksheet ws, int row, PanelRow pr, int rowIndex)
    {
        var baseBg = rowIndex % 2 == 0 ? White : AltRowBg;
        var bg     = pr.TotalClaims == 0  ? baseBg
                   : pr.PaymentRate == 0m  ? BadBg
                   : pr.PaymentRate >= 50m ? GoodBg
                   : WarnBg;

        ws.Range(row, 1, row, ColCount).Style.Fill.BackgroundColor = bg;
        ws.Range(row, 1, row, ColCount).Style.Border.BottomBorder      = XLBorderStyleValues.Thin;
        ws.Range(row, 1, row, ColCount).Style.Border.BottomBorderColor = XLColor.FromArgb(0xDC, 0xDC, 0xDC);

        // ?? Panel Name — understated badge ????????????????????????????????????
        var nameCell = ws.Cell(row, ColPanelName);
        nameCell.Value                        = pr.PanelName;
        nameCell.Style.Font.Bold              = true;
        nameCell.Style.Font.FontSize          = 10;
        (nameCell.Style.Fill.BackgroundColor,
         nameCell.Style.Font.FontColor)       = ClassifyPanelColors(pr.PanelName);
        nameCell.Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Left;

        SetInt(ws, row, ColTotalClaims, pr.TotalClaims, bold: true);
        SetInt(ws, row, ColPaid,        pr.Paid,        color: pr.Paid       > 0 ? GoodRate : BodyText);
        SetInt(ws, row, ColDenied,      pr.Denied,      color: pr.Denied     > 0 ? BadRate  : BodyText);
        SetInt(ws, row, ColNoResponse,  pr.NoResponse,  color: pr.NoResponse > 0 ? WarnRate : BodyText);
        SetInt(ws, row, ColAdjusted,    pr.Adjusted,    color: pr.Adjusted   > 0 ? WarnRate : BodyText);
        SetInt(ws, row, ColUnpaid,      pr.Unpaid,      bold: true,
                                                        color: pr.Unpaid     > 0 ? BadRate  : BodyText);

        var rateCell = ws.Cell(row, ColPayRate);
        rateCell.Value                        = $"{pr.PaymentRate:N1}%";
        rateCell.Style.Font.Bold              = true;
        rateCell.Style.Font.FontSize          = 10;
        rateCell.Style.Font.FontColor         = pr.PaymentRate == 0m   ? BadRate
                                              : pr.PaymentRate >= 50m  ? GoodRate
                                              : WarnRate;
        rateCell.Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Center;

        SetMoney(ws, row, ColPredAllowed, pr.PredictedAllowed);
        SetMoney(ws, row, ColPredIns,     pr.PredictedInsurance);
        SetMoney(ws, row, ColActAllowed,  pr.ActualAllowed);
        SetMoney(ws, row, ColActIns,      pr.ActualInsurance);

        if (pr.Variance != 0m)
        {
            var varCell = ws.Cell(row, ColVariance);
            varCell.Value                      = pr.Variance;
            varCell.Style.NumberFormat.Format  = "$#,##0.00";
            varCell.Style.Font.Bold            = false;
            varCell.Style.Font.FontSize        = 10;
            varCell.Style.Font.FontColor       = pr.Variance >= 0m ? PositiveVar : NegativeVar;
            varCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        }

        ws.Row(row).Height = 18;
    }

    // ?? Total row ?????????????????????????????????????????????????????????????

    private static void WriteTotalRow(IXLWorksheet ws, int row, List<PanelRow> rows)
    {
        ws.Range(row, 1, row, ColCount).Style.Fill.BackgroundColor  = TotalRowBg;
        ws.Range(row, 1, row, ColCount).Style.Border.TopBorder      = XLBorderStyleValues.Medium;
        ws.Range(row, 1, row, ColCount).Style.Border.TopBorderColor = HeaderBg;

        var lbl = ws.Cell(row, ColPanelName);
        lbl.Value                      = "TOTAL";
        lbl.Style.Font.Bold            = true;
        lbl.Style.Font.FontSize        = 11;
        lbl.Style.Font.FontColor       = White;

        void TotalInt(int col, int val)
        {
            var c                        = ws.Cell(row, col);
            c.Value                      = val;
            c.Style.Font.Bold            = true;
            c.Style.Font.FontColor       = White;
            c.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        void TotalMoney(int col, decimal val, XLColor? color = null)
        {
            var c                        = ws.Cell(row, col);
            c.Value                      = val;
            c.Style.NumberFormat.Format  = "$#,##0.00";
            c.Style.Font.Bold            = true;
            c.Style.Font.FontColor       = color ?? White;
            c.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        TotalInt  (ColTotalClaims, rows.Sum(r => r.TotalClaims));
        TotalInt  (ColPaid,        rows.Sum(r => r.Paid));
        TotalInt  (ColDenied,      rows.Sum(r => r.Denied));
        TotalInt  (ColNoResponse,  rows.Sum(r => r.NoResponse));
        TotalInt  (ColAdjusted,    rows.Sum(r => r.Adjusted));
        TotalInt  (ColUnpaid,      rows.Sum(r => r.Unpaid));
        TotalMoney(ColPredAllowed, rows.Sum(r => r.PredictedAllowed));
        TotalMoney(ColPredIns,     rows.Sum(r => r.PredictedInsurance));
        TotalMoney(ColActAllowed,  rows.Sum(r => r.ActualAllowed));
        TotalMoney(ColActIns,      rows.Sum(r => r.ActualInsurance));

        decimal totalVariance = rows.Sum(r => r.Variance);
        TotalMoney(ColVariance, totalVariance,
            color: totalVariance >= 0m
                ? XLColor.FromArgb(0xA8, 0xD5, 0xB5)   // soft mint
                : XLColor.FromArgb(0xF0, 0xA0, 0x9A));  // soft coral

        ws.Row(row).Height = 22;
    }

    // ?? Build panel rows from claim data ??????????????????????????????????????

    private static List<PanelRow> BuildPanelRows(
        List<ClaimRecord> predicted,
        List<ClaimRecord> working,
        AnalysisSettings settings)
    {
        // Use PanelName when available; fall back to ForecastingP when blank.
        static string PanelKey(ClaimRecord r)
        {
            var name = r.PanelName.Trim();
            return string.IsNullOrEmpty(name) ? r.ForecastingP.Trim() : name;
        }

        var byPanel = predicted
            .GroupBy(PanelKey, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var unpaidByPanel = working
            .GroupBy(PanelKey, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var allPanels = byPanel.Keys
            .Union(unpaidByPanel.Keys, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var result = new List<PanelRow>(allPanels.Count);

        foreach (var panel in allPanels)
        {
            byPanel.TryGetValue(panel, out var predRecords);
            unpaidByPanel.TryGetValue(panel, out var unpaidRecords);

            predRecords   ??= [];
            unpaidRecords ??= [];

            int totalClaims = predRecords.Select(r => r.VisitNumber).Distinct().Count();

            int paidCount = predRecords
                .Where(r => r.PayStatus.Trim().Equals(
                    settings.PayStatusPaid, StringComparison.OrdinalIgnoreCase))
                .Select(r => r.VisitNumber).Distinct().Count();

            int deniedCount = unpaidRecords
                .Where(r => r.PayStatus.Trim().Equals(
                    settings.PayStatusDenied, StringComparison.OrdinalIgnoreCase))
                .Select(r => r.VisitNumber).Distinct().Count();

            int noRespCount = unpaidRecords
                .Where(r => r.PayStatus.Trim().Equals(
                    settings.PayStatusNoResponse, StringComparison.OrdinalIgnoreCase))
                .Select(r => r.VisitNumber).Distinct().Count();

            int adjCount = unpaidRecords
                .Where(r => r.PayStatus.Trim().Equals(
                    settings.PayStatusAdjusted, StringComparison.OrdinalIgnoreCase))
                .Select(r => r.VisitNumber).Distinct().Count();

            int unpaidCount = unpaidRecords.Select(r => r.VisitNumber).Distinct().Count();

            decimal payRate      = totalClaims == 0 ? 0m
                                 : Math.Round((decimal)paidCount / totalClaims * 100, 1);
            decimal predAllowed  = predRecords.Sum(r => r.ModeAllowedAmount);
            decimal predIns      = predRecords.Sum(r => r.ModeInsurancePaid);
            decimal actAllowed   = predRecords.Sum(r => r.AllowedAmount);
            decimal actIns       = predRecords.Sum(r => r.InsurancePayment);
            decimal variance     = actAllowed - predAllowed;

            result.Add(new PanelRow(
                PanelName:           panel,
                TotalClaims:         totalClaims,
                Paid:                paidCount,
                Denied:              deniedCount,
                NoResponse:          noRespCount,
                Adjusted:            adjCount,
                Unpaid:              unpaidCount,
                PaymentRate:         payRate,
                PredictedAllowed:    predAllowed,
                PredictedInsurance:  predIns,
                ActualAllowed:       actAllowed,
                ActualInsurance:     actIns,
                Variance:            variance));
        }

        return result
            .OrderByDescending(r => r.TotalClaims)
            .ToList();
    }

    // ?? Panel badge colour classifier ?????????????????????????????????????????

    private static (XLColor bg, XLColor fg) ClassifyPanelColors(string panelName)
    {
        if (panelName.Contains("Need Action", StringComparison.OrdinalIgnoreCase))
            return (NeedActionBg, NeedActionFg);
        if (panelName.Contains("Potentially", StringComparison.OrdinalIgnoreCase))
            return (PotPayableBg, PotPayableFg);
        if (panelName.Contains("Payable", StringComparison.OrdinalIgnoreCase))
            return (PayableBg, PayableFg);
        return (OtherPanelBg, OtherPanelFg);
    }

    // ?? Cell helpers ??????????????????????????????????????????????????????????

    private static void SetInt(IXLWorksheet ws, int row, int col, int value,
        bool bold = false, XLColor? color = null)
    {
        var c                        = ws.Cell(row, col);
        c.Value                      = value;
        c.Style.Font.FontSize        = 10;
        c.Style.Font.Bold            = bold;
        c.Style.Font.FontColor       = color ?? BodyText;
        c.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
    }

    private static void SetMoney(IXLWorksheet ws, int row, int col, decimal value)
    {
        if (value == 0m) return;
        var c                        = ws.Cell(row, col);
        c.Value                      = value;
        c.Style.NumberFormat.Format  = "$#,##0.00";
        c.Style.Font.FontSize        = 10;
        c.Style.Font.FontColor       = BodyText;
        c.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
    }

    // ?? Column widths ?????????????????????????????????????????????????????????

    private static void SetColumnWidths(IXLWorksheet ws)
    {
        ws.Column(ColPanelName).Width   = 28;
        ws.Column(ColTotalClaims).Width = 11;
        ws.Column(ColPaid).Width        = 8;
        ws.Column(ColDenied).Width      = 9;
        ws.Column(ColNoResponse).Width  = 12;
        ws.Column(ColAdjusted).Width    = 10;
        ws.Column(ColUnpaid).Width      = 9;
        ws.Column(ColPayRate).Width     = 13;
        ws.Column(ColPredAllowed).Width = 16;
        ws.Column(ColPredIns).Width     = 20;
        ws.Column(ColActAllowed).Width  = 14;
        ws.Column(ColActIns).Width      = 18;
        ws.Column(ColVariance).Width    = 13;
    }

    // ?? Internal row model ????????????????????????????????????????????????????

    private record PanelRow(
        string  PanelName,
        int     TotalClaims,
        int     Paid,
        int     Denied,
        int     NoResponse,
        int     Adjusted,
        int     Unpaid,
        decimal PaymentRate,
        decimal PredictedAllowed,
        decimal PredictedInsurance,
        decimal ActualAllowed,
        decimal ActualInsurance,
        decimal Variance);
}
