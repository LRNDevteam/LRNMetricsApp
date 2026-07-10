using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Forecasting Summary data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces sheets: Median Summary, Mode Summary (weekly by payer) and,
/// when records are supplied, one or more Data sheets with line-item detail.
/// Large exports are split across multiple sheets (by month, then by row chunks).
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
            BuildDataSheets(wb, records, labName, hasFilters: activeFilters is { Count: > 0 });

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 2, activeFilters);
        }

        return wb;
    }

    /// <summary>Above this row count, data is split into multiple sheets.</summary>
    private const int SplitThreshold = 300_000;

    /// <summary>Hard cap per sheet — Excel allows 1,048,576 rows (2 reserved for headers).</summary>
    private const int MaxRowsPerSheet = 1_048_574;

    /// <summary>Above this row count, per-row banding and AutoFit are skipped.</summary>
    private const int FullStylingMaxRows = 10_000;

    private static readonly string[] DataHeaders =
    [
        "Accession #", "Visit #", "CPT", "Payer Name", "Payer Type", "Panel",
        "Forecasting Payability", "Pay Status", "Payability", "Final Coverage",
        "Expected Pmt Date", "First Billed Date", "Date Of Service",
        "Billed Amt", "Allowed Amt", "Ins Payment",
        "Median Allowed (Same Lab)", "Median Ins Paid (Same Lab)",
        "Mode Allowed (Same Lab)", "Mode Ins Paid (Same Lab)",
        "Denial Code", "Denial Description"
    ];

    private static void BuildDataSheets(XLWorkbook wb, IReadOnlyList<PredictionRecord> records,
        string labName, bool hasFilters)
    {
        if (records.Count == 0)
            return;

        var segments = CreateDataSegments(records);
        foreach (var (sheetName, segment, segmentIndex, segmentCount) in segments)
        {
            BuildDataSheet(
                wb,
                sheetName,
                segment,
                labName,
                hasFilters,
                records.Count,
                segmentIndex,
                segmentCount);
        }
    }

    private static List<(string SheetName, IReadOnlyList<PredictionRecord> Records, int Index, int Count)>
        CreateDataSegments(IReadOnlyList<PredictionRecord> records)
    {
        if (records.Count <= SplitThreshold)
            return [("Data", records, 1, 1)];

        // Index-based paging — avoids an O(n) GroupBy over hundreds of thousands of rows.
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var segments = new List<(string, IReadOnlyList<PredictionRecord>, int, int)>();
        var partCount = (int)Math.Ceiling(records.Count / (double)SplitThreshold);

        for (var part = 0; part < partCount; part++)
        {
            var offset = part * SplitThreshold;
            var take = Math.Min(SplitThreshold, records.Count - offset);
            IReadOnlyList<PredictionRecord> chunk = records is List<PredictionRecord> list
                ? list.GetRange(offset, take)
                : records.Skip(offset).Take(take).ToList();
            var partName = partCount > 1 ? $"Data_P{part + 1}" : "Data";
            segments.Add((UniqueSheetName(partName, usedNames), chunk, part + 1, partCount));
        }

        return segments;
    }

    private static string UniqueSheetName(string baseName, HashSet<string> used)
    {
        var name = TruncateSheetName(baseName);
        if (used.Add(name))
            return name;

        for (var i = 2; i < 100; i++)
        {
            var candidate = TruncateSheetName($"{baseName}_{i}");
            if (used.Add(candidate))
                return candidate;
        }

        return TruncateSheetName($"{baseName}_{used.Count + 1}");
    }

    private static string TruncateSheetName(string name) =>
        name.Length <= 31 ? name : name[..31];

    private static void BuildDataSheet(
        XLWorkbook wb,
        string sheetName,
        IReadOnlyList<PredictionRecord> records,
        string labName,
        bool hasFilters,
        int totalCount,
        int segmentIndex,
        int segmentCount)
    {
        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        int colCount = DataHeaders.Length;
        int rowsToWrite = Math.Min(records.Count, MaxRowsPerSheet);
        bool truncatedOnSheet = records.Count > MaxRowsPerSheet;

        var scope = hasFilters ? "Filtered" : "All records";
        var title = BuildDataSheetTitle(
            scope, labName, rowsToWrite, totalCount, segmentIndex, segmentCount, truncatedOnSheet);
        ExcelTheme.WriteTitleBar(ws, 1, colCount, title);
        ExcelTheme.WriteHeaderRow(ws, 2, 1, DataHeaders);

        var data = records.Take(rowsToWrite).Select(MapRecordToRow);
        ws.Cell(3, 1).InsertData(data);

        if (rowsToWrite > 0 && rowsToWrite <= FullStylingMaxRows)
        {
            for (int i = 0; i < rowsToWrite; i++)
            {
                var bg = ExcelTheme.GetRowBg(i);
                if (bg != XLColor.White)
                    ws.Range(3 + i, 1, 3 + i, colCount).Style.Fill.BackgroundColor = bg;
            }
        }

        foreach (var c in new[] { 14, 15, 16, 17, 18, 19, 20 })
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(2);
        if (rowsToWrite <= FullStylingMaxRows)
            ws.Range(2, 1, 2, colCount).SetAutoFilter();

        if (rowsToWrite <= FullStylingMaxRows)
        {
            ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 12, firstColMinWidth: 16);
        }
        else
        {
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

    private static string BuildDataSheetTitle(
        string scope,
        string labName,
        int rowsOnSheet,
        int totalCount,
        int segmentIndex,
        int segmentCount,
        bool truncatedOnSheet)
    {
        var parts = new List<string> { $"Line Item Detail — {scope}", labName };

        if (segmentCount > 1)
            parts.Add($"sheet {segmentIndex} of {segmentCount}");

        if (truncatedOnSheet)
            parts.Add($"first {rowsOnSheet:N0} of {totalCount:N0} rows on this sheet");
        else if (segmentCount > 1)
            parts.Add($"{rowsOnSheet:N0} rows on this sheet ({totalCount:N0} total)");
        else
            parts.Add($"{totalCount:N0} rows");

        return string.Join(" | ", parts);
    }

    private static object[] MapRecordToRow(PredictionRecord r) =>
    [
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
    ];

    private static void BuildWeeklySheet(XLWorkbook wb, string sheetName,
        WeeklyForecastSummary summary, string labName)
    {
        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        var weeks = summary.Weeks;
        int fixedCols = 1;
        int weekCols = weeks.Count * 2;
        int totalCols = 2;
        int colCount = fixedCols + weekCols + totalCols;

        ExcelTheme.WriteTitleBar(ws, 1, colCount, $"{sheetName} - 5-Week Forecast | {labName}");

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

        int totalStartCol = fixedCols + weekCols + 1;
        var totalRange = ws.Range(2, totalStartCol, 2, totalStartCol + 1);
        totalRange.Merge();
        ws.Cell(2, totalStartCol).Value = "Total";
        ws.Cell(2, totalStartCol).Style.Font.Bold = true;
        ws.Cell(2, totalStartCol).Style.Font.FontColor = XLColor.White;
        ws.Cell(2, totalStartCol).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        ws.Cell(2, totalStartCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        ws.Cell(3, 1).Value = "";
        ws.Cell(3, 1).Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        for (int w = 0; w < weeks.Count; w++)
        {
            int sc = fixedCols + w * 2 + 1;
            ExcelTheme.WriteHeaderRow(ws, 3, sc, ["Allowed", "Paid"]);
        }
        ExcelTheme.WriteHeaderRow(ws, 3, totalStartCol, ["Allowed", "Paid"]);

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

        for (int c = 2; c <= colCount; c++)
            ws.Column(c).Style.NumberFormat.Format = "$#,##0";

        ws.SheetView.FreezeRows(3);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 28);
    }
}
