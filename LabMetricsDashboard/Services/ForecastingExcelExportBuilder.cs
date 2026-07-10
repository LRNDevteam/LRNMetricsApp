using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Forecasting Summary data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces sheets: Median Summary, Mode Summary (weekly by payer) and,
/// when records are supplied, a Data sheet with the full line-item detail
/// (all PayerValidationReport rows of the displayed run, after any filters).
/// </summary>
public static class ForecastingExcelExportBuilder
{
    /// <summary>Creates the workbook from the Forecasting Summary view model.</summary>
    public static XLWorkbook CreateWorkbook(ForecastingSummaryViewModel vm, string labName,
        IReadOnlyList<(string Label, string? Value)>? activeFilters = null,
        IReadOnlyList<PredictionRecord>? records = null)
    {
        var wb = new XLWorkbook();

        BuildWeeklySheet(wb, "Median Summary", vm.MedianSummary, labName);
        BuildWeeklySheet(wb, "Mode Summary", vm.ModeSummary, labName);

        if (records is not null)
            BuildDataSheet(wb, records, labName, hasFilters: activeFilters is { Count: > 0 });

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 2, activeFilters);
        }

        return wb;
    }

    /// <summary>Max rows written to the Data sheet — keeps generation time and
    /// file size sane for very large labs; the title notes when truncated.</summary>
    private const int MaxDataSheetRows = 100_000;

    /// <summary>Above this row count, per-row banding and AutoFit are skipped —
    /// both are O(rows × cols) in ClosedXML and dominated export time.</summary>
    private const int FullStylingMaxRows = 10_000;

    /// <summary>
    /// Full line-item detail sheet. Contains every row passed in — all
    /// PayerValidationReport rows for the run when no filter is applied,
    /// or the filtered subset when dimension filters are active.
    /// Written via bulk InsertData + range-level styling for performance.
    /// </summary>
    private static void BuildDataSheet(XLWorkbook wb, IReadOnlyList<PredictionRecord> records,
        string labName, bool hasFilters)
    {
        var ws = wb.AddWorksheet("Data");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Accession #", "Visit #", "CPT", "Payer Name", "Payer Type", "Panel",
            "Forecasting Payability", "Pay Status", "Payability", "Final Coverage",
            "Expected Pmt Date", "First Billed Date", "Date Of Service",
            "Billed Amt", "Allowed Amt", "Ins Payment",
            "Median Allowed (Same Lab)", "Median Ins Paid (Same Lab)",
            "Mode Allowed (Same Lab)", "Mode Ins Paid (Same Lab)",
            "Denial Code", "Denial Description"
        ];
        int colCount = headers.Length;

        int  totalCount = records.Count;
        bool truncated  = totalCount > MaxDataSheetRows;
        if (truncated)
            records = records.Take(MaxDataSheetRows).ToList();

        var scope = hasFilters ? "Filtered" : "All records";
        var title = truncated
            ? $"Line Item Detail — {scope} | {labName} | first {MaxDataSheetRows:N0} of {totalCount:N0} rows"
            : $"Line Item Detail — {scope} | {labName} | {totalCount:N0} rows";
        ExcelTheme.WriteTitleBar(ws, 1, colCount, title);
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headers);

        // ── Bulk insert: single InsertData call instead of rows × 22 cell writes ──
        var data = records.Select(r => new object[]
        {
            r.AccessionNo,
            r.VisitNumber,
            r.CPTCode,
            string.IsNullOrWhiteSpace(r.PayerNameNormalized) ? r.PayerName : r.PayerNameNormalized,
            r.PayerType,
            r.PanelName,
            r.ForecastingPayability,
            r.PayStatus,
            r.Payability,
            r.FinalCoverageStatus,
            r.ExpectedPaymentDate,
            r.FirstBilledDate,
            r.DateOfService,
            r.BilledAmount,
            r.AllowedAmount,
            r.InsurancePayment,
            r.MedianAllowedAmountSameLab,
            r.MedianInsurancePaidSameLab,
            r.ModeAllowedAmountSameLab,
            r.ModeInsurancePaidSameLab,
            r.DenialCode,
            r.DenialDescription
        });
        ws.Cell(3, 1).InsertData(data);

        if (records.Count > 0 && records.Count <= FullStylingMaxRows)
        {
            // Banded rows: one range-style per row (cheap at this size).
            for (int i = 0; i < records.Count; i++)
            {
                var bg = ExcelTheme.GetRowBg(i);
                if (bg != XLColor.White)
                    ws.Range(3 + i, 1, 3 + i, colCount).Style.Fill.BackgroundColor = bg;
            }
        }

        // Money columns
        foreach (var c in new[] { 14, 15, 16, 17, 18, 19, 20 })
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(2);
        ws.Range(2, 1, 2, colCount).SetAutoFilter();

        if (records.Count <= FullStylingMaxRows)
        {
            ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 12, firstColMinWidth: 16);
        }
        else
        {
            // AutoFit measures every cell — far too slow here. Fixed widths instead.
            double[] widths =
            [
                16, 14, 10, 30, 14, 18, 20, 14, 14, 18,
                16, 16, 16, 12, 12, 12, 15, 15, 15, 15,
                12, 40
            ];
            for (int c = 1; c <= colCount; c++)
                ws.Column(c).Width = widths[c - 1];
        }
    }

    private static void BuildWeeklySheet(XLWorkbook wb, string sheetName,
        WeeklyForecastSummary summary, string labName)
    {
        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var weeks = summary.Weeks;
        // Columns: Payer | <per-week: Allowed, Paid> | Total Allowed | Total Paid
        int fixedCols = 1;
        int weekCols = weeks.Count * 2;
        int totalCols = 2;
        int colCount = fixedCols + weekCols + totalCols;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"{sheetName} - 5-Week Forecast | {labName}");

        // Header row 1 � Payer + week ranges merged + Total
        ws.Cell(2, 1).Value = "Payer";
        ws.Cell(2, 1).Style.Font.Bold = true;
        ws.Cell(2, 1).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, 1).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(2, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Cell(2, 1).Style.Alignment.WrapText = true;

        for (int w = 0; w < weeks.Count; w++)
        {
            int startCol = fixedCols + w * 2 + 1;
            var range = ws.Range(2, startCol, 2, startCol + 1);
            range.Merge();
            var cell = ws.Cell(2, startCol);
            cell.Value = weeks[w].Label;
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // Total header
        int totalStartCol = fixedCols + weekCols + 1;
        var totalRange = ws.Range(2, totalStartCol, 2, totalStartCol + 1);
        totalRange.Merge();
        ws.Cell(2, totalStartCol).Value = "Total";
        ws.Cell(2, totalStartCol).Style.Font.Bold = true;
        ws.Cell(2, totalStartCol).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, totalStartCol).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(2, totalStartCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        // Header row 2 � sub-headers (Allowed / Paid)
        ws.Cell(3, 1).Value = "";
        ws.Cell(3, 1).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        for (int w = 0; w < weeks.Count; w++)
        {
            int sc = fixedCols + w * 2 + 1;
            ExcelTheme.WriteHeaderRow(ws, 3, sc, ["Allowed", "Paid"]);
        }
        ExcelTheme.WriteHeaderRow(ws, 3, totalStartCol, ["Allowed", "Paid"]);

        // Data rows
        int row = 4;
        for (int i = 0; i < summary.PayerRows.Count; i++)
        {
            var p = summary.PayerRows[i];
            var bg = ExcelTheme.GetRowBg(i);

            ws.Cell(row, 1).Value = p.PayerName;

            for (int w = 0; w < weeks.Count; w++)
            {
                int sc = fixedCols + w * 2 + 1;
                if (p.WeekAmounts.TryGetValue(weeks[w].Start, out var wa))
                {
                    ws.Cell(row, sc).Value = wa.ExpectedAllowed;
                    ws.Cell(row, sc + 1).Value = wa.ExpectedPaid;
                }
            }

            ws.Cell(row, totalStartCol).Value = p.TotalAllowed;
            ws.Cell(row, totalStartCol + 1).Value = p.TotalPaid;

            for (int c = 1; c <= colCount; c++)
                ExcelTheme.StyleDataCell(ws.Cell(row, c), bg);
            row++;
        }

        // Totals row
        var t = summary.Totals;
        ExcelTheme.StyleTotalRow(ws, row, 1, colCount);
        ws.Cell(row, 1).Value = "Total";
        for (int w = 0; w < weeks.Count; w++)
        {
            int sc = fixedCols + w * 2 + 1;
            if (t.WeekAmounts.TryGetValue(weeks[w].Start, out var wa))
            {
                ws.Cell(row, sc).Value = wa.ExpectedAllowed;
                ws.Cell(row, sc + 1).Value = wa.ExpectedPaid;
            }
        }
        ws.Cell(row, totalStartCol).Value = t.TotalAllowed;
        ws.Cell(row, totalStartCol + 1).Value = t.TotalPaid;

        // Number formats for all money columns
        for (int c = 2; c <= colCount; c++)
            ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(3);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 28);
    }
}
