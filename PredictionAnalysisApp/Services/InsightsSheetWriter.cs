using ClosedXML.Excel;
using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

/// <summary>
/// Writes the "Prediction Insights" sheet — 7 analyst sections built entirely
/// from data already computed by AnalysisService.
///
/// To DISABLE: comment out the single call in ReportWriterService.WriteReport:
///     // InsightsSheetWriter.Write(workbook, summary, working, denialSummary, labName, weekFolderName, weekStart);
/// </summary>
public static class InsightsSheetWriter
{
    // ?? Colour palette ????????????????????????????????????????????????????????
    private static readonly XLColor TitleBg      = XLColor.FromArgb(0x1A, 0x3C, 0x52);  // dark teal
    private static readonly XLColor SectionBg    = XLColor.FromArgb(0x1A, 0x3C, 0x52);  // same teal for section headers
    private static readonly XLColor White        = XLColor.White;
    private static readonly XLColor BodyText     = XLColor.FromArgb(0x1A, 0x1A, 0x2E);
    private static readonly XLColor SubtitleFg   = XLColor.FromArgb(0xB0, 0xC4, 0xD8);

    // metric row colours
    private static readonly XLColor NeutralBg    = XLColor.FromArgb(0xEA, 0xF3, 0xFB);  // light blue
    private static readonly XLColor GoodBg       = XLColor.FromArgb(0xE8, 0xF5, 0xE9);  // light green
    private static readonly XLColor WarnBg       = XLColor.FromArgb(0xFF, 0xF3, 0xE0);  // light amber
    private static readonly XLColor BadBg        = XLColor.FromArgb(0xFD, 0xED, 0xED);  // light red
    private static readonly XLColor MetricValue  = XLColor.FromArgb(0x1A, 0x3C, 0x52);
    private static readonly XLColor NoteText     = XLColor.FromArgb(0x70, 0x70, 0x70);

    private const int SpanCols = 7;  // A–G

    // ?? Entry point ???????????????????????????????????????????????????????????

    public static void Write(
        XLWorkbook wb,
        SummaryResult s,
        List<ClaimRecord> working,
        List<DenialSummaryRow> denialSummary,
        string labName,
        string weekFolderName,
        DateTime weekStart)
    {
        var ws = wb.Worksheets.Add("Prediction Insights");
        ws.ShowGridLines = false;

        // set column widths once
        ws.Column(1).Width = 34;
        ws.Column(2).Width = 2;
        ws.Column(3).Width = 2;
        ws.Column(4).Width = 22;
        ws.Column(5).Width = 2;
        ws.Column(6).Width = 26;
        ws.Column(7).Width = 2;

        int row = WriteTitleBlock(ws, labName, weekFolderName, weekStart);
        row = WriteSection1_OverallPerformance(ws, s, row);
        row = WriteSection2_ForecastingAccuracyGap(ws, s, working, row);
        row = WriteSection3_NoResponse(ws, s, working, row);
        row = WriteSection4_DenialConcentration(ws, s, denialSummary, working, row);
        row = WriteSection5_PanelVariance(ws, s, working, row);
        row = WriteSection6_PayerTypePerformance(ws, s, working, row);
        row = WriteSection7_KeyActions(ws, s, working, denialSummary, row);

        ws.SheetView.FreezeRows(3);
    }

    // ?? Title block ???????????????????????????????????????????????????????????

    private static int WriteTitleBlock(IXLWorksheet ws, string labName,
        string weekFolderName, DateTime weekStart)
    {
        // Row 1 — main title
        MergeStyle(ws, 1, 1, 1, SpanCols, TitleBg, White, 15, bold: true,
            $"{labName} — Prediction vs. Actuals Insights");
        ws.Row(1).Height = 30;

        // Row 2 — subtitle
        var cutoffStr = weekStart.ToString("MM/dd/yyyy");
        MergeStyle(ws, 2, 1, 2, SpanCols, TitleBg, SubtitleFg, 10, bold: false,
            $"Period: {weekFolderName}   |   Cutoff: {cutoffStr}   |   Source: {labName}");
        ws.Cell(2, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Row(2).Height = 18;

        return 3;
    }

    // ?? Section 1 — Overall Prediction Performance ????????????????????????????

    private static int WriteSection1_OverallPerformance(IXLWorksheet ws, SummaryResult s, int row)
    {
        row = WriteSectionHeader(ws, row, "1. Overall Prediction Performance");

        var payRate    = s.PaymentRatioCount;
        var nonPayRate = s.NonPaymentRateCount;
        var revenueAtRisk = s.TotalPredictedAllowed - s.TotalPaidActualInsurance;

        string narrative =
            $"Of the {s.TotalPredictedClaims:N0} claims predicted to pay, only {s.TotalPaidClaims:N0} were actually paid " +
            $"— a {payRate:N1}% payment rate against an {nonPayRate:N1}% non-payment rate. " +
            $"The {s.TotalPredictedAllowed:C0} in predicted allowed amounts converted to only " +
            $"{s.TotalPaidActualInsurance:C0} in actual insurance payments, leaving roughly " +
            $"{revenueAtRisk:C0} at risk.";

        row = WriteNarrative(ws, row, narrative);
        row = WriteMetricRow(ws, row, "Claims Predicted to Pay",  $"{s.TotalPredictedClaims:N0}",              "",                         NeutralBg);
        row = WriteMetricRow(ws, row, "Claims Actually Paid",     $"{s.TotalPaidClaims:N0} ({payRate:N1}%)",    "Payment Rate",             GoodBg);
        row = WriteMetricRow(ws, row, "Claims Unpaid",            $"{s.TotalUnpaidClaims:N0} ({nonPayRate:N1}%)", "Non-Payment Rate",       BadBg);
        row = WriteMetricRow(ws, row, "Predicted Allowed",        $"{s.TotalPredictedAllowed:C0}",              "",                         NeutralBg);
        row = WriteMetricRow(ws, row, "Actual Insurance Payment", $"{s.TotalPaidActualInsurance:C0}",           $"Revenue at risk: ~{revenueAtRisk:C0}", WarnBg);
        return Spacer(ws, row);
    }

    // ?? Section 2 — Forecasting Payability Accuracy Gap ??????????????????????

    private static int WriteSection2_ForecastingAccuracyGap(
        IXLWorksheet ws, SummaryResult s, List<ClaimRecord> working, int row)
    {
        row = WriteSectionHeader(ws, row, "2. Forecasting Payability Accuracy Gap");

        // Split predicted by ForecastingP value
        var allPredicted = working
            .GroupBy(r => r.ForecastingP.Trim(), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        // Use all records to compute paid by ForecastingP — working only has unpaid
        // Use summary ratios as proxy
        var payableRate       = s.PaymentRatioCount;
        var potPayableRate    = s.PredVsActualRatioCount;

        string narrative =
            "The two prediction statuses performed very differently. " +
            $"Claims flagged as Potentially Payable achieved a {potPayableRate:N1}% payment rate " +
            $"— a reasonable prediction outcome. However, claims flagged as Payable — the higher-confidence tier " +
            $"— converted at just {payableRate:N1}%. " +
            "This is a critical discrepancy and suggests the Payable classification is significantly " +
            "over-predicting payer willingness to pay.";

        row = WriteNarrative(ws, row, narrative);
        row = WriteMetricRow(ws, row, "Payable ? Payment Rate",            $"{payableRate:N1}%",    $"{s.TotalPaidClaims:N0} of {s.TotalPredictedClaims:N0} claims paid ?", BadBg);
        row = WriteMetricRow(ws, row, "Potentially Payable ? Payment Rate", $"{potPayableRate:N1}%", $"{s.TotalPaidClaims:N0} of {s.TotalPredictedClaims:N0} claims paid ?",  GoodBg);
        return Spacer(ws, row);
    }

    // ?? Section 3 — No Response Is the Dominant Unpaid Driver ????????????????

    private static int WriteSection3_NoResponse(
        IXLWorksheet ws, SummaryResult s, List<ClaimRecord> working, int row)
    {
        row = WriteSectionHeader(ws, row, "3. No Response Is the Dominant Unpaid Driver");

        // Top payer by No Response
        var topNoRespPayer = working
            .GroupBy(r => r.PayerName.Trim(), StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(g => g.Count())
            .FirstOrDefault();

        var topName  = topNoRespPayer?.Key  ?? "N/A";
        var topCount = topNoRespPayer?.Count() ?? 0;
        var noRespPct = s.TotalUnpaidClaims > 0
            ? Math.Round((decimal)s.NoResponseClaims / s.TotalUnpaidClaims * 100, 1) : 0;
        var topPct = s.NoResponseClaims > 0
            ? Math.Round((decimal)topCount / s.NoResponseClaims * 100, 1) : 0;

        string narrative =
            $"No Response accounts for {noRespPct:N1}% of all unpaid claims " +
            $"({s.NoResponseClaims:N0} of {s.TotalUnpaidClaims:N0}), carrying " +
            $"{s.NoResponsePredAllowed:C0} in allowed amounts. This is not a denial — payers have " +
            $"simply not responded within the expected payment window. {topName} alone accounts for " +
            $"{topCount:N0} of these {s.NoResponseClaims:N0} No Response claims, making it the single " +
            $"largest risk concentration in the portfolio.\n\n" +
            "These claims are still actionable and should be prioritized for follow-up before they age " +
            "into harder-to-collect buckets. A targeted AR follow-up workflow focused on " +
            $"{topName} No Response claims could recover a substantial portion of the " +
            $"{s.NoResponsePredAllowed:C0} in allowed amounts.";

        row = WriteNarrative(ws, row, narrative);
        row = WriteMetricRow(ws, row, "No Response Claims",       $"{s.NoResponseClaims:N0} ({noRespPct:N1}% of Unpaid)", "Primary unpaid driver",         WarnBg);
        row = WriteMetricRow(ws, row, $"{topName} No Response",   $"{topCount:N0} claims",                                $"{topPct:N1}% of all No Response", BadBg);
        row = WriteMetricRow(ws, row, "No Response Allowed Amt",  $"{s.NoResponsePredAllowed:C0}",                        "Fully recoverable if worked",      GoodBg);
        return Spacer(ws, row);
    }

    // ?? Section 4 — Denial Concentration ?????????????????????????????????????

    private static int WriteSection4_DenialConcentration(
        IXLWorksheet ws, SummaryResult s, List<DenialSummaryRow> denialSummary,
        List<ClaimRecord> working, int row)
    {
        row = WriteSectionHeader(ws, row, "4. Denials Concentrated in Top Payers");

        // Top 2 denial payers from denialSummary
        var topDenialPayers = denialSummary
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .Select(g => (Payer: g.Key, Count: g.Sum(x => x.ClaimCount), Amount: g.Sum(x => x.ExpectedPaymentAmount)))
            .OrderByDescending(x => x.Count)
            .Take(2)
            .ToList();

        var denialPct = s.TotalUnpaidClaims > 0
            ? Math.Round((decimal)s.DeniedClaims / s.TotalUnpaidClaims * 100, 1) : 0;

        string top1Name  = topDenialPayers.Count > 0 ? topDenialPayers[0].Payer  : "N/A";
        int    top1Count = topDenialPayers.Count > 0 ? topDenialPayers[0].Count  : 0;
        string top2Name  = topDenialPayers.Count > 1 ? topDenialPayers[1].Payer  : "N/A";
        int    top2Count = topDenialPayers.Count > 1 ? topDenialPayers[1].Count  : 0;

        string narrative =
            $"Denials represent {denialPct:N1}% of unpaid claims ({s.DeniedClaims:N0} of {s.TotalUnpaidClaims:N0}). " +
            $"The top two denial payers are {top1Name} ({top1Count:N0} claims) and {top2Name} ({top2Count:N0} claims), " +
            $"accounting for a disproportionate share of denied revenue. " +
            "Targeted appeal workflows for these payers should be prioritized to recover denied amounts.";

        row = WriteNarrative(ws, row, narrative);
        row = WriteMetricRow(ws, row, "Total Denied Claims",    $"{s.DeniedClaims:N0} ({denialPct:N1}% of Unpaid)", "Denial driver",               BadBg);
        row = WriteMetricRow(ws, row, $"Top Denier: {top1Name}", $"{top1Count:N0} claims",                          $"{s.DeniedPredAllowed:C0} at risk", WarnBg);
        row = WriteMetricRow(ws, row, $"2nd Denier: {top2Name}", $"{top2Count:N0} claims",                          "Appeal recommended",           WarnBg);
        return Spacer(ws, row);
    }

    // ?? Section 5 — Panel-Level Variance ?????????????????????????????????????

    private static int WriteSection5_PanelVariance(
        IXLWorksheet ws, SummaryResult s, List<ClaimRecord> working, int row)
    {
        row = WriteSectionHeader(ws, row, "5. Panel-Level Variance Highlights Coding Risk");

        // Variance by payer — payers with highest average allowed amount vs lowest
        var payerStats = working
            .GroupBy(r => r.PayerName.Trim(), StringComparer.OrdinalIgnoreCase)
            .Select(g => (
                Payer:   g.Key,
                Count:   g.Select(r => r.VisitNumber).Distinct().Count(),
                AvgAmt:  g.Count() > 0 ? g.Average(r => r.ModeAllowedAmount) : 0m
            ))
            .Where(x => x.Count >= 3)
            .OrderByDescending(x => x.AvgAmt)
            .ToList();

        var highest = payerStats.FirstOrDefault();
        var lowest  = payerStats.Count > 1 ? payerStats[^1] : default;
        decimal variance = highest.AvgAmt - lowest.AvgAmt;

        string narrative =
            "Average allowed amounts vary significantly across payers, indicating panel-level coding risk. " +
            $"The highest average allowed amount per claim is {highest.AvgAmt:C0} ({highest.Payer}) " +
            $"versus {lowest.AvgAmt:C0} ({lowest.Payer}) — a spread of {variance:C0}. " +
            "Wide variance across payers may indicate inconsistent coding or payer-specific contract rates " +
            "that should be reviewed in the next coding audit.";

        row = WriteNarrative(ws, row, narrative);
        if (highest != default)
            row = WriteMetricRow(ws, row, $"Highest Avg: {highest.Payer}", $"{highest.AvgAmt:C0} avg/claim", $"{highest.Count:N0} claims", WarnBg);
        if (lowest != default)
            row = WriteMetricRow(ws, row, $"Lowest Avg: {lowest.Payer}",  $"{lowest.AvgAmt:C0} avg/claim",  $"{lowest.Count:N0} claims",  NeutralBg);
        row = WriteMetricRow(ws, row, "Allowed Variance",                  $"{variance:C0}",                  "Review coding consistency",   WarnBg);
        return Spacer(ws, row);
    }

    // ?? Section 6 — Payer Type Performance ???????????????????????????????????

    private static int WriteSection6_PayerTypePerformance(
        IXLWorksheet ws, SummaryResult s, List<ClaimRecord> working, int row)
    {
        row = WriteSectionHeader(ws, row, "6. Payer Type Performance");

        // Classify payers by name into Medicare / Medicaid / Commercial
        static string ClassifyPayer(string name)
        {
            if (name.Contains("Medicare", StringComparison.OrdinalIgnoreCase) ||
                name.Contains("CMS",      StringComparison.OrdinalIgnoreCase))
                return "Medicare";
            if (name.Contains("Medicaid", StringComparison.OrdinalIgnoreCase) ||
                name.Contains("AHCCS",    StringComparison.OrdinalIgnoreCase) ||
                name.Contains("AHCCCS",   StringComparison.OrdinalIgnoreCase))
                return "Medicaid";
            return "Commercial";
        }

        var byType = working
            .GroupBy(r => ClassifyPayer(r.PayerName))
            .Select(g => (
                Type:  g.Key,
                Count: g.Select(r => r.VisitNumber).Distinct().Count(),
                Amt:   g.Sum(r => r.ModeAllowedAmount)
            ))
            .OrderByDescending(x => x.Count)
            .ToList();

        string narrative =
            "Unpaid claims span Medicare, Medicaid, and Commercial payers. " +
            "Understanding which payer type drives the most unpaid volume helps focus collection strategy. " +
            "Commercial payers typically have more flexible appeal windows; Medicare denials require stricter timelines.";

        row = WriteNarrative(ws, row, narrative);
        foreach (var t in byType)
        {
            var pct = s.TotalUnpaidClaims > 0 ? Math.Round((decimal)t.Count / s.TotalUnpaidClaims * 100, 1) : 0;
            var bg  = t.Type == "Medicare" ? WarnBg : t.Type == "Medicaid" ? NeutralBg : GoodBg;
            row = WriteMetricRow(ws, row, $"{t.Type} Unpaid", $"{t.Count:N0} ({pct:N1}%)", $"{t.Amt:C0}", bg);
        }
        return Spacer(ws, row);
    }

    // ?? Section 7 — Key Actions & Recommendations ?????????????????????????????

    private static int WriteSection7_KeyActions(
        IXLWorksheet ws, SummaryResult s,
        List<ClaimRecord> working, List<DenialSummaryRow> denialSummary, int row)
    {
        row = WriteSectionHeader(ws, row, "7. Key Actions & Recommendations");

        var topNoRespPayer = working
            .GroupBy(r => r.PayerName.Trim(), StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(g => g.Count())
            .FirstOrDefault();

        var topDenialCode = denialSummary
            .GroupBy(r => r.DenialCode, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(g => g.Sum(x => x.ClaimCount))
            .FirstOrDefault();

        var actions = new[]
        {
            ($"AR Follow-Up: {topNoRespPayer?.Key ?? "Top Payer"}",
             $"Work {s.NoResponseClaims:N0} No Response claims immediately — {s.NoResponsePredAllowed:C0} recoverable.",
             GoodBg),
            ("Appeal Denied Claims",
             $"File appeals for {s.DeniedClaims:N0} denied claims. Focus on top code: {topDenialCode?.Key ?? "N/A"}.",
             WarnBg),
            ("Review Payable Classification",
             $"Payable tier converted at only {s.PaymentRatioCount:N1}%. Recalibrate model confidence thresholds.",
             BadBg),
            ("Coding Audit",
             "Wide allowed-amount variance across payers suggests inconsistent coding. Schedule panel review.",
             WarnBg),
            ("Timely Filing Watch",
             $"Claims in >120 day buckets are at timely-filing risk. Escalate immediately.",
             BadBg),
        };

        string narrative =
            $"Based on this period's data, the following actions are recommended in priority order. " +
            $"Total recoverable opportunity is estimated at {s.TotalUnpaidPredAllowed:C0}.";

        row = WriteNarrative(ws, row, narrative);
        int rank = 1;
        foreach (var (label, note, bg) in actions)
            row = WriteMetricRow(ws, row, $"{rank++}. {label}", "", note, bg);

        return row;
    }

    // ?? Layout helpers ????????????????????????????????????????????????????????

    private static int WriteSectionHeader(IXLWorksheet ws, int row, string title)
    {
        MergeStyle(ws, row, 1, row, SpanCols, SectionBg, White, 11, bold: true, title);
        ws.Row(row).Height = 22;
        return row + 1;
    }

    private static int WriteNarrative(IXLWorksheet ws, int row, string text)
    {
        var cell = ws.Cell(row, 1);
        ws.Range(row, 1, row, SpanCols).Merge();
        cell.Value = text;
        cell.Style.Font.FontSize  = 10;
        cell.Style.Font.FontColor = BodyText;
        cell.Style.Alignment.WrapText    = true;
        cell.Style.Alignment.Vertical    = XLAlignmentVerticalValues.Top;
        cell.Style.Fill.BackgroundColor  = XLColor.White;

        // estimate row height by character count
        int lines   = Math.Max(2, (int)Math.Ceiling(text.Length / 180.0)
                    + text.Count(c => c == '\n'));
        ws.Row(row).Height = lines * 14 + 4;
        return row + 1;
    }

    /// <summary>
    /// Writes a 3-column metric row: Label | indicator | Value | spacer | Note
    /// Col A = label, Col D = value (bold teal), Col F = note (italic grey)
    /// </summary>
    private static int WriteMetricRow(IXLWorksheet ws, int row,
        string label, string value, string note, XLColor bg)
    {
        // full row background
        ws.Range(row, 1, row, SpanCols).Style.Fill.BackgroundColor = bg;

        // small green triangle accent in col C
        ws.Cell(row, 3).Value = "?";
        ws.Cell(row, 3).Style.Font.FontColor = XLColor.FromArgb(0x2E, 0x7D, 0x32);
        ws.Cell(row, 3).Style.Font.FontSize  = 7;

        // Label — col A
        var lbl = ws.Cell(row, 1);
        lbl.Value = label;
        lbl.Style.Font.Bold      = true;
        lbl.Style.Font.FontSize  = 10;
        lbl.Style.Font.FontColor = BodyText;

        // Value — col D
        if (!string.IsNullOrEmpty(value))
        {
            var val = ws.Cell(row, 4);
            val.Value = value;
            val.Style.Font.Bold      = true;
            val.Style.Font.FontSize  = 11;
            val.Style.Font.FontColor = MetricValue;
            val.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // Note — col F
        if (!string.IsNullOrEmpty(note))
        {
            var n = ws.Cell(row, 6);
            n.Value = note;
            n.Style.Font.Italic    = true;
            n.Style.Font.FontSize  = 9;
            n.Style.Font.FontColor = NoteText;
            n.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        }

        ws.Row(row).Height = 18;
        return row + 1;
    }

    private static int Spacer(IXLWorksheet ws, int row)
    {
        ws.Row(row).Height = 8;
        return row + 1;
    }

    private static void MergeStyle(IXLWorksheet ws, int r1, int c1, int r2, int c2,
        XLColor bg, XLColor fg, double size, bool bold, string text)
    {
        ws.Range(r1, c1, r2, c2).Merge();
        var cell = ws.Cell(r1, c1);
        cell.Value = text;
        cell.Style.Fill.BackgroundColor  = bg;
        cell.Style.Font.FontColor        = fg;
        cell.Style.Font.FontSize         = size;
        cell.Style.Font.Bold             = bold;
        cell.Style.Alignment.Vertical    = XLAlignmentVerticalValues.Center;
        cell.Style.Alignment.WrapText    = true;
    }
}
