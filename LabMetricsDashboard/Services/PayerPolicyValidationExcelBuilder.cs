using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds an Excel workbook of Payer Policy Validation line items for one lab,
/// including Mode and Median Same Lab columns.
/// </summary>
public static class PayerPolicyValidationExcelBuilder
{
    private const int SplitThreshold = 300_000;
    private const int FullStylingMaxRows = 10_000;

    private static readonly string[] Headers =
    [
        "Accession #", "Visit #", "CPT", "Payer Name", "Payer Type", "Panel",
        "Forecasting Payability", "Pay Status", "Payability", "Final Coverage",
        "Expected Pmt Date", "First Billed Date", "Date Of Service",
        "Billed Amt", "Allowed Amt", "Ins Payment",
        "Median Allowed (Same Lab)", "Median Ins Paid (Same Lab)",
        "Mode Allowed (Same Lab)", "Mode Ins Paid (Same Lab)",
        "Denial Code", "Denial Description"
    ];

    public static byte[] CreateWorkbook(
        string labName,
        IReadOnlyList<PredictionRecord> rows,
        IReadOnlyList<(string Label, string? Value)>? activeFilters = null)
    {
        using var wb = new XLWorkbook();
        BuildDataSheets(wb, labName, rows);

        if (activeFilters is { Count: > 0 })
        {
            var ws = wb.Worksheets.First();
            int lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
            ExcelTheme.WriteFilterSummary(ws, lastRow + 1, 2, activeFilters);
        }

        using var stream = new MemoryStream();
        wb.SaveAs(stream);
        return stream.ToArray();
    }

    private static void BuildDataSheets(XLWorkbook wb, string labName, IReadOnlyList<PredictionRecord> rows)
    {
        if (rows.Count == 0)
        {
            var ws = wb.AddWorksheet("Data");
            ws.Cell(1, 1).Value = "No data matched the selected filters.";
            return;
        }

        if (rows.Count <= SplitThreshold)
        {
            WriteSheet(wb, "Data", labName, rows, 1, 1);
            return;
        }

        var partCount = (int)Math.Ceiling(rows.Count / (double)SplitThreshold);
        for (var part = 0; part < partCount; part++)
        {
            var offset = part * SplitThreshold;
            var take = Math.Min(SplitThreshold, rows.Count - offset);
            var chunk = rows.Skip(offset).Take(take).ToList();
            var name = partCount > 1 ? $"Data_P{part + 1}" : "Data";
            WriteSheet(wb, TruncateSheetName(name), labName, chunk, part + 1, partCount);
        }
    }

    private static void WriteSheet(
        XLWorkbook wb,
        string sheetName,
        string labName,
        IReadOnlyList<PredictionRecord> rows,
        int partIndex,
        int partCount)
    {
        var ws = wb.AddWorksheet(sheetName);
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        int colCount = Headers.Length;
        var title = partCount > 1
            ? $"{labName} — Payer Policy Validation — {rows.Count:N0} rows (sheet {partIndex} of {partCount})"
            : $"{labName} — Payer Policy Validation — {rows.Count:N0} rows";

        ExcelTheme.WriteTitleBar(ws, 1, colCount, title);
        ExcelTheme.WriteHeaderRow(ws, 2, 1, Headers);

        var data = rows.Select(MapRow);
        ws.Cell(3, 1).InsertData(data);

        foreach (var c in new[] { 14, 15, 16, 17, 18, 19, 20 })
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(2);
        if (rows.Count <= FullStylingMaxRows)
            ws.Range(2, 1, 2, colCount).SetAutoFilter();
        else
        {
            double[] widths =
            [
                16, 14, 10, 30, 14, 18, 20, 14, 14, 18,
                16, 16, 16, 12, 12, 12, 15, 15, 15, 15, 12, 40
            ];
            for (int c = 1; c <= colCount; c++)
                ws.Column(c).Width = widths[c - 1];
        }
    }

    private static object[] MapRow(PredictionRecord r) =>
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

    private static string TruncateSheetName(string name) =>
        name.Length <= 31 ? name : name[..31];
}
