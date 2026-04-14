using ClosedXML.Excel;
using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

public class ReportWriterService
{
    // Colours matching the image
    private static readonly XLColor DarkGreen = XLColor.FromArgb(0x1E, 0x49, 0x3B); // title row
    private static readonly XLColor MidGreen = XLColor.FromArgb(0x37, 0x6B, 0x4E); // month header
    private static readonly XLColor SubGreen = XLColor.FromArgb(0x52, 0x85, 0x65); // sub-header
    private static readonly XLColor PayerRowBg = XLColor.FromArgb(0xD9, 0xE6, 0xD5); // payer merged row
    private static readonly XLColor HeaderBg = XLColor.FromArgb(0x1F, 0x49, 0x7D);
    private static readonly XLColor HeaderFont = XLColor.White;
    private static readonly XLColor SectionBg = XLColor.FromArgb(0xD6, 0xE4, 0xF0);
    private static readonly XLColor White = XLColor.White;

    public string WriteReport(
        string processingFolderPath,
        SummaryResult summary,
        List<DenialSummaryRow> denialSummary,
        DenialPivotResult denialPivot,
        List<AgingPivotRow> aging,
        string sourceFilePath,
        List<ClaimRecord> predicted,
        List<ClaimRecord> working,
        string runId,
        string labName,
        string weekFolderName,
        ReadMeSettings readMe,
        AnalysisSettings settings,
        List<DenialCodeAnalysisRow> denialCodeAnalysis)
    {
        Directory.CreateDirectory(processingFolderPath);

        var now       = DateTime.Now;
        var weekTag   = SanitiseFileName(weekFolderName);
        var timestamp = now.ToString("ddMMyyyyHHmm");
        var fileName  = $"{runId}_{labName}_Prediction_vs_NonPayment_Analysis_{weekTag}_{timestamp}.xlsx";
        var outputPath = Path.Combine(processingFolderPath, fileName);

        Console.WriteLine($"[Step 4] Writing to Processing : {outputPath}");

        var weekStart = DateTime.Today.AddDays(-(((int)DateTime.Today.DayOfWeek + 6) % 7));

        int     predictedCount  = predicted.Select(r => r.VisitNumber).Distinct().Count();
        decimal predictedAmount = predicted.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeAllowedAmount));
        int     workingCount    = working.Select(r => r.VisitNumber).Distinct().Count();
        decimal workingAmount   = working.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeAllowedAmount));

        Console.WriteLine("[Step 4] Summary values:");
        Console.WriteLine($"         Predicted  — Count: {predictedCount,6} | Amount: {predictedAmount,12:C}");
        Console.WriteLine($"         Unpaid     — Count: {workingCount,6} | Amount: {workingAmount,12:C}");
        Console.WriteLine($"         Non-Pay %  — Count: {(predictedCount == 0 ? 0m : Math.Round((decimal)workingCount / predictedCount * 100, 2)),6}% | Amount: {(predictedAmount == 0 ? 0m : Math.Round(workingAmount / predictedAmount * 100, 2)),6}%");

        using var workbook = new XLWorkbook();

        WriteSheet0_ReadMe(workbook, readMe, now);           // ← always first tab
        WriteSheet1_Summary(workbook, summary, weekStart);
        InsightsSheetWriter.Write(workbook, summary, working, denialSummary, labName, weekFolderName, weekStart); // ← comment to disable
        PayerValidationSheetWriter.Write(workbook, predicted, working, settings, labName, weekFolderName, weekStart); // ← comment to disable
        PanelBreakdownSheetWriter.Write(workbook, predicted, working, settings, labName, weekFolderName, weekStart);  // ← comment to disable
        DenialCodeAnalysisSheetWriter.Write(workbook, denialCodeAnalysis, labName, weekFolderName, weekStart);         // ← comment to disable
        WriteSheet2_DenialPivot(workbook, denialPivot);
        WriteSheet3_NoResponseAging(workbook, aging);
        WriteSheet4_AnalystNotes(workbook, sourceFilePath, weekStart);
        WriteSheet5_PredictedSourceData(workbook, predicted);
        WriteSheet6_UnpaidWorkingData(workbook, working);

        workbook.SaveAs(outputPath);
        Console.WriteLine($"[Step 4] Report written : {fileName}");

        return outputPath;
    }

    private static string SanitiseFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return string.Concat(name.Select(c => invalid.Contains(c) ? '_' : c));
    }

    // ── Sheet 0: Read Me ──────────────────────────────────────────────────────
    private static void WriteSheet0_ReadMe(XLWorkbook wb, ReadMeSettings readMe, DateTime generatedAt)
    {
        var ws        = wb.Worksheets.Add("Read Me");
        var titleBg   = XLColor.FromArgb(0x1F, 0x49, 0x3B);
        var darkText  = XLColor.FromArgb(0x1F, 0x25, 0x5A);
        var green     = XLColor.FromArgb(0x37, 0x6B, 0x4E);
        var boldRed   = XLColor.FromArgb(0xC0, 0x00, 0x00);
        var redItalic = XLColor.FromArgb(0xC0, 0x00, 0x00);

        // ── Hide gridlines + flood entire sheet with white ────────────────────
        ws.ShowGridLines              = false;
        ws.Style.Fill.BackgroundColor = XLColor.White;

            int row = 1;

        // ── Row 1: Title ──────────────────────────────────────────────────────
        ws.Cell(row, 1).Value = "Read Me:";
        ws.Range(row, 1, row, 2).Merge();
        ws.Cell(row, 1).Style.Font.Bold            = true;
        ws.Cell(row, 1).Style.Font.FontSize        = 13;
        ws.Cell(row, 1).Style.Font.FontColor       = XLColor.White;
        ws.Cell(row, 1).Style.Fill.BackgroundColor = titleBg;
        ws.Row(row).Height = 24;
        row += 2;

        // ── Metrics section header ────────────────────────────────────────────
        ws.Cell(row, 1).Value = "How Metrics are calculated?";
        ws.Cell(row, 1).Style.Font.Bold            = true;
        ws.Cell(row, 1).Style.Font.FontSize        = 11;
        ws.Cell(row, 1).Style.Fill.BackgroundColor = XLColor.White;
        row++;

        foreach (var entry in readMe.Metrics)
        {
            ws.Cell(row, 1).Value = entry.Label;
            ws.Cell(row, 2).Value = entry.Description;

            var lc = ws.Cell(row, 1);
            lc.Style.Fill.BackgroundColor = XLColor.White;

            if (entry.Label.StartsWith("Total Unpaid", StringComparison.OrdinalIgnoreCase))
            {
                lc.Style.Font.FontColor = boldRed;
                lc.Style.Font.Bold      = true;
            }
            else
            {
                lc.Style.Font.FontColor = darkText;
            }

            var dc = ws.Cell(row, 2);
            dc.Style.Font.FontColor       = darkText;
            dc.Style.Fill.BackgroundColor = XLColor.White;
            row++;
        }

        row++;

        // ── Ratios section header ─────────────────────────────────────────────
        ws.Cell(row, 1).Value = "How Ratios are calculated?";
        ws.Cell(row, 1).Style.Font.Bold            = true;
        ws.Cell(row, 1).Style.Font.FontSize        = 11;
        ws.Cell(row, 1).Style.Fill.BackgroundColor = XLColor.White;
        row++;

        var ratioColors = new Dictionary<string, (XLColor color, bool bold, bool italic)>(
            StringComparer.OrdinalIgnoreCase)
        {
            ["Payment Ratio (%)"]    = (green,     false, true),
            ["Non-Payment Rate (%)"] = (boldRed,   true,  false),
            ["Denied (%)"]           = (redItalic, false, true),
            ["Adjusted (%)"]         = (redItalic, false, true),
            ["No Response (%)"]      = (redItalic, false, true),
        };

        foreach (var entry in readMe.Ratios)
        {
            ws.Cell(row, 1).Value = entry.Label;
            ws.Cell(row, 2).Value = entry.Description;

            var lc = ws.Cell(row, 1);
            lc.Style.Fill.BackgroundColor = XLColor.White;
            if (ratioColors.TryGetValue(entry.Label, out var s))
            {
                lc.Style.Font.FontColor = s.color;
                lc.Style.Font.Bold      = s.bold;
                lc.Style.Font.Italic    = s.italic;
            }

            var dc = ws.Cell(row, 2);
            dc.Style.Font.FontColor       = darkText;
            dc.Style.Fill.BackgroundColor = XLColor.White;
            row++;
        }

        row += 2;

        // ── Footer: generated timestamp ───────────────────────────────────────
        ws.Cell(row, 1).Value = $"Report generated: {generatedAt:MMMM dd, yyyy  HH:mm}";
        ws.Cell(row, 1).Style.Font.Italic             = true;
        ws.Cell(row, 1).Style.Font.FontColor          = XLColor.Gray;
        ws.Cell(row, 1).Style.Fill.BackgroundColor    = XLColor.White;
        ws.Range(row, 1, row, 2).Merge();

        // ── Column widths ─────────────────────────────────────────────────────
        ws.Column(1).Width = 30;
        ws.Column(2).Width = 115;
        ws.Column(2).Style.Alignment.WrapText = true;
    }

    // ── Sheet 1: Summary ──────────────────────────────────────────────────────
    private static void WriteSheet1_Summary(XLWorkbook wb, SummaryResult s, DateTime weekStart)
    {
        var ws            = wb.Worksheets.Add("Prediction Analysis Summary");
        var titleBg       = XLColor.FromArgb(0x1F, 0x49, 0x3B);
        var headerBg      = XLColor.FromArgb(0x1F, 0x49, 0x7D);
        var redItalic     = XLColor.FromArgb(0xC0, 0x00, 0x00);
        var boldRed       = XLColor.FromArgb(0xC0, 0x00, 0x00);

        const int totalMetricCols = 8;
        const int totalRatioCols  = 4;

        // ── Row 1: Title ──────────────────────────────────────────────────────
        ws.Cell(1, 1).Value = "Prediction vs Non-Payment Summary";
        ws.Range(1, 1, 1, totalMetricCols).Merge();
        ws.Cell(1, 1).Style.Font.Bold            = true;
        ws.Cell(1, 1).Style.Font.FontSize        = 14;
        ws.Cell(1, 1).Style.Font.FontColor       = XLColor.White;
        ws.Cell(1, 1).Style.Fill.BackgroundColor = titleBg;
        ws.Row(1).Height = 22;

        // ── Row 2: Cutoff note ────────────────────────────────────────────────
        ws.Cell(2, 1).Value = $"Disclaimer : Analysis cutoff - Expected Payment Date < {weekStart:MM/dd/yyyy} (start of current week)";
        ws.Cell(2, 1).Style.Font.Italic = true;
        ws.Range(2, 1, 2, totalMetricCols).Merge();

        // ════════════════════════════════════════════════════════════════════
        // METRICS TABLE  (row 4 header, rows 5-10 data)
        // ════════════════════════════════════════════════════════════════════

        // ── Row 4: Column headers ─────────────────────────────────────────────
        string[] metricHeaders =
        [
            "Metrics",
            "Claim Count (#)",
            "Predicted Allowed ($)",
            "Predicted Insurance Payment ($)",
            "Actual Allowed Amount ($)",
            "Actual Insurance Payment ($)",
            "Allowed Amount - Predicted Vs Actual ($)",
            "Insurance Paid - Predicted Vs Actual ($)"
        ];
        for (int c = 0; c < metricHeaders.Length; c++)
        {
            var cell = ws.Cell(4, c + 1);
            cell.Value = metricHeaders[c];
            cell.Style.Font.Bold            = true;
            cell.Style.Font.FontColor       = XLColor.White;
            cell.Style.Fill.BackgroundColor = headerBg;
            cell.Style.Alignment.WrapText   = true;
        }
        ws.Row(4).Height = 42;

        // ── Helper: write one metrics data row ───────────────────────────────
        // Variance cols (G, H) are computed here: PredAllowed-ActAllowed, PredIns-ActIns
        void MetricRow(
            int      row,
            string   label,
            int      count,
            decimal  predAllowed,
            decimal  predIns,
            decimal? actAllowed   = null,
            decimal? actIns       = null,
            bool     bold         = false,
            bool     italic       = false,
            XLColor? fontColor    = null)
        {
            ws.Cell(row, 1).Value = label;
            ws.Cell(row, 2).Value = count;
            ws.Cell(row, 3).Value = predAllowed;   ws.Cell(row, 3).Style.NumberFormat.Format = "$#,##0.00";
            ws.Cell(row, 4).Value = predIns;       ws.Cell(row, 4).Style.NumberFormat.Format = "$#,##0.00";

            if (actAllowed.HasValue)
            {
                ws.Cell(row, 5).Value = actAllowed.Value;
                ws.Cell(row, 5).Style.NumberFormat.Format = "$#,##0.00";

                ws.Cell(row, 6).Value = actIns!.Value;
                ws.Cell(row, 6).Style.NumberFormat.Format = "$#,##0.00";

                // G = Predicted Allowed - Actual Allowed
                ws.Cell(row, 7).Value = predAllowed - actAllowed.Value;
                ws.Cell(row, 7).Style.NumberFormat.Format = "$#,##0.00";

                // H = Predicted Insurance - Actual Insurance
                ws.Cell(row, 8).Value = predIns - actIns!.Value;
                ws.Cell(row, 8).Style.NumberFormat.Format = "$#,##0.00";
            }
            else
            {
                ws.Cell(row, 5).Value = "-";
                ws.Cell(row, 6).Value = "-";
                ws.Cell(row, 7).Value = "-";
                ws.Cell(row, 8).Value = "-";
            }

            for (int c = 1; c <= totalMetricCols; c++)
            {
                ws.Cell(row, c).Style.Font.Bold   = bold;
                ws.Cell(row, c).Style.Font.Italic = italic;
                if (fontColor != null)
                    ws.Cell(row, c).Style.Font.FontColor = fontColor;
            }
        }

        // Row 5: Predicted To Pay — no Actual cols
        MetricRow(5, "Predicted To Pay",
            s.TotalPredictedClaims,
            s.TotalPredictedAllowed,
            s.TotalPredictedInsurance,
            bold: true);

        // Row 6: Predicted - Paid — all 8 cols
        MetricRow(6, "Predicted - Paid",
            s.TotalPaidClaims,
            s.TotalPaidPredAllowed,
            s.TotalPaidPredInsurance,
            actAllowed: s.TotalPaidActualAllowed,
            actIns:     s.TotalPaidActualInsurance,
            bold: true);

        // Row 7: Predicted - Unpaid — all 8 cols
        MetricRow(7, "Predicted - Unpaid",
            s.TotalUnpaidClaims,
            s.TotalUnpaidPredAllowed,
            s.TotalUnpaidPredInsurance,
            actAllowed: s.TotalUnpaidActualAllowed,
            actIns:     s.TotalUnpaidActualInsurance,
            bold: true, fontColor: boldRed);

        // Row 8: Unpaid - Denied
        MetricRow(8, "Unpaid - Denied",
            s.DeniedClaims,
            s.DeniedPredAllowed,
            s.DeniedPredInsurance,
            actAllowed: s.DeniedActualAllowed,
            actIns:     s.DeniedActualInsurance,
            italic: true, fontColor: redItalic);

        // Row 9: Unpaid - No Response
        MetricRow(9, "Unpaid - No Response",
            s.NoResponseClaims,
            s.NoResponsePredAllowed,
            s.NoResponsePredInsurance,
            actAllowed: s.NoResponseActualAllowed,
            actIns:     s.NoResponseActualInsurance,
            italic: true, fontColor: redItalic);

        // Row 10: Unpaid - Adjusted
        MetricRow(10, "Unpaid - Adjusted",
            s.AdjustedClaims,
            s.AdjustedPredAllowed,
            s.AdjustedPredInsurance,
            actAllowed: s.AdjustedActualAllowed,
            actIns:     s.AdjustedActualInsurance,
            italic: true, fontColor: redItalic);

        ApplyThinBorder(ws.Range(4, 1, 10, totalMetricCols));

        // ════════════════════════════════════════════════════════════════════
        // RATIOS TABLE  (row 12 blank, row 13 header, rows 14-18 data)
        // ════════════════════════════════════════════════════════════════════

        // ── Row 15: Ratios header ─────────────────────────────────────────────
        string[] ratioHeaders =
        [
            "Ratios",
            "Claim (%)",
            "Predicted Allowed Amount (%)",
            "Predicted Insurance Payment (%)"
        ];
        for (int c = 0; c < ratioHeaders.Length; c++)
        {
            var cell = ws.Cell(15, c + 1);
            cell.Value = ratioHeaders[c];
            cell.Style.Font.Bold            = true;
            cell.Style.Font.FontColor       = XLColor.White;
            cell.Style.Fill.BackgroundColor = headerBg;
            cell.Style.Alignment.WrapText   = true;
        }
        ws.Row(15).Height = 30;

        // ── Helper: write one ratio row ───────────────────────────────────────
        void RatioRow(
            int      row,
            string   label,
            decimal  claimPct,
            decimal  allowedPct,
            decimal  insPct,
            bool     bold      = false,
            XLColor? fontColor = null)
        {
            ws.Cell(row, 1).Value = label;
            ws.Cell(row, 2).Value = $"{Math.Round(claimPct, 1)}%";
            ws.Cell(row, 3).Value = $"{Math.Round(allowedPct, 1)}%";
            ws.Cell(row, 4).Value = $"{Math.Round(insPct, 1)}%";

            for (int c = 1; c <= totalRatioCols; c++)
            {
                ws.Cell(row, c).Style.Font.Bold   = bold;
                ws.Cell(row, c).Style.Font.Italic = !bold;
                if (fontColor != null)
                    ws.Cell(row, c).Style.Font.FontColor = fontColor;
            }
        }

        RatioRow(16, "Payment Ratio (%)",
            s.PaymentRatioCount, s.PaymentRatioAllowed, s.PaymentRatioInsurance,
            fontColor: XLColor.FromArgb(0x37, 0x6B, 0x4E));

        RatioRow(17, "Non-Payment Rate (%)",
            s.NonPaymentRateCount, s.NonPaymentRateAllowed, s.NonPaymentRateInsurance,
            bold: true, fontColor: boldRed);

        RatioRow(18, "Denied (%)",
            s.DeniedRatioCount, s.DeniedRatioAllowed, s.DeniedRatioInsurance,
            fontColor: redItalic);

        RatioRow(19, "No Response (%)",
            s.NoResponseRatioCount, s.NoResponseRatioAllowed, s.NoResponseRatioInsurance,
            fontColor: redItalic);

        RatioRow(20, "Adjusted (%)",
            s.AdjustedRatioCount, s.AdjustedRatioAllowed, s.AdjustedRatioInsurance,
            fontColor: redItalic);

        ApplyThinBorder(ws.Range(15, 1, 20, totalRatioCols));

        // ════════════════════════════════════════════════════════════════════
        // PREDICTION ACCURACY TABLE  (row 23 header, row 24 data)
        // ════════════════════════════════════════════════════════════════════

        string[] accHeaders =
        [
            "Prediction Accuracy",
            "Claim (%)",
            "Prediction vs Actuals - Allowed Amount (%)",
            "Prediction vs Actuals - Insurance Payment (%)"
        ];
        for (int c = 0; c < accHeaders.Length; c++)
        {
            var cell = ws.Cell(23, c + 1);
            cell.Value = accHeaders[c];
            cell.Style.Font.Bold            = true;
            cell.Style.Font.FontColor       = XLColor.White;
            cell.Style.Fill.BackgroundColor = headerBg;
            cell.Style.Alignment.WrapText   = true;
        }
        ws.Row(23).Height = 30;

        ws.Cell(24, 1).Value = "Predicted Vs Actuals Ratio";
        ws.Cell(24, 2).Value = $"{Math.Round(s.PredVsActualRatioCount, 1)}%";
        ws.Cell(24, 3).Value = $"{Math.Round(s.PredVsActualRatioAllowed, 1)}%";
        ws.Cell(24, 4).Value = $"{Math.Round(s.PredVsActualRatioInsurance, 1)}%";
        ws.Cell(24, 1).Style.Font.Italic = true;

        ApplyThinBorder(ws.Range(23, 1, 24, totalRatioCols));

        // ── Column widths ─────────────────────────────────────────────────────
        ws.Column(1).Width = 32;  // Metrics label
        ws.Column(2).Width = 16;  // Claim Count
        ws.Column(3).Width = 24;  // Predicted Allowed
        ws.Column(4).Width = 28;  // Predicted Insurance Payment
        ws.Column(5).Width = 24;  // Actual Allowed Amount
        ws.Column(6).Width = 26;  // Actual Insurance Payment
        ws.Column(7).Width = 30;  // Allowed Amount Variance
        ws.Column(8).Width = 30;  // Insurance Paid Variance
    }

    // ── Sheet 2: Forecasting Prediction Vs Denial Breakdown ──────────────────
    private static void WriteSheet2_DenialPivot(XLWorkbook wb, DenialPivotResult pivot)
    {
        var ws = wb.Worksheets.Add("Predicted to Pay Vs Denial");

        var months    = pivot.AllMonths;
        // 3 sub-columns per month (Count, Allowed, Insurance) + 3 for Total
        int totalCols = 1 + months.Count * 3 + 3;

        // ── Row 1: Sheet title ────────────────────────────────────────────────
        ws.Cell(1, 1).Value = "Forecasting Prediction Vs Denial Breakdown";
        ws.Range(1, 1, 1, totalCols).Merge();
        StyleCell(ws.Cell(1, 1), DarkGreen, White, 13, bold: true);
        ws.Row(1).Height = 20;

        // ── Row 2: Summary sub-title ──────────────────────────────────────────
        ws.Cell(2, 2).Value = "Predicted Vs Denial Summary";
        ws.Range(2, 2, 2, totalCols).Merge();
        StyleCell(ws.Cell(2, 2), MidGreen, White, 11, bold: true);
        StyleCell(ws.Cell(2, 1), MidGreen, White, 11, bold: false);  // fill col 1 — no white gap
        ws.Cell(2, 1).Value = string.Empty;

        // ── Row 3: Payer Name header + Month group headers ────────────────────
        ws.Cell(3, 1).Value = "Payer Name";
        StyleCell(ws.Cell(3, 1), DarkGreen, White, 10, bold: true);
        ws.Range(3, 1, 4, 1).Merge();

        int col = 2;
        foreach (var month in months)
        {
            ws.Cell(3, col).Value = month;
            ws.Range(3, col, 3, col + 2).Merge();       // span 3 sub-cols
            StyleCell(ws.Cell(3, col), MidGreen, White, 10, bold: true);
            ws.Cell(3, col).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            col += 3;
        }
        ws.Cell(3, col).Value = "Total";
        ws.Range(3, col, 3, col + 2).Merge();            // span 3 sub-cols
        StyleCell(ws.Cell(3, col), DarkGreen, White, 10, bold: true);
        ws.Cell(3, col).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        // ── Row 4: Sub-column labels ──────────────────────────────────────────
        col = 2;
        foreach (var _ in months)
        {
            ws.Cell(4, col).Value     = "Claim Count";
            ws.Cell(4, col + 1).Value = "Predicted Allowed Amount ($)";
            ws.Cell(4, col + 2).Value = "Predicted Insurance Payment ($)";
            StyleCell(ws.Cell(4, col),     SubGreen, White, 9, bold: true);
            StyleCell(ws.Cell(4, col + 1), SubGreen, White, 9, bold: true);
            StyleCell(ws.Cell(4, col + 2), SubGreen, White, 9, bold: true);
            ws.Cell(4, col + 1).Style.Alignment.WrapText = true;
            ws.Cell(4, col + 2).Style.Alignment.WrapText = true;
            col += 3;
        }
        ws.Cell(4, col).Value     = "Claim Count";
        ws.Cell(4, col + 1).Value = "Predicted Allowed Amount ($)";
        ws.Cell(4, col + 2).Value = "Predicted Insurance Payment ($)";
        StyleCell(ws.Cell(4, col),     DarkGreen, White, 9, bold: true);
        StyleCell(ws.Cell(4, col + 1), DarkGreen, White, 9, bold: true);
        StyleCell(ws.Cell(4, col + 2), DarkGreen, White, 9, bold: true);
        ws.Cell(4, col + 1).Style.Alignment.WrapText = true;
        ws.Cell(4, col + 2).Style.Alignment.WrapText = true;
        ws.Row(4).Height = 30;

        // ── Data rows ─────────────────────────────────────────────────────────
        int row = 5;
        foreach (var payer in pivot.OrderedPayers)
        {
            var codes = pivot.TopCodesByPayer.TryGetValue(payer, out var c) ? c : [];

            // ── Payer header row ──────────────────────────────────────────────
            ws.Cell(row, 1).Value                      = payer;
            ws.Cell(row, 1).Style.Font.Bold            = true;
            ws.Cell(row, 1).Style.Fill.BackgroundColor = PayerRowBg;
            ws.Cell(row, 1).Style.Font.FontSize        = 10;

            col = 2;
            foreach (var month in months)
            {
                int     mCount   = codes.Sum(code => pivot.CellData.TryGetValue((payer, code, month), out var cell) ? cell.ClaimCount       : 0);
                decimal mAllowed = codes.Sum(code => pivot.CellData.TryGetValue((payer, code, month), out var cell) ? cell.Amount            : 0m);
                decimal mInsurance = codes.Sum(code => pivot.CellData.TryGetValue((payer, code, month), out var cell) ? cell.InsuranceAmount  : 0m);

                ws.Cell(row, col).Value                      = mCount;
                ws.Cell(row, col).Style.Font.Bold            = true;
                ws.Cell(row, col).Style.Fill.BackgroundColor = PayerRowBg;

                ws.Cell(row, col + 1).Value                      = mAllowed;
                ws.Cell(row, col + 1).Style.NumberFormat.Format  = "$#,##0.00";
                ws.Cell(row, col + 1).Style.Font.Bold            = true;
                ws.Cell(row, col + 1).Style.Fill.BackgroundColor = PayerRowBg;

                ws.Cell(row, col + 2).Value                      = mInsurance;
                ws.Cell(row, col + 2).Style.NumberFormat.Format  = "$#,##0.00";
                ws.Cell(row, col + 2).Style.Font.Bold            = true;
                ws.Cell(row, col + 2).Style.Fill.BackgroundColor = PayerRowBg;

                col += 3;
            }

            pivot.PayerTotals.TryGetValue(payer, out var pt);
            ws.Cell(row, col).Value                          = pt?.ClaimCount      ?? 0;
            ws.Cell(row, col).Style.Font.Bold                = true;
            ws.Cell(row, col).Style.Fill.BackgroundColor     = PayerRowBg;

            ws.Cell(row, col + 1).Value                          = pt?.Amount         ?? 0m;
            ws.Cell(row, col + 1).Style.NumberFormat.Format      = "$#,##0.00";
            ws.Cell(row, col + 1).Style.Font.Bold                = true;
            ws.Cell(row, col + 1).Style.Fill.BackgroundColor     = PayerRowBg;

            ws.Cell(row, col + 2).Value                          = pt?.InsuranceAmount ?? 0m;
            ws.Cell(row, col + 2).Style.NumberFormat.Format      = "$#,##0.00";
            ws.Cell(row, col + 2).Style.Font.Bold                = true;
            ws.Cell(row, col + 2).Style.Fill.BackgroundColor     = PayerRowBg;

            row++;

            // ── Denial code child rows ────────────────────────────────────────
            foreach (var code in codes)
            {
                ws.Cell(row, 1).Value                  = code;
                ws.Cell(row, 1).Style.Alignment.Indent = 2;

                col = 2;
                foreach (var month in months)
                {
                    pivot.CellData.TryGetValue((payer, code, month), out var cell);
                    ws.Cell(row, col).Value     = cell?.ClaimCount       ?? 0;
                    ws.Cell(row, col + 1).Value = cell?.Amount           ?? 0m;
                    ws.Cell(row, col + 1).Style.NumberFormat.Format = "$#,##0.00";
                    ws.Cell(row, col + 2).Value = cell?.InsuranceAmount  ?? 0m;
                    ws.Cell(row, col + 2).Style.NumberFormat.Format = "$#,##0.00";
                    col += 3;
                }

                pivot.CodeTotals.TryGetValue((payer, code), out var ct);
                ws.Cell(row, col).Value                          = ct?.ClaimCount      ?? 0;
                ws.Cell(row, col).Style.Font.Bold                = true;
                ws.Cell(row, col).Style.Fill.BackgroundColor     = PayerRowBg;

                ws.Cell(row, col + 1).Value                          = ct?.Amount         ?? 0m;
                ws.Cell(row, col + 1).Style.NumberFormat.Format      = "$#,##0.00";
                ws.Cell(row, col + 1).Style.Font.Bold                = true;
                ws.Cell(row, col + 1).Style.Fill.BackgroundColor     = PayerRowBg;

                ws.Cell(row, col + 2).Value                          = ct?.InsuranceAmount ?? 0m;
                ws.Cell(row, col + 2).Style.NumberFormat.Format      = "$#,##0.00";
                ws.Cell(row, col + 2).Style.Font.Bold                = true;
                ws.Cell(row, col + 2).Style.Fill.BackgroundColor     = PayerRowBg;

                ApplyThinBorder(ws.Range(row, 1, row, totalCols));
                row++;
            }
        }

        // ── Column widths ─────────────────────────────────────────────────────
        ws.Column(1).Width = 22;
        for (int c = 2; c <= totalCols; c++)
        {
            // Pattern repeats every 3: Count=10, Allowed=20, Insurance=22
            int offset = (c - 2) % 3;
            ws.Column(c).Width = offset == 0 ? 10 : offset == 1 ? 20 : 22;
        }

        ws.SheetView.FreezeRows(4);
    }

    // ── Sheet 3: No Response Aging ────────────────────────────────────────────
    private static void WriteSheet3_NoResponseAging(XLWorkbook wb, List<AgingPivotRow> aging)
    {
        var ws = wb.Worksheets.Add("Predicted to Pay Vs No Response");

        // 3 sub-cols per bucket × 5 buckets + Payer + Total(3) + Priority
        // Col layout: 1=Payer | 2,3,4=0-30 | 5,6,7=31-60 | 8,9,10=61-90 |
        //             11,12,13=91-120 | 14,15,16=>120 | 17,18,19=Total | 20=Priority
        const int bucketCols  = 3;   // Count, Allowed, Insurance per bucket
        const int bucketCount = 5;
        const int totalColIdx = 1 + bucketCols * bucketCount + 1;  // col 17
        const int priColIdx   = totalColIdx + bucketCols;           // col 20
        const int totalCols   = priColIdx;

        var headerBg = XLColor.FromArgb(0x2E, 0x5E, 0x8E);

        // ── Row 1: Filter description ─────────────────────────────────────────
        ws.Cell(1, 1).Value = "Source :";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(1, 2).Value = "Prediction - UnPaid";
        ws.Range(1, 2, 1, totalCols).Merge();
        ws.Cell(1, 2).Style.Font.Bold = true;

        // ── Row 2: Sort description ───────────────────────────────────────────
        //ws.Cell(2, 1).Value = "Sort Table Values By:";
        ws.Cell(2, 1).Value = " ";
        ws.Cell(2, 1).Style.Font.Bold = true;
        //ws.Cell(2, 2).Value = "Sort Table Value By: Claim Count";
        ws.Cell(2, 2).Value = " ";
        ws.Range(2, 2, 2, totalCols).Merge();
        ws.Cell(2, 2).Style.Font.Bold = true;

        // ── Row 3: blank ──────────────────────────────────────────────────────

        // ── Row 4: Full-width title — spans ALL columns including Priority ────────
        //          Must be written BEFORE any sub-headers in rows 5/6 to avoid merge conflicts
        ws.Cell(4, 1).Value = "Predicted to Pay Vs No Response Breakdown";
        ws.Range(4, 1, 4, totalCols).Merge();
        StyleCell(ws.Cell(4, 1), DarkGreen, White, 11, bold: true);
        ws.Cell(4, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Cell(4, 1).Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
        ws.Row(4).Height = 22;

        // ── Row 5: Payer Name | Bucket group labels | TOTAL | Priority ──────────
        ws.Cell(5, 1).Value = "Payer Name";
        ws.Range(5, 1, 6, 1).Merge();
        StyleCell(ws.Cell(5, 1), DarkGreen, White, 10, bold: true);
        ws.Cell(5, 1).Style.Alignment.Vertical   = XLAlignmentVerticalValues.Center;
        ws.Cell(5, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        var bucketLabels = new[] { "0-30", "31-60", "61-90", "91-120", ">120" };
        for (int b = 0; b < bucketCount; b++)
        {
            int startCol = 2 + b * bucketCols;
            ws.Cell(5, startCol).Value = bucketLabels[b];
            ws.Range(5, startCol, 5, startCol + bucketCols - 1).Merge();
            StyleCell(ws.Cell(5, startCol), DarkGreen, White, 10, bold: true);
            ws.Cell(5, startCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // ── Row 6: Sub-column labels ──────────────────────────────────────────
        for (int b = 0; b < bucketCount; b++)
        {
            int sc = 2 + b * bucketCols;
            ws.Cell(6, sc).Value     = "Claim Count";
            ws.Cell(6, sc + 1).Value = "Predicted Allowed Amount ($)";
            ws.Cell(6, sc + 2).Value = "Predicted Insurance Payments ($)";
            StyleCell(ws.Cell(6, sc),     DarkGreen, White, 9, bold: true);
            StyleCell(ws.Cell(6, sc + 1), DarkGreen, White, 9, bold: true);
            StyleCell(ws.Cell(6, sc + 2), DarkGreen, White, 9, bold: true);
            ws.Cell(6, sc + 1).Style.Alignment.WrapText = true;
            ws.Cell(6, sc + 2).Style.Alignment.WrapText = true;
        }
        // Total sub-cols on row 6
        ws.Cell(6, totalColIdx).Value     = "Claim Count";
        ws.Cell(6, totalColIdx + 1).Value = "Predicted Allowed Amount ($)";
        ws.Cell(6, totalColIdx + 2).Value = "Predicted Insurance Payments ($)";
        StyleCell(ws.Cell(6, totalColIdx),     DarkGreen, White, 9, bold: true);
        StyleCell(ws.Cell(6, totalColIdx + 1), DarkGreen, White, 9, bold: true);
        StyleCell(ws.Cell(6, totalColIdx + 2), DarkGreen, White, 9, bold: true);
        ws.Cell(6, totalColIdx + 1).Style.Alignment.WrapText = true;
        ws.Cell(6, totalColIdx + 2).Style.Alignment.WrapText = true;
        ws.Row(6).Height = 40;

        // ── Data rows ─────────────────────────────────────────────────────────
        int row = 7;
        foreach (var a in aging)
        {
            ws.Cell(row, 1).Value = a.PayerName;

            // Write each bucket's data (Count, Allowed, Insurance) to correct columns
            // Using direct column assignments instead of array
            
            // 0-30
            if (a.Bucket0_30 > 0) ws.Cell(row, 2).Value = a.Bucket0_30;
            if (a.AmountBucket0_30 > 0) { ws.Cell(row, 3).Value = a.AmountBucket0_30; ws.Cell(row, 3).Style.NumberFormat.Format = "$#,##0.00"; }
            if (a.InsuranceBucket0_30 > 0) { ws.Cell(row, 4).Value = a.InsuranceBucket0_30; ws.Cell(row, 4).Style.NumberFormat.Format = "$#,##0.00"; }
            
            // 31-60
            if (a.Bucket31_60 > 0) ws.Cell(row, 5).Value = a.Bucket31_60;
            if (a.AmountBucket31_60 > 0) { ws.Cell(row, 6).Value = a.AmountBucket31_60; ws.Cell(row, 6).Style.NumberFormat.Format = "$#,##0.00"; }
            if (a.InsuranceBucket31_60 > 0) { ws.Cell(row, 7).Value = a.InsuranceBucket31_60; ws.Cell(row, 7).Style.NumberFormat.Format = "$#,##0.00"; }
            
            // 61-90
            if (a.Bucket61_90 > 0) ws.Cell(row, 8).Value = a.Bucket61_90;
            if (a.AmountBucket61_90 > 0) { ws.Cell(row, 9).Value = a.AmountBucket61_90; ws.Cell(row, 9).Style.NumberFormat.Format = "$#,##0.00"; }
            if (a.InsuranceBucket61_90 > 0) { ws.Cell(row, 10).Value = a.InsuranceBucket61_90; ws.Cell(row, 10).Style.NumberFormat.Format = "$#,##0.00"; }
            
            // 91-120
            if (a.Bucket91_120 > 0) ws.Cell(row, 11).Value = a.Bucket91_120;
            if (a.AmountBucket91_120 > 0) { ws.Cell(row, 12).Value = a.AmountBucket91_120; ws.Cell(row, 12).Style.NumberFormat.Format = "$#,##0.00"; }
            if (a.InsuranceBucket91_120 > 0) { ws.Cell(row, 13).Value = a.InsuranceBucket91_120; ws.Cell(row, 13).Style.NumberFormat.Format = "$#,##0.00"; }
            
            // >120
            if (a.Bucket121Plus > 0) ws.Cell(row, 14).Value = a.Bucket121Plus;
            if (a.AmountBucket121Plus > 0) { ws.Cell(row, 15).Value = a.AmountBucket121Plus; ws.Cell(row, 15).Style.NumberFormat.Format = "$#,##0.00"; }
            if (a.InsuranceBucket121Plus > 0) { ws.Cell(row, 16).Value = a.InsuranceBucket121Plus; ws.Cell(row, 16).Style.NumberFormat.Format = "$#,##0.00"; }

            // Total
            ws.Cell(row, totalColIdx).Value                        = a.Total;
            ws.Cell(row, totalColIdx).Style.Font.Bold              = true;
            ws.Cell(row, totalColIdx).Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Center;
            ws.Cell(row, totalColIdx + 1).Value                    = a.TotalAmount;
            ws.Cell(row, totalColIdx + 1).Style.NumberFormat.Format= "$#,##0.00";
            ws.Cell(row, totalColIdx + 1).Style.Font.Bold          = true;
            ws.Cell(row, totalColIdx + 2).Value                    = a.TotalInsurance;
            ws.Cell(row, totalColIdx + 2).Style.NumberFormat.Format= "$#,##0.00";
            ws.Cell(row, totalColIdx + 2).Style.Font.Bold          = true;

            // Priority
            var priorityCell = ws.Cell(row, priColIdx);
            priorityCell.Value = a.PriorityLevel;
            priorityCell.Style.Font.Bold              = true;
            priorityCell.Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Center;

            var (bg, fg) = a.PriorityLevel switch
            {
                "Monitor"                      => (XLColor.FromArgb(0xE2, 0xEF, 0xDA), XLColor.FromArgb(0x37, 0x6B, 0x4E)),
                "Follow-Up Required"           => (XLColor.FromArgb(0xFF, 0xFF, 0xCC), XLColor.FromArgb(0x7B, 0x6D, 0x00)),
                "Escalate"                     => (XLColor.FromArgb(0xFF, 0xE0, 0xB2), XLColor.FromArgb(0x7B, 0x3B, 0x00)),
                "Urgent Review"                => (XLColor.FromArgb(0xFF, 0xCC, 0xBC), XLColor.FromArgb(0x6D, 0x1F, 0x00)),
                "Critical / Timely Filing Risk"=> (XLColor.FromArgb(0xE0, 0x30, 0x00), XLColor.White),
                _                              => (XLColor.White, XLColor.Black)
            };
            priorityCell.Style.Fill.BackgroundColor = bg;
            priorityCell.Style.Font.FontColor       = fg;

            ws.Range(row, 1, row, totalCols).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            row++;
        }

        // ── Total row ─────────────────────────────────────────────────────────
        ws.Cell(row, 1).Value = "Total";    
        ws.Cell(row, 1).Style.Font.Bold = true;

        int[] bucketStartCols = [2, 5, 8, 11, 14];
        int[] counts   = [
            aging.Sum(a => a.Bucket0_30),   aging.Sum(a => a.Bucket31_60),
            aging.Sum(a => a.Bucket61_90),  aging.Sum(a => a.Bucket91_120),
            aging.Sum(a => a.Bucket121Plus)];
        decimal[] amounts = [
            aging.Sum(a => a.AmountBucket0_30),   aging.Sum(a => a.AmountBucket31_60),
            aging.Sum(a => a.AmountBucket61_90),  aging.Sum(a => a.AmountBucket91_120),
            aging.Sum(a => a.AmountBucket121Plus)];
        decimal[] insurances = [
            aging.Sum(a => a.InsuranceBucket0_30),   aging.Sum(a => a.InsuranceBucket31_60),
            aging.Sum(a => a.InsuranceBucket61_90),  aging.Sum(a => a.InsuranceBucket91_120),
            aging.Sum(a => a.InsuranceBucket121Plus)];

        for (int b = 0; b < bucketCount; b++)
        {
            int sc = bucketStartCols[b];
            ws.Cell(row, sc).Value                        = counts[b];
            ws.Cell(row, sc).Style.Font.Bold              = true;
            ws.Cell(row, sc).Style.Alignment.Horizontal   = XLAlignmentHorizontalValues.Center;
            ws.Cell(row, sc + 1).Value                    = amounts[b];
            ws.Cell(row, sc + 1).Style.NumberFormat.Format      = "$#,##0.00";
            ws.Cell(row, sc + 1).Style.Font.Bold          = true;
            ws.Cell(row, sc + 2).Value                    = insurances[b];
            ws.Cell(row, sc + 2).Style.NumberFormat.Format      = "$#,##0.00";
            ws.Cell(row, sc + 2).Style.Font.Bold          = true;
        }

        ws.Cell(row, totalColIdx).Value                         = aging.Sum(a => a.Total);
        ws.Cell(row, totalColIdx).Style.Font.Bold               = true;
        ws.Cell(row, totalColIdx).Style.Alignment.Horizontal    = XLAlignmentHorizontalValues.Center;
        ws.Cell(row, totalColIdx + 1).Value                     = aging.Sum(a => a.TotalAmount);
        ws.Cell(row, totalColIdx + 1).Style.NumberFormat.Format = "$#,##0.00";
        ws.Cell(row, totalColIdx + 1).Style.Font.Bold           = true;
        ws.Cell(row, totalColIdx + 2).Value                     = aging.Sum(a => a.TotalInsurance);
        ws.Cell(row, totalColIdx + 2).Style.NumberFormat.Format = "$#,##0.00";
        ws.Cell(row, totalColIdx + 2).Style.Font.Bold           = true;

        ws.Range(row, 1, row, totalCols).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        ws.Range(row, 1, row, totalCols).Style.Fill.BackgroundColor = XLColor.FromArgb(0xD6, 0xE4, 0xF0);       

        ws.Range(4, 1, row, totalCols).Style.Border.OutsideBorder = XLBorderStyleValues.Medium;

        // ── Column widths ─────────────────────────────────────────────────────
        ws.Column(1).Width = 32;  // Payer Name
        for (int b = 0; b < bucketCount; b++)
        {
            int sc = 2 + b * bucketCols;
            ws.Column(sc).Width     = 10;  // Count
            ws.Column(sc + 1).Width = 22;  // Allowed
            ws.Column(sc + 2).Width = 24;  // Insurance
        }
        ws.Column(totalColIdx).Width     = 10;
        ws.Column(totalColIdx + 1).Width = 22;
        ws.Column(totalColIdx + 2).Width = 24;
        ws.Column(priColIdx).Width       = 28;

        ws.SheetView.FreezeRows(6);
    }

    // ── Sheet 4: Analyst Notes ────────────────────────────────────────────────
    private static void WriteSheet4_AnalystNotes(XLWorkbook wb, string sourceFilePath, DateTime weekStart)
    {
        var ws = wb.Worksheets.Add("Legend");

        WriteHeaderRow(ws, 1, "Field", "Value");
        ws.Cell(2, 1).Value = "Report Generated";
        ws.Cell(2, 2).Value = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        ws.Cell(3, 1).Value = "Source File";
        ws.Cell(3, 2).Value = sourceFilePath;
        ws.Cell(4, 1).Value = "Analysis Date Cutoff";
        ws.Cell(4, 2).Value = $"Expected Payment Date < {weekStart:MM/dd/yyyy} (Monday of current week)";
        ws.Cell(5, 1).Value = "Run By (Analyst Name)";
        ws.Cell(5, 2).Value = string.Empty;
        ws.Cell(6, 1).Value = "Observations / Notes";
        ws.Cell(6, 2).Value = string.Empty;
        ws.Cell(7, 1).Value = "Follow-Up Actions";
        ws.Cell(7, 2).Value = string.Empty;
        ws.Cell(8, 1).Value = "Escalations Required";
        ws.Cell(8, 2).Value = string.Empty;

        ws.Column(1).Width = 28;
        ws.Column(2).Width = 80;
        ws.Column(2).Style.Alignment.WrapText = true;
    }

    // ── Sheet 5: Predicted Payable Source Data ────────────────────────────────
    private static void WriteSheet5_PredictedSourceData(
        XLWorkbook wb,
        List<ClaimRecord> predicted)
    {
        var ws = wb.Worksheets.Add("Predicted Payable DataSheet");
        WriteUnpaidSourceBlock(ws, predicted,
            "Predicted Payable (All Forecasting Payable Included — Cutoff Filtered)",
            appendAgeColumns: false);
        ws.SheetView.FreezeRows(2);
    }

    // ── Sheet 6: Unpaid Working Dataset ──────────────────────────────────────
    private static void WriteSheet6_UnpaidWorkingData(
        XLWorkbook wb,
        List<ClaimRecord> working)
    {
        var ws = wb.Worksheets.Add("Unpaid Working Dataset");
        WriteUnpaidSourceBlock(ws, working,
            "Unpaid Working Dataset (Denied + Adjusted + No Response)",
            appendAgeColumns: true);
        ws.SheetView.FreezeRows(2);
    }

    /// <summary>
    /// Same as WriteRawSourceBlock but appends two calculated columns:
    ///   • Today to Expected Payment Date  (days: Today − ExpectedPaymentDate)
    ///   • Age Group                       (0-30 / 31-60 / 61-90 / 91-120 / >120)
    /// </summary>
    private static void WriteUnpaidSourceBlock(
        IXLWorksheet ws,
        List<ClaimRecord> records,
        string sectionTitle,
        bool appendAgeColumns = false)
    {
        if (records.Count == 0)
        {
            ws.Cell(1, 1).Value = sectionTitle + " — No records.";
            return;
        }

        var headers  = records[0].SourceHeaders;
        int srcCols  = headers.Count;
        int colCount = appendAgeColumns ? srcCols + 2 : srcCols;
        int daysCol  = srcCols + 1;
        int aggrCol  = srcCols + 2;

        // ── Row 1: section title — use same blue as column headers ───────────
        ws.Cell(1, 1).Value = sectionTitle;
        ws.Range(1, 1, 1, colCount).Merge();
        StyleCell(ws.Cell(1, 1), HeaderBg, White, 11, bold: true);
        ws.Row(1).Height = 18;

        // ── Row 2: headers ────────────────────────────────────────────────────
        for (int c = 0; c < headers.Count; c++)
        {
            var cell = ws.Cell(2, c + 1);
            cell.Value = headers[c];
            StyleCell(cell, HeaderBg, HeaderFont, 10, bold: true);
            cell.Style.Alignment.WrapText = true;
        }

        // Extra header: Today to Expected Payment Date
        if (appendAgeColumns)
        {
            var daysHeader = ws.Cell(2, daysCol);
            daysHeader.Value = "Today to Expected Payment Date";
            StyleCell(daysHeader, HeaderBg, HeaderFont, 10, bold: true);  // same as other headers
            daysHeader.Style.Alignment.WrapText = true;

            // Extra header: Age Group
            var aggrHeader = ws.Cell(2, aggrCol);
            aggrHeader.Value = "Age Group";
            StyleCell(aggrHeader, HeaderBg, HeaderFont, 10, bold: true);  // same as other headers
            aggrHeader.Style.Alignment.WrapText = true;
        }

        ws.Row(2).Height = 30;

        // ── Data rows ─────────────────────────────────────────────────────────
        int dataRow = 3;
        foreach (var r in records)
        {
            // Source columns
            for (int c = 0; c < headers.Count; c++)
            {
                var header = headers[c];
                var cell   = ws.Cell(dataRow, c + 1);

                if (r.RawColumns.TryGetValue(header, out var raw) && !string.IsNullOrEmpty(raw))
                {
                    // ── Date columns: parse and write as DateTime with MM/DD/YYYY format ──
                    bool isDateCol = header.Contains("Date",  StringComparison.OrdinalIgnoreCase)
                                  || header.Contains("DOB",   StringComparison.OrdinalIgnoreCase);

                    if (isDateCol && DateTime.TryParse(raw,
                            System.Globalization.CultureInfo.InvariantCulture,
                            System.Globalization.DateTimeStyles.None, out var dt))
                    {
                        cell.Value = dt.Date;
                        cell.Style.NumberFormat.Format = "MM/DD/YYYY";
                    }
                    else if (decimal.TryParse(raw,
                            System.Globalization.NumberStyles.Any,
                            System.Globalization.CultureInfo.InvariantCulture,
                            out var num))
                    {
                        cell.Value = num;
                        if (header.Contains("Amount",   StringComparison.OrdinalIgnoreCase) ||
                            header.Contains("Payment",  StringComparison.OrdinalIgnoreCase) ||
                            header.Contains("Balance",  StringComparison.OrdinalIgnoreCase) ||
                            header.Contains("Billed",   StringComparison.OrdinalIgnoreCase) ||
                            header.Contains("Fee",      StringComparison.OrdinalIgnoreCase))
                            cell.Style.NumberFormat.Format = "$#,##0.00";
                    }
                    else
                    {
                        cell.Value = raw;
                    }
                }
            }

            // ── Age columns (Unpaid sheet only) ───────────────────────────────
            if (appendAgeColumns)
            {
                // Today to Expected Payment Date
                var daysCell = ws.Cell(dataRow, daysCol);
                if (r.ExpectedPaymentDate.HasValue)
                {
                    daysCell.Value = r.DaysSinceExpectedPayment;
                    daysCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
                }

                // Age Group — plain text, no colour fill
                var aggrCell = ws.Cell(dataRow, aggrCol);
                if (!string.IsNullOrEmpty(r.AgeGroup))
                {
                    aggrCell.Value = r.AgeGroup;
                    aggrCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
                }
            }

            dataRow++;
        }

        // ── Total row ─────────────────────────────────────────────────────────
        int claimCount      = records.Select(r => r.VisitNumber).Distinct().Count();
        decimal expectedPmt = records.Sum(r => r.ModeAllowedAmount);

        ws.Range(dataRow, 1, dataRow, colCount).Style.Fill.BackgroundColor = SectionBg;
        ws.Cell(dataRow, 1).Value = $"TOTAL  |  Unique Visit #: {claimCount}";
        ws.Range(dataRow, 1, dataRow, colCount - 1).Merge();
        ws.Cell(dataRow, 1).Style.Font.Bold = true;
        ws.Cell(dataRow, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        ws.Cell(dataRow, colCount).Value = expectedPmt;
        ws.Cell(dataRow, colCount).Style.NumberFormat.Format = "$#,##0.00";
        ws.Cell(dataRow, colCount).Style.Font.Bold = true;

        ApplyThinBorder(ws.Range(2, 1, dataRow, colCount));

        // ── Column widths ─────────────────────────────────────────────────────
        for (int c = 1; c <= srcCols; c++)
            ws.Column(c).Width = 18;

        for (int c = 0; c < headers.Count; c++)
        {
            var h   = headers[c];
            int col = c + 1;
            if (h.Contains("Description", StringComparison.OrdinalIgnoreCase) ||
                h.Contains("Remark",      StringComparison.OrdinalIgnoreCase) ||
                h.Contains("Comment",     StringComparison.OrdinalIgnoreCase) ||
                h.Contains("Resolution",  StringComparison.OrdinalIgnoreCase) ||
                h.Contains("ICD",         StringComparison.OrdinalIgnoreCase) ||
                h.Contains("Policy",      StringComparison.OrdinalIgnoreCase))
                ws.Column(col).Width = 35;
            else if (h.Contains("Name",  StringComparison.OrdinalIgnoreCase) ||
                     h.Contains("Payer", StringComparison.OrdinalIgnoreCase))
                ws.Column(col).Width = 26;
            else if (h.Contains("Date",  StringComparison.OrdinalIgnoreCase) ||
                     h.Contains("Month", StringComparison.OrdinalIgnoreCase))
                ws.Column(col).Width = 18;
        }

        // Fixed widths for the two new columns (Unpaid sheet only)
        if (appendAgeColumns)
        {
            ws.Column(daysCol).Width = 20;
            ws.Column(aggrCol).Width = 14;
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static void StyleCell(IXLCell cell, XLColor bg, XLColor fg,
        double fontSize = 10, bool bold = false)
    {
        cell.Style.Fill.BackgroundColor = bg;
        cell.Style.Font.FontColor = fg;
        cell.Style.Font.FontSize = fontSize;
        cell.Style.Font.Bold = bold;
    }

    private static void ApplyThinBorder(IXLRange range)
    {
        range.Style.Border.TopBorder = XLBorderStyleValues.Thin;
        range.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
    }

    private static void WriteSectionTitle(IXLWorksheet ws, int row, int span, string title)
    {
        ws.Cell(row, 1).Value = title;
        ws.Range(row, 1, row, span).Merge();
        ws.Cell(row, 1).Style.Font.Bold = true; 
        ws.Cell(row, 1).Style.Font.FontSize = 12;
        ws.Cell(row, 1).Style.Fill.BackgroundColor = SectionBg;
    }

    private static void WriteHeaderRow(IXLWorksheet ws, int row, params string[] headers)
    {
        for (int col = 0; col < headers.Length; col++)
        {
            var cell = ws.Cell(row, col + 1);
            cell.Value = headers[col];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = HeaderFont;
            cell.Style.Fill.BackgroundColor = HeaderBg;
        }
    }

    private static void WriteDataRow(IXLWorksheet ws, int row, params string[] values)
    {
        for (int col = 0; col < values.Length; col++)
            ws.Cell(row, col + 1).Value = values[col];
    }
}


