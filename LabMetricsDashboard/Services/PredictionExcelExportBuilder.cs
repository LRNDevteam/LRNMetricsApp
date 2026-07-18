using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Prediction Analysis data.
/// Sheet layout mirrors the dashboard UI tabs and column structure.
/// Colors/fonts match Denial Dashboard Excel via shared <see cref="ExcelTheme"/>
/// (same constants used by DenialDashboardExcelExportBuilder — Calibri 10,
/// green title/header/banded rows).
/// </summary>
public static class PredictionExcelExportBuilder
{
    private static readonly string[] VarianceHeaders =
    [
        "Predicted – Allowed Amount",
        "Predicted – Insurance Payment",
        "Actual – Allowed Amount",
        "Actual – Insurance Payment",
        "Variance – Allowed Amount",
        "Variance – Paid Amount"
    ];

    /// <summary>Creates the workbook from the Prediction Analysis view model.</summary>
    public static XLWorkbook CreateWorkbook(PredictionAnalysisViewModel vm, string labName,
        IReadOnlyList<(string Label, string? Value)>? activeFilters = null)
    {
        var wb = new XLWorkbook();

        BuildSummarySheet(wb, vm, labName);

        if (vm.Insight is { Sections.Count: > 0 })
            BuildInsightsSheet(wb, vm.Insight);

        BuildPayerVarianceSheet(wb, vm.TopPayerInsights, vm.PayerPayStatusBreakdown);

        if (vm.DenialBreakdown.PayerRows.Count > 0)
            BuildDeniedSheet(wb, vm.DenialBreakdown);

        if (vm.NoResponseBreakdown.PayerRows.Count > 0)
            BuildNoResponseSheet(wb, vm.NoResponseBreakdown);

        if (vm.AdjustedByPayer.Count > 0)
            BuildAdjustedSheet(wb, vm.AdjustedByPayer);

        // After sheets exist: hyperlink Summary variance cells → Denied / No Response / Adjusted
        var summaryWs = wb.Worksheets.FirstOrDefault(s => s.Name == "Summary");
        if (summaryWs is not null)
            TryLinkSummaryVarianceToSheets(summaryWs);

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 8, activeFilters);
        }

        return wb;
    }

    // ── Summary tab: Section A buckets + ratios + prediction accuracy ────────

    private static string DisplayGroupName(string groupName) =>
        groupName == "Not Predicted" ? "Not Predicted to Pay" : groupName;

    private static decimal SortVarInsurance(decimal? v) => v ?? decimal.MinValue;

    private static XLColor BucketGroupBackground(string groupName) =>
        groupName == "Predicted To Pay"
            ? ExcelTheme.BlueGroupRowBg
            : ExcelTheme.GroupRowBg;

    private static void BuildSummarySheet(XLWorkbook wb, PredictionAnalysisViewModel vm, string labName)
    {
        var ws = wb.AddWorksheet("Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        string[] bucketHeaders =
        [
            "Metrics", "Claim Count (#)", "Predicted Allowed ($)", "Predicted Insurance Payment ($)",
            "Actual Allowed Amount ($)", "Actual Insurance Payment ($)",
            "Variance - Allowed Amount ($)", "Variance - Insurance Payment ($)"
        ];
        int colCount = bucketHeaders.Length;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"Prediction vs Non-Payment Summary | {labName}");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, bucketHeaders);

        var summaryGroups = vm.Buckets
            .Where(b => b.IsGroupTotal)
            .Select(g => new
            {
                Total = g,
                Children = vm.Buckets
                    .Where(c => !c.IsGroupTotal && c.GroupName == g.GroupName)
                    .OrderByDescending(c => SortVarInsurance(c.VariancePaid))
                    .ToList()
            })
            .OrderBy(g => g.Total.GroupName == "Predicted To Pay" ? 0 : 1)
            .ToList();

        int row = 3;
        foreach (var grp in summaryGroups)
        {
            WriteBucketRow(ws, row++, grp.Total, isParent: true);
            foreach (var child in grp.Children)
                WriteBucketRow(ws, row++, child, isParent: false);
        }

        ws.Column(2).Style.NumberFormat.Format = "#,##0";
        for (int c = 3; c <= colCount; c++)
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        row += 2;
        row = WriteRatiosSection(ws, row, vm.SummaryMetrics);
        row += 2;
        WritePredictionAccuracySection(ws, row, vm.SummaryMetrics);

        // Detail rows are outlined under each group parent — collapse by default
        ws.CollapseRows();

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 18, firstColMinWidth: 28);
    }

    /// <summary>
    /// Adds blue hyperlinks on Variance Allowed / Insurance columns for
    /// Denied, No Response, Adjusted under Predicted To Pay → matching sheets.
    /// </summary>
    private static void TryLinkSummaryVarianceToSheets(IXLWorksheet summaryWs)
    {
        var wb = summaryWs.Workbook;
        var last = summaryWs.LastRowUsed()?.RowNumber() ?? 3;
        string? currentGroup = null;
        for (int r = 3; r <= last; r++)
        {
            var label = (summaryWs.Cell(r, 1).GetFormattedString() ?? "").Trim();
            if (string.IsNullOrEmpty(label)) continue;

            // Stop once we leave the bucket table (ratios / accuracy sections follow).
            if (label.Equals("Ratios", StringComparison.OrdinalIgnoreCase)
                || label.Equals("Prediction Accuracy", StringComparison.OrdinalIgnoreCase)
                || label.StartsWith("Metric", StringComparison.OrdinalIgnoreCase))
                break;

            if (label is "Predicted To Pay" or "Not Predicted to Pay" or "Not Predicted")
            {
                currentGroup = label == "Not Predicted to Pay" ? "Not Predicted" : label;
                continue;
            }

            if (!string.Equals(currentGroup, "Predicted To Pay", StringComparison.OrdinalIgnoreCase))
                continue;

            string? sheetName = label switch
            {
                _ when label.Equals("Denied", StringComparison.OrdinalIgnoreCase) => "Denied",
                _ when label.Equals("No Response", StringComparison.OrdinalIgnoreCase) => "No Response",
                _ when label.Equals("Adjusted", StringComparison.OrdinalIgnoreCase) => "Adjusted",
                _ => null
            };
            if (sheetName is null) continue;
            if (wb.Worksheets.All(s => !string.Equals(s.Name, sheetName, StringComparison.OrdinalIgnoreCase)))
                continue;

            ApplySheetHyperlink(summaryWs.Cell(r, 7), sheetName);
            ApplySheetHyperlink(summaryWs.Cell(r, 8), sheetName);
        }
    }

    private static void ApplySheetHyperlink(IXLCell cell, string sheetName)
    {
        var existing = cell.Value;
        cell.SetHyperlink(new XLHyperlink($"'{sheetName}'!A1"));
        cell.Value = existing;
        // Same link style as DenialDashboardExcelExportBuilder (Insights "Data" links)
        cell.Style.Font.FontColor = XLColor.Blue;
        cell.Style.Font.Underline = XLFontUnderlineValues.Single;
    }

    private static void WriteBucketRow(IXLWorksheet ws, int row, PredictionBucketRow b, bool isParent)
    {
        const int colCount = 8;
        var bg = isParent ? BucketGroupBackground(b.GroupName) : ExcelTheme.GetRowBg(row);

        var labelCell = ws.Cell(row, 1);
        labelCell.Value = isParent ? DisplayGroupName(b.GroupName) : b.BucketName;
        if (isParent)
        {
            // Parent stays at outline level 0 so it remains visible when groups are collapsed.
            labelCell.Style.Font.Bold = true;
            labelCell.Style.Font.FontSize = ExcelTheme.FontSizeHeader;
            ws.Row(row).OutlineLevel = 0;
        }
        else
        {
            labelCell.Style.Alignment.Indent = 1;
            labelCell.Style.Font.FontColor = b.GroupName == "Predicted To Pay"
                ? ExcelTheme.BlueHeaderBg
                : ExcelTheme.AmberHeaderBg;
            ws.Row(row).OutlineLevel = 1;
        }

        ws.Cell(row, 2).Value = b.ClaimCount;
        ws.Cell(row, 3).Value = b.PredictedAllowed;
        ws.Cell(row, 4).Value = b.PredictedInsurance;
        if (b.ActualAllowed.HasValue) ws.Cell(row, 5).Value = b.ActualAllowed.Value;
        if (b.ActualInsurance.HasValue) ws.Cell(row, 6).Value = b.ActualInsurance.Value;
        if (b.VarianceAllowed.HasValue) ws.Cell(row, 7).Value = b.VarianceAllowed.Value;
        if (b.VariancePaid.HasValue) ws.Cell(row, 8).Value = b.VariancePaid.Value;

        for (int c = 1; c <= colCount; c++)
            ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
    }

    private static int WriteRatiosSection(IXLWorksheet ws, int startRow, PredictionSummaryMetrics sm)
    {
        string[] headers = ["Metric", "Claim %", "Allowed %", "Insurance %"];
        int colCount = headers.Length;

        ExcelTheme.WriteSectionTitle(ws, startRow, 1, colCount, "Ratios");
        ExcelTheme.WriteHeaderRow(ws, startRow + 1, 1, headers);

        int row = startRow + 2;
        WriteMetricRow(ws, row++, "Payment Ratio", sm.PaymentRatioClaim, sm.PaymentRatioAllowed, sm.PaymentRatioInsurance, 0);
        WriteMetricRow(ws, row++, "Non-Payment Rate", sm.NonPaymentRateClaim, sm.NonPaymentRateAllowed, sm.NonPaymentRateInsurance, 1);
        WriteMetricRow(ws, row++, "Denied %", sm.DeniedPctClaim, sm.DeniedPctAllowed, sm.DeniedPctInsurance, 2);
        WriteMetricRow(ws, row++, "No Response %", sm.NoResponsePctClaim, sm.NoResponsePctAllowed, sm.NoResponsePctInsurance, 3);
        WriteMetricRow(ws, row++, "Adjusted %", sm.AdjustedPctClaim, sm.AdjustedPctAllowed, sm.AdjustedPctInsurance, 4);

        return row;
    }

    private static void WritePredictionAccuracySection(IXLWorksheet ws, int startRow, PredictionSummaryMetrics sm)
    {
        string[] headers = ["Metric", "Claim %", "Allowed %", "Insurance %"];
        int colCount = headers.Length;

        ExcelTheme.WriteSectionTitle(ws, startRow, 1, colCount, "Prediction Accuracy");
        ExcelTheme.WriteHeaderRow(ws, startRow + 1, 1, headers);
        WriteMetricRow(ws, startRow + 2, "Pred vs Actual",
            sm.PredVsActualRatioClaim, sm.PredVsActualAllowedAmount, sm.PredVsActualInsPayment, 0);
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

    // ── Insights tab (optional AI content) ───────────────────────────────────

    private static void BuildInsightsSheet(XLWorkbook wb, PredictionInsight insight)
    {
        var ws = wb.AddWorksheet("Insights");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        ExcelTheme.WriteTitleBar(ws, 1, 2, insight.ReportTitle);
        ws.Cell(2, 1).Value = "Report Period";
        ws.Cell(2, 1).Style.Font.Bold = true;
        ws.Cell(2, 2).Value = insight.ReportPeriod;
        ws.Cell(3, 1).Value = "Source";
        ws.Cell(3, 1).Style.Font.Bold = true;
        ws.Cell(3, 2).Value = insight.SourceFileName;

        int row = 5;
        foreach (var sec in insight.Sections)
        {
            ExcelTheme.WriteSectionTitle(ws, row, 1, 2, $"{sec.SectionNumber}. {sec.Title}");
            row++;

            foreach (var sub in sec.Subsections)
            {
                ws.Cell(row, 1).Value = sub.Title;
                ws.Cell(row, 1).Style.Font.Bold = true;
                ws.Cell(row, 1).Style.Font.FontColor = ExcelTheme.TitleBg;
                row++;

                foreach (var bullet in sub.Bullets)
                {
                    ws.Cell(row, 1).Value = $"• {bullet}";
                    ws.Range(row, 1, row, 2).Merge();
                    ws.Cell(row, 1).Style.Alignment.WrapText = true;
                    row++;
                }

                row++;
            }
        }

        ExcelTheme.AutoFitColumns(ws, 2, minWidth: 20, firstColMinWidth: 24);
    }

    // ── Section B: Prediction vs Actual By Payer (with PayStatus drill-down) ─

    private static void BuildPayerVarianceSheet(XLWorkbook wb,
        IReadOnlyList<PredictionPayerRow> rows,
        IReadOnlyList<PredictionPayerPayStatusRow> payStatusRows)
    {
        var ws = wb.AddWorksheet("By Payer");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        int colCount = 1 + VarianceHeaders.Length;
        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Prediction vs Actual By Payer");
        WriteVarianceHeaderRow(ws, 2, "Payer Name / PayStatus");

        var payStatusByPayer = payStatusRows
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(
                g => g.Key,
                g => g.OrderByDescending(x => x.VarianceAllowed).ToList(),
                StringComparer.OrdinalIgnoreCase);

        int row = 3;
        foreach (var r in rows)
        {
            WriteVarianceDataRow(ws, row++, r.PayerName, r.PredictedAllowed, r.PredictedInsurance,
                r.ActualAllowed, r.ActualInsurance, r.VarianceAllowed, r.VariancePaid,
                ExcelTheme.GroupRowBg, bold: true, outlineLevel: 0);

            if (payStatusByPayer.TryGetValue(r.PayerName, out var psList))
            {
                foreach (var ps in psList)
                {
                    WriteVarianceDataRow(ws, row++, ps.PayStatus,
                        ps.PredictedAllowed, ps.PredictedInsurance,
                        ps.ActualAllowed, ps.ActualInsurance,
                        ps.VarianceAllowed, ps.VariancePaid,
                        XLColor.White, indent: 1, outlineLevel: 1);
                }
            }
        }

        WriteVarianceTotalRow(ws, row, "Grand Total",
            rows.Sum(r => r.PredictedAllowed),
            rows.Sum(r => r.PredictedInsurance),
            rows.Sum(r => r.ActualAllowed),
            rows.Sum(r => r.ActualInsurance),
            rows.Sum(r => r.VarianceAllowed),
            rows.Sum(r => r.VariancePaid));

        ws.CollapseRows();

        FormatVarianceColumns(ws, colCount);
        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 16, firstColMinWidth: 32);
    }

    // ── Section C: Predicted to Pay – Denied ─────────────────────────────────

    private static void BuildDeniedSheet(XLWorkbook wb, DenialBreakdown db)
    {
        var ws = wb.AddWorksheet("Denied");
        ws.TabColor = ExcelTheme.TabRed;
        ExcelTheme.ApplyDefaults(ws);
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;

        // Payer rows + detail rows with separate Denial Code / Denial Description columns
        string[] headers =
        [
            "Payer Name",
            "Denial Code",
            "Denial Description",
            .. VarianceHeaders
        ];
        int colCount = headers.Length;
        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Predicted to Pay – Denied");
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        int row = 3;
        int idx = 0;
        foreach (var payer in db.PayerRows)
        {
            // Payer summary (blank code/description)
            WriteDeniedDetailRow(ws, row++, payer.PayerName, null, null,
                payer.TotalPredictedAllowed, payer.TotalPredictedInsurance,
                payer.ActualAllowed, payer.ActualInsurance,
                payer.VarianceAllowed, payer.VariancePaid,
                ExcelTheme.GroupRowBg, bold: true, outlineLevel: 0);

            foreach (var dc in payer.TopDenialCodes)
            {
                WriteDeniedDetailRow(ws, row++, null, dc.DenialCode, dc.DenialDescription,
                    dc.TotalPredictedAllowed, dc.TotalPredictedInsurance,
                    dc.ActualAllowed, dc.ActualInsurance,
                    dc.VarianceAllowed, dc.VariancePaid,
                    ExcelTheme.GetRowBg(idx++), indent: 1, outlineLevel: 1);
            }
        }

        ExcelTheme.StyleTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Grand Total";
        ws.Cell(row, 4).Value = db.TotalPredictedAllowed;
        ws.Cell(row, 5).Value = db.TotalPredictedInsurance;
        ws.Cell(row, 6).Value = db.TotalActualAllowed;
        ws.Cell(row, 7).Value = db.TotalActualInsurance;
        ws.Cell(row, 8).Value = db.TotalVarianceAllowed;
        ws.Cell(row, 9).Value = db.TotalVariancePaid;

        ws.CollapseRows();

        FormatVarianceColumns(ws, colCount, firstDataCol: 4);
        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 28);
        // Match Denial Dashboard wrap/width for description text
        ws.Column(2).Width = Math.Max(ws.Column(2).Width, 18);
        ws.Column(3).Style.Alignment.WrapText = true;
        ws.Column(3).Width = Math.Max(ws.Column(3).Width, 40);
    }

    private static void WriteDeniedDetailRow(IXLWorksheet ws, int row,
        string? payerName, string? denialCode, string? denialDescription,
        decimal predAllowed, decimal predIns, decimal actAllowed, decimal actIns,
        decimal varAllowed, decimal varPaid, XLColor bg,
        bool bold = false, int indent = 0, int outlineLevel = 0)
    {
        if (outlineLevel > 0)
            ws.Row(row).OutlineLevel = outlineLevel;

        if (!string.IsNullOrWhiteSpace(payerName))
        {
            ws.Cell(row, 1).Value = payerName;
            if (bold)
            {
                ws.Cell(row, 1).Style.Font.Bold = true;
                ws.Cell(row, 1).Style.Font.FontSize = ExcelTheme.FontSizeHeader;
            }
        }
        else if (indent > 0)
        {
            ws.Cell(row, 1).Style.Alignment.Indent = indent;
        }

        if (!string.IsNullOrWhiteSpace(denialCode))
            ws.Cell(row, 2).Value = denialCode.Trim(); // keep multi-codes as-is e.g. "CO-11, CO-242"
        if (!string.IsNullOrWhiteSpace(denialDescription))
        {
            ws.Cell(row, 3).Value = denialDescription;
            ws.Cell(row, 3).Style.Alignment.WrapText = true;
        }

        ws.Cell(row, 4).Value = predAllowed;
        ws.Cell(row, 5).Value = predIns;
        ws.Cell(row, 6).Value = actAllowed;
        ws.Cell(row, 7).Value = actIns;
        ws.Cell(row, 8).Value = varAllowed;
        ws.Cell(row, 9).Value = varPaid;

        for (int c = 1; c <= 9; c++)
            ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
    }

    // ── Section D: Predicted to Pay – No Response (aging matrix) ─────────────

    private static void BuildNoResponseSheet(XLWorkbook wb, NoResponseBreakdown nr)
    {
        var ws = wb.AddWorksheet("No Response");
        ws.TabColor = ExcelTheme.TabGold;
        ExcelTheme.ApplyDefaults(ws);

        var buckets = AgeBuckets.All;
        int fixedCols = 1;
        int bucketCols = buckets.Count * 4;
        int totalCols = 2;
        int colCount = fixedCols + bucketCols + totalCols;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Predicted to Pay – No Response (Aging by Days To DOS)");

        ws.Cell(2, 1).Value = "Payer";
        ws.Cell(2, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, 1).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(2, 1).Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Range(2, 1, 3, 1).Merge();

        int col = 2;
        foreach (var bkt in buckets)
        {
            var range = ws.Range(2, col, 2, col + 3);
            range.Merge();
            var cell = ws.Cell(2, col);
            cell.Value = AgeBuckets.DisplayLabel(bkt);
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

            string[] sub = ["Sum Var – Allowed", "Sum Var – Paid", "% Var – Allowed", "% Var – Ins. Pmt"];
            for (int i = 0; i < sub.Length; i++)
            {
                var sc = ws.Cell(3, col + i);
                sc.Value = sub[i];
                sc.Style.Font.Bold = true;
                sc.Style.Font.FontColor = XLColor.White;
                sc.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
                sc.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
                sc.Style.Alignment.WrapText = true;
            }
            col += 4;
        }

        var totalRange = ws.Range(2, col, 2, col + 1);
        totalRange.Merge();
        ws.Cell(2, col).Value = "Total";
        ws.Cell(2, col).Style.Font.Bold = true;
        ws.Cell(2, col).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, col).Style.Fill.BackgroundColor = ExcelTheme.TitleBg;
        ws.Cell(2, col).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        ws.Cell(3, col).Value = "Total Var – Allowed";
        ws.Cell(3, col).Style.Font.Bold = true;
        ws.Cell(3, col).Style.Font.FontColor = XLColor.White;
        ws.Cell(3, col).Style.Fill.BackgroundColor = ExcelTheme.TitleBg;
        ws.Cell(3, col + 1).Value = "Total Var – Paid";
        ws.Cell(3, col + 1).Style.Font.Bold = true;
        ws.Cell(3, col + 1).Style.Font.FontColor = XLColor.White;
        ws.Cell(3, col + 1).Style.Fill.BackgroundColor = ExcelTheme.TitleBg;

        int row = 4;
        for (int i = 0; i < nr.PayerRows.Count; i++)
        {
            var p = nr.PayerRows[i];
            var bg = ExcelTheme.GetRowBg(i);
            ws.Cell(row, 1).Value = p.PayerName;

            col = 2;
            foreach (var bkt in buckets)
            {
                var ba = p.ByBucket.GetValueOrDefault(bkt);
                WriteNullableCurrency(ws.Cell(row, col), ba?.VarianceAllowed);
                WriteNullableCurrency(ws.Cell(row, col + 1), ba?.VariancePaid);
                WriteNullablePercent(ws.Cell(row, col + 2), ba?.PctVarianceAllowed);
                WriteNullablePercent(ws.Cell(row, col + 3), ba?.PctVariancePaid);
                col += 4;
            }

            WriteCurrency(ws.Cell(row, col), p.TotalVarianceAllowed);
            WriteCurrency(ws.Cell(row, col + 1), p.TotalVariancePaid);

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
            row++;
        }

        ExcelTheme.StyleTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Grand Total";
        col = 2;
        foreach (var bkt in buckets)
        {
            var tba = nr.TotalByBucket.GetValueOrDefault(bkt);
            WriteNullableCurrency(ws.Cell(row, col), tba?.VarianceAllowed);
            WriteNullableCurrency(ws.Cell(row, col + 1), tba?.VariancePaid);
            WriteNullablePercent(ws.Cell(row, col + 2), tba?.PctVarianceAllowed);
            WriteNullablePercent(ws.Cell(row, col + 3), tba?.PctVariancePaid);
            col += 4;
        }
        WriteCurrency(ws.Cell(row, col), nr.TotalVarianceAllowed);
        WriteCurrency(ws.Cell(row, col + 1), nr.TotalVariancePaid);

        ws.Column(1).Style.NumberFormat.Format = "@";
        for (int c = 2; c <= colCount; c++)
        {
            if ((c - 2) % 4 is 2 or 3)
                ws.Column(c).Style.NumberFormat.Format = "0.00\"%\"";
            else
                ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";
        }

        ws.SheetView.FreezeRows(3);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 12, firstColMinWidth: 28);
    }

    // ── Section E: Predicted to Pay – Adjusted ───────────────────────────────

    private static void BuildAdjustedSheet(XLWorkbook wb, IReadOnlyList<PredictionAdjustedPayerRow> rows)
    {
        var ws = wb.AddWorksheet("Adjusted");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        int colCount = 1 + VarianceHeaders.Length;
        ExcelTheme.WriteTitleBar(ws, 1, colCount, "Predicted to Pay – Adjusted");
        WriteVarianceHeaderRow(ws, 2);

        int row = 3;
        for (int i = 0; i < rows.Count; i++)
        {
            var r = rows[i];
            WriteVarianceDataRow(ws, row++, r.PayerName,
                r.PredictedAllowed, r.PredictedInsurance,
                r.ActualAllowed, r.ActualInsurance,
                r.VarianceAllowed, r.VariancePaid,
                ExcelTheme.GetRowBg(i), bold: true);
        }

        WriteVarianceTotalRow(ws, row, "Grand Total",
            rows.Sum(r => r.PredictedAllowed),
            rows.Sum(r => r.PredictedInsurance),
            rows.Sum(r => r.ActualAllowed),
            rows.Sum(r => r.ActualInsurance),
            rows.Sum(r => r.VarianceAllowed),
            rows.Sum(r => r.VariancePaid));

        FormatVarianceColumns(ws, colCount);
        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 16, firstColMinWidth: 28);
    }

    // ── Shared variance-table helpers ────────────────────────────────────────

    private static void WriteVarianceHeaderRow(IXLWorksheet ws, int row, string? firstCol = null)
    {
        var headers = new[] { firstCol ?? "Payer Name" }.Concat(VarianceHeaders).ToArray();
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers);
    }

    private static void WriteVarianceDataRow(IXLWorksheet ws, int row, string label,
        decimal predAllowed, decimal predIns, decimal actAllowed, decimal actIns,
        decimal varAllowed, decimal varPaid, XLColor bg,
        bool bold = false, int indent = 0, int outlineLevel = 0)
    {
        if (outlineLevel > 0)
            ws.Row(row).OutlineLevel = outlineLevel;

        ws.Cell(row, 1).Value = label;
        if (bold) ws.Cell(row, 1).Style.Font.Bold = true;
        if (indent > 0) ws.Cell(row, 1).Style.Alignment.Indent = indent;

        ws.Cell(row, 2).Value = predAllowed;
        ws.Cell(row, 3).Value = predIns;
        ws.Cell(row, 4).Value = actAllowed;
        ws.Cell(row, 5).Value = actIns;
        ws.Cell(row, 6).Value = varAllowed;
        ws.Cell(row, 7).Value = varPaid;

        for (int c = 1; c <= 7; c++)
            ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
    }

    private static void WriteVarianceTotalRow(IXLWorksheet ws, int row, string label,
        decimal predAllowed, decimal predIns, decimal actAllowed, decimal actIns,
        decimal varAllowed, decimal varPaid)
    {
        ExcelTheme.StyleTotalRow(ws, row, 1, 7);
        ws.Cell(row, 1).Value = label;
        ws.Cell(row, 2).Value = predAllowed;
        ws.Cell(row, 3).Value = predIns;
        ws.Cell(row, 4).Value = actAllowed;
        ws.Cell(row, 5).Value = actIns;
        ws.Cell(row, 6).Value = varAllowed;
        ws.Cell(row, 7).Value = varPaid;
    }

    private static void FormatVarianceColumns(IXLWorksheet ws, int colCount, int firstDataCol = 2)
    {
        for (int c = firstDataCol; c <= colCount; c++)
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";
    }

    private static void WriteCurrency(IXLCell cell, decimal value)
    {
        cell.Value = value;
        cell.Style.NumberFormat.Format = "$#,##0.00";
    }

    private static void WriteNullableCurrency(IXLCell cell, decimal? value)
    {
        if (value.HasValue)
            WriteCurrency(cell, value.Value);
    }

    private static void WriteNullablePercent(IXLCell cell, decimal? value)
    {
        if (value.HasValue)
        {
            cell.Value = value.Value;
            cell.Style.NumberFormat.Format = "0.00\"%\"";
        }
    }
}
