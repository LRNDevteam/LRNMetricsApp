using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Prediction Analysis data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces sheets: Prediction Buckets, Summary Metrics, Payer Insights,
/// Panel Insights, CPT Insights, Denial Breakdown, and No Response Breakdown.
/// </summary>
public static class PredictionExcelExportBuilder
{
    /// <summary>Creates the workbook from the Prediction Analysis view model.</summary>
    public static XLWorkbook CreateWorkbook(PredictionAnalysisViewModel vm, string labName,
        IReadOnlyList<(string Label, string? Value)>? activeFilters = null)
    {
        var wb = new XLWorkbook();

        BuildBucketsSheet(wb, vm, labName);
        BuildSummaryMetricsSheet(wb, vm.SummaryMetrics);
        BuildPayerInsightsSheet(wb, vm.TopPayerInsights);
        BuildPanelInsightsSheet(wb, vm.TopPanelInsights);
        BuildCptInsightsSheet(wb, vm.TopCptInsights);
        BuildBreakdownSheet(wb, vm);

        if (vm.DenialBreakdown.PayerRows.Count > 0)
            BuildDenialBreakdownSheet(wb, vm.DenialBreakdown);

        if (vm.NoResponseBreakdown.PayerRows.Count > 0)
            BuildNoResponseSheet(wb, vm.NoResponseBreakdown);

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 7, activeFilters);
        }

        return wb;
    }

    // ?? Prediction Buckets sheet ????????????????????????????????????????

    private static void BuildBucketsSheet(XLWorkbook wb, PredictionAnalysisViewModel vm, string labName)
    {
        var ws = wb.AddWorksheet("Prediction Buckets");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Bucket", "Claim Count", "Predicted Allowed", "Predicted Insurance",
                            "Actual Allowed", "Actual Insurance", "Variance"];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"Prediction Buckets | {labName}");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < vm.Buckets.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var b = vm.Buckets[r];

            ws.Cell(rowNum, 1).Value = b.BucketName;
            ws.Cell(rowNum, 2).Value = b.ClaimCount;
            ws.Cell(rowNum, 3).Value = b.PredictedAllowed;
            ws.Cell(rowNum, 4).Value = b.PredictedInsurance;

            if (b.ActualAllowed.HasValue) ws.Cell(rowNum, 5).Value = b.ActualAllowed.Value;
            if (b.ActualInsurance.HasValue) ws.Cell(rowNum, 6).Value = b.ActualInsurance.Value;
            if (b.Variance.HasValue) ws.Cell(rowNum, 7).Value = b.Variance.Value;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        ws.Column(2).Style.NumberFormat.Format = "#,##0";
        for (int c = 3; c <= 7; c++)
            ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 18, firstColMinWidth: 28);
    }

    // ?? Summary Metrics sheet ???????????????????????????????????????????

    private static void BuildSummaryMetricsSheet(XLWorkbook wb, PredictionSummaryMetrics sm)
    {
        var ws = wb.AddWorksheet("Summary Metrics");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Metric", "Claim %", "Allowed %", "Insurance %"];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Summary Metrics — Ratios & Accuracy");
        ExcelTheme.WriteSectionTitle(ws, 2, 1, colCount, "Ratios");
        ExcelTheme.WriteHeaderRow(ws, 3, 1, headers);

        int row = 4;
        WriteMetricRow(ws, row++, "Payment Ratio", sm.PaymentRatioClaim, sm.PaymentRatioAllowed, sm.PaymentRatioInsurance, 0);
        WriteMetricRow(ws, row++, "Non-Payment Rate", sm.NonPaymentRateClaim, sm.NonPaymentRateAllowed, sm.NonPaymentRateInsurance, 1);
        WriteMetricRow(ws, row++, "Denied %", sm.DeniedPctClaim, sm.DeniedPctAllowed, sm.DeniedPctInsurance, 2);
        WriteMetricRow(ws, row++, "No Response %", sm.NoResponsePctClaim, sm.NoResponsePctAllowed, sm.NoResponsePctInsurance, 3);
        WriteMetricRow(ws, row++, "Adjusted %", sm.AdjustedPctClaim, sm.AdjustedPctAllowed, sm.AdjustedPctInsurance, 4);

        row++;
        ExcelTheme.WriteSectionTitle(ws, row, 1, colCount, "Prediction Accuracy");
        ExcelTheme.WriteHeaderRow(ws, row + 1, 1, headers);
        WriteMetricRow(ws, row + 2, "Pred vs Actual", sm.PredVsActualRatioClaim, sm.PredVsActualAllowedAmount, sm.PredVsActualInsPayment, 0);

        ws.SheetView.FreezeRows(3);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 16, firstColMinWidth: 24);
    }

    private static void WriteMetricRow(IXLWorksheet ws, int row, string label,
        decimal? claim, decimal? allowed, decimal? insurance, int idx)
    {
        var bg = ExcelTheme.GetRowBg(idx);

        ws.Cell(row, 1).Value = label;
        if (claim.HasValue) { ws.Cell(row, 2).Value = claim.Value; ws.Cell(row, 2).Style.NumberFormat.Format = "0.00\"%\""; }
        if (allowed.HasValue) { ws.Cell(row, 3).Value = allowed.Value; ws.Cell(row, 3).Style.NumberFormat.Format = "0.00\"%\""; }
        if (insurance.HasValue) { ws.Cell(row, 4).Value = insurance.Value; ws.Cell(row, 4).Style.NumberFormat.Format = "0.00\"%\""; }

        for (int c = 1; c <= 4; c++)
            ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
    }

    // ?? Payer Insights sheet ????????????????????????????????????????????

    private static void BuildPayerInsightsSheet(XLWorkbook wb, IReadOnlyList<PredictionPayerRow> rows)
    {
        var ws = wb.AddWorksheet("Payer Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Payer Name", "Payer Type", "Total Claims", "Paid", "Denied",
                            "No Response", "Adjusted", "Unpaid", "Payment Rate %",
                            "Pred Allowed", "Pred Insurance", "Actual Allowed", "Actual Insurance", "Variance"];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Prediction Validation by Payer");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var p = rows[r];

            ws.Cell(rowNum, 1).Value = p.PayerName;
            ws.Cell(rowNum, 2).Value = p.PayerType;
            ws.Cell(rowNum, 3).Value = p.TotalClaims;
            ws.Cell(rowNum, 4).Value = p.Paid;
            ws.Cell(rowNum, 5).Value = p.Denied;
            ws.Cell(rowNum, 6).Value = p.NoResponse;
            ws.Cell(rowNum, 7).Value = p.Adjusted;
            ws.Cell(rowNum, 8).Value = p.Unpaid;
            if (p.PaymentRatePct.HasValue) ws.Cell(rowNum, 9).Value = p.PaymentRatePct.Value;
            ws.Cell(rowNum, 10).Value = p.PredictedAllowed;
            ws.Cell(rowNum, 11).Value = p.PredictedInsurance;
            ws.Cell(rowNum, 12).Value = p.ActualAllowed;
            ws.Cell(rowNum, 13).Value = p.ActualInsurance;
            ws.Cell(rowNum, 14).Value = p.Variance;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        for (int c = 3; c <= 8; c++) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        ws.Column(9).Style.NumberFormat.Format = "0.0\"%\"";
        for (int c = 10; c <= 14; c++) ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 28);
    }

    // ?? Panel Insights sheet ????????????????????????????????????????????

    private static void BuildPanelInsightsSheet(XLWorkbook wb, IReadOnlyList<PredictionPanelRow> rows)
    {
        var ws = wb.AddWorksheet("Panel Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["Panel Name", "Total Claims", "Paid", "Denied",
                            "No Response", "Adjusted", "Unpaid", "Payment Rate %",
                            "Pred Allowed", "Pred Insurance", "Actual Allowed", "Actual Insurance", "Variance"];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Prediction Validation by Panel");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var p = rows[r];

            ws.Cell(rowNum, 1).Value = p.PanelName;
            ws.Cell(rowNum, 2).Value = p.TotalClaims;
            ws.Cell(rowNum, 3).Value = p.Paid;
            ws.Cell(rowNum, 4).Value = p.Denied;
            ws.Cell(rowNum, 5).Value = p.NoResponse;
            ws.Cell(rowNum, 6).Value = p.Adjusted;
            ws.Cell(rowNum, 7).Value = p.Unpaid;
            if (p.PaymentRatePct.HasValue) ws.Cell(rowNum, 8).Value = p.PaymentRatePct.Value;
            ws.Cell(rowNum, 9).Value = p.PredictedAllowed;
            ws.Cell(rowNum, 10).Value = p.PredictedInsurance;
            ws.Cell(rowNum, 11).Value = p.ActualAllowed;
            ws.Cell(rowNum, 12).Value = p.ActualInsurance;
            ws.Cell(rowNum, 13).Value = p.Variance;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, c), bg);
        }

        for (int c = 2; c <= 7; c++) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        ws.Column(8).Style.NumberFormat.Format = "0.0\"%\"";
        for (int c = 9; c <= 13; c++) ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 28);
    }

    // ?? CPT Insights sheet ??????????????????????????????????????????????

    private static void BuildCptInsightsSheet(XLWorkbook wb, IReadOnlyList<PredictionCptRow> rows)
    {
        var ws = wb.AddWorksheet("CPT Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers = ["CPT Code", "Line Items", "Billed Amount", "Predicted Allowed", "Predicted Insurance"];
        int colCount = headers.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Prediction Insights by CPT Code");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            var bg = ExcelTheme.GetRowBg(r);
            var c = rows[r];

            ws.Cell(rowNum, 1).Value = c.CPTCode;
            ws.Cell(rowNum, 2).Value = c.LineItems;
            ws.Cell(rowNum, 3).Value = c.BilledAmount;
            ws.Cell(rowNum, 4).Value = c.PredictedAllowed;
            ws.Cell(rowNum, 5).Value = c.PredictedInsurance;

            for (int col = 1; col <= colCount; col++)
                ExcelTheme.StyleDataCell(ws.Cell(rowNum, col), bg);
        }

        ws.Column(2).Style.NumberFormat.Format = "#,##0";
        for (int c = 3; c <= 5; c++) ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 16, firstColMinWidth: 18);
    }

    // ?? Breakdown Charts sheet ??????????????????????????????????????????

    private static void BuildBreakdownSheet(XLWorkbook wb, PredictionAnalysisViewModel vm)
    {
        var ws = wb.AddWorksheet("Breakdowns");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        ExcelTheme.WriteTitleBar(ws, 1, 3, "Distribution Breakdowns");

        int row = 2;
        row = WriteBreakdownSection(ws, row, "Payability", vm.PayabilityBreakdown);
        row = WriteBreakdownSection(ws, row, "Final Coverage Status", vm.FinalCoverageStatusBreakdown);
        row = WriteBreakdownSection(ws, row, "Forecasting Payability", vm.ForecastingPayabilityBreakdown);
        row = WriteBreakdownSection(ws, row, "ICD Compliance", vm.ICDComplianceBreakdown);
        WriteBreakdownSection(ws, row, "Payer Type", vm.PayerTypeBreakdown);

        ws.SheetView.FreezeRows(1);
        ExcelTheme.AutoFitColumns(ws, 3, minWidth: 14, firstColMinWidth: 34);
    }

    private static int WriteBreakdownSection(IXLWorksheet ws, int startRow,
        string title, IReadOnlyDictionary<string, int> data)
    {
        ExcelTheme.WriteSectionTitle(ws, startRow, 1, 3, title);
        ExcelTheme.WriteHeaderRow(ws, startRow + 1, 1, ["Category", "Count", "% of Total"]);

        var total = data.Values.Sum();
        int r = startRow + 2;
        int idx = 0;
        foreach (var kvp in data.OrderByDescending(x => x.Value))
        {
            var bg = ExcelTheme.GetRowBg(idx++);
            ws.Cell(r, 1).Value = kvp.Key;
            ws.Cell(r, 2).Value = kvp.Value;
            ws.Cell(r, 2).Style.NumberFormat.Format = "#,##0";
            ws.Cell(r, 3).Value = total > 0 ? Math.Round((decimal)kvp.Value / total * 100, 1) : 0;
            ws.Cell(r, 3).Style.NumberFormat.Format = "0.0\"%\"";
            for (int c = 1; c <= 3; c++)
                ExcelTheme.StyleDataCell(ws.Cell(r, c), bg);
            r++;
        }

        return r + 1;
    }

    // ?? Denial Breakdown sheet ??????????????????????????????????????????

    private static void BuildDenialBreakdownSheet(XLWorkbook wb, DenialBreakdown db)
    {
        var ws = wb.AddWorksheet("Denial Breakdown");
        ws.TabColor = ExcelTheme.TabRed;
        ExcelTheme.ApplyDefaults(ws);

        // Dynamic columns: Payer | Total Claims | Total Pred Allowed | Total Pred Insurance | <months…>
        var months = db.Months;
        int fixedCols = 4;
        int colCount = fixedCols + months.Count * 3;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Predicted to Pay vs Denial Breakdown");

        // Header row 1 — fixed + month group headers
        string[] fixedHeaders = ["Payer / Denial Code", "Total Claims", "Pred Allowed", "Pred Insurance"];
        ExcelTheme.WriteHeaderRow(ws, 2, 1, fixedHeaders);

        for (int m = 0; m < months.Count; m++)
        {
            int startCol = fixedCols + m * 3 + 1;
            var range = ws.Range(2, startCol, 2, startCol + 2);
            range.Merge();
            var cell = ws.Cell(2, startCol);
            cell.Value = months[m];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // Header row 2 — sub-headers for each month
        string[] subHeaders = ["Claims", "Allowed", "Insurance"];
        ExcelTheme.WriteHeaderRow(ws, 3, 1, ["", "", "", ""]);
        for (int m = 0; m < months.Count; m++)
        {
            int startCol = fixedCols + m * 3 + 1;
            ExcelTheme.WriteHeaderRow(ws, 3, startCol, subHeaders);
        }

        int row = 4;
        foreach (var payer in db.PayerRows)
        {
            // Payer header row (bold)
            var grpBg = ExcelTheme.GroupRowBg;
            ws.Cell(row, 1).Value = payer.PayerName;
            ws.Cell(row, 1).Style.Font.Bold = true;
            ws.Cell(row, 2).Value = payer.TotalClaims;
            ws.Cell(row, 3).Value = payer.TotalPredictedAllowed;
            ws.Cell(row, 4).Value = payer.TotalPredictedInsurance;

            for (int m = 0; m < months.Count; m++)
            {
                int sc = fixedCols + m * 3 + 1;
                if (payer.ByMonth.TryGetValue(months[m], out var ma))
                {
                    ws.Cell(row, sc).Value = ma.ClaimCount;
                    ws.Cell(row, sc + 1).Value = ma.PredictedAllowed;
                    ws.Cell(row, sc + 2).Value = ma.PredictedInsurance;
                }
            }

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(row, c), grpBg);
            ws.Cell(row, 1).Style.Font.Bold = true;
            row++;

            // Denial code sub-rows
            foreach (var dc in payer.TopDenialCodes)
            {
                var bg = ExcelTheme.GetRowBg(row);
                ws.Cell(row, 1).Value = $"  {dc.DenialCode} — {dc.DenialDescription}";
                ws.Cell(row, 2).Value = dc.TotalClaims;
                ws.Cell(row, 3).Value = dc.TotalPredictedAllowed;
                ws.Cell(row, 4).Value = dc.TotalPredictedInsurance;

                for (int m = 0; m < months.Count; m++)
                {
                    int sc = fixedCols + m * 3 + 1;
                    if (dc.ByMonth.TryGetValue(months[m], out var ma))
                    {
                        ws.Cell(row, sc).Value = ma.ClaimCount;
                        ws.Cell(row, sc + 1).Value = ma.PredictedAllowed;
                        ws.Cell(row, sc + 2).Value = ma.PredictedInsurance;
                    }
                }

                for (int c = 1; c <= colCount; c++)
                    ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
                row++;
            }
        }

        // Grand Total row
        ExcelTheme.StyleTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Grand Total";
        ws.Cell(row, 2).Value = db.TotalClaims;
        ws.Cell(row, 3).Value = db.TotalPredictedAllowed;
        ws.Cell(row, 4).Value = db.TotalPredictedInsurance;
        for (int m = 0; m < months.Count; m++)
        {
            int sc = fixedCols + m * 3 + 1;
            if (db.TotalByMonth.TryGetValue(months[m], out var ma))
            {
                ws.Cell(row, sc).Value = ma.ClaimCount;
                ws.Cell(row, sc + 1).Value = ma.PredictedAllowed;
                ws.Cell(row, sc + 2).Value = ma.PredictedInsurance;
            }
        }

        ws.Column(2).Style.NumberFormat.Format = "#,##0";
        ws.Column(3).Style.NumberFormat.Format = "$#,##0";
        ws.Column(4).Style.NumberFormat.Format = "$#,##0";
        for (int m = 0; m < months.Count; m++)
        {
            int sc = fixedCols + m * 3 + 1;
            ws.Column(sc).Style.NumberFormat.Format = "#,##0";
            ws.Column(sc + 1).Style.NumberFormat.Format = "$#,##0";
            ws.Column(sc + 2).Style.NumberFormat.Format = "$#,##0";
        }

        ws.SheetView.FreezeRows(3);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 12, firstColMinWidth: 34);
    }

    // ?? No Response Breakdown sheet ?????????????????????????????????????

    private static void BuildNoResponseSheet(XLWorkbook wb, NoResponseBreakdown nr)
    {
        var ws = wb.AddWorksheet("No Response Breakdown");
        ws.TabColor = ExcelTheme.TabGold;
        ExcelTheme.ApplyDefaults(ws);

        // Columns: Payer | Total Claims | Pred Allowed | Pred Insurance | <age buckets…> | Priority
        var buckets = AgeBuckets.All;
        int fixedCols = 4;
        int colCount = fixedCols + buckets.Count * 3 + 1;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Predicted to Pay vs No Response Breakdown");

        string[] fixedHeaders = ["Payer", "Total Claims", "Pred Allowed", "Pred Insurance"];
        ExcelTheme.WriteHeaderRow(ws, 2, 1, fixedHeaders);

        for (int b = 0; b < buckets.Count; b++)
        {
            int startCol = fixedCols + b * 3 + 1;
            var range = ws.Range(2, startCol, 2, startCol + 2);
            range.Merge();
            var cell = ws.Cell(2, startCol);
            cell.Value = buckets[b];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // Priority header
        int priCol = colCount;
        ws.Cell(2, priCol).Value = "Priority";
        ws.Cell(2, priCol).Style.Font.Bold = true;
        ws.Cell(2, priCol).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, priCol).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(2, priCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        // Sub-headers
        string[] subHeaders = ["Claims", "Allowed", "Insurance"];
        ExcelTheme.WriteHeaderRow(ws, 3, 1, ["", "", "", ""]);
        for (int b = 0; b < buckets.Count; b++)
        {
            int startCol = fixedCols + b * 3 + 1;
            ExcelTheme.WriteHeaderRow(ws, 3, startCol, subHeaders);
        }
        ws.Cell(3, priCol).Value = "Level";
        ws.Cell(3, priCol).Style.Font.Bold = true;
        ws.Cell(3, priCol).Style.Font.FontColor = XLColor.White;
        ws.Cell(3, priCol).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(3, priCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        int row = 4;
        for (int i = 0; i < nr.PayerRows.Count; i++)
        {
            var p = nr.PayerRows[i];
            var bg = ExcelTheme.GetRowBg(i);

            ws.Cell(row, 1).Value = p.PayerName;
            ws.Cell(row, 2).Value = p.TotalClaims;
            ws.Cell(row, 3).Value = p.TotalPredictedAllowed;
            ws.Cell(row, 4).Value = p.TotalPredictedInsurance;

            for (int b = 0; b < buckets.Count; b++)
            {
                int sc = fixedCols + b * 3 + 1;
                if (p.ByBucket.TryGetValue(buckets[b], out var ba))
                {
                    ws.Cell(row, sc).Value = ba.ClaimCount;
                    ws.Cell(row, sc + 1).Value = ba.PredictedAllowed;
                    ws.Cell(row, sc + 2).Value = ba.PredictedInsurance;
                }
            }

            ws.Cell(row, priCol).Value = p.PriorityBucket;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
            row++;
        }

        // Grand Total
        ExcelTheme.StyleTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Grand Total";
        ws.Cell(row, 2).Value = nr.TotalClaims;
        ws.Cell(row, 3).Value = nr.TotalPredictedAllowed;
        ws.Cell(row, 4).Value = nr.TotalPredictedInsurance;
        for (int b = 0; b < buckets.Count; b++)
        {
            int sc = fixedCols + b * 3 + 1;
            if (nr.TotalByBucket.TryGetValue(buckets[b], out var ba))
            {
                ws.Cell(row, sc).Value = ba.ClaimCount;
                ws.Cell(row, sc + 1).Value = ba.PredictedAllowed;
                ws.Cell(row, sc + 2).Value = ba.PredictedInsurance;
            }
        }

        ws.Column(2).Style.NumberFormat.Format = "#,##0";
        ws.Column(3).Style.NumberFormat.Format = "$#,##0";
        ws.Column(4).Style.NumberFormat.Format = "$#,##0";
        for (int b = 0; b < buckets.Count; b++)
        {
            int sc = fixedCols + b * 3 + 1;
            ws.Column(sc).Style.NumberFormat.Format = "#,##0";
            ws.Column(sc + 1).Style.NumberFormat.Format = "$#,##0";
            ws.Column(sc + 2).Style.NumberFormat.Format = "$#,##0";
        }

        ws.SheetView.FreezeRows(3);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 11, firstColMinWidth: 28);
    }
}
