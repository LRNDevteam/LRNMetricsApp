using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds an Excel workbook of Payer Policy Validation line items for one lab.
/// Exports the full dbo.PayerValidationReport column set (see
/// <see cref="PayerPolicyValidationColumns"/>) using the shared green
/// <see cref="ExcelTheme"/> — same styling family as the Prediction exports.
/// </summary>
public static class PayerPolicyValidationExcelBuilder
{
    private const int SplitThreshold = 300_000;
    private const int FullStylingMaxRows = 10_000;

    private static readonly string[] Headers =
        PayerPolicyValidationColumns.All.Select(c => c.Header).ToArray();

    private static readonly int[] MoneyColumnNumbers =
        PayerPolicyValidationColumns.All
            .Select((c, i) => (c.IsMoney, Col: i + 1))
            .Where(x => x.IsMoney)
            .Select(x => x.Col)
            .ToArray();

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

        foreach (var c in MoneyColumnNumbers)
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(2);
        if (rows.Count <= FullStylingMaxRows)
            ws.Range(2, 1, 2, colCount).SetAutoFilter();
        else
        {
            for (int c = 1; c <= colCount; c++)
                ws.Column(c).Width = 16;
        }
    }

    private static object[] MapRow(PredictionRecord r) =>
        PayerPolicyValidationColumns.All.Select(c => c.Value(r) ?? string.Empty).ToArray();

    private static string TruncateSheetName(string name) =>
        name.Length <= 31 ? name : name[..31];
}
