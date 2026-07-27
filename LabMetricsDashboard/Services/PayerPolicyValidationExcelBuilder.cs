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

    // ICD code-list columns can exceed Excel's 32,767-char cell limit; oversized
    // values are split across the base column plus appended "{name}_1", "_2", … columns.
    private static readonly int[] IcdColumnIndexes =
        Headers
            .Select((h, i) => (h, i))
            .Where(x => IcdCellSplitter.IsIcdColumn(x.h))
            .Select(x => x.i)
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

        // Determine how many overflow columns each ICD column needs for THIS sheet's
        // rows (0 for the common case where nothing exceeds the cell limit).
        var extraParts = new int[Headers.Length];
        foreach (var r in rows)
        {
            foreach (var ci in IcdColumnIndexes)
            {
                var val = PayerPolicyValidationColumns.All[ci].Value(r)?.ToString();
                if (string.IsNullOrEmpty(val) || val.Length <= IcdCellSplitter.MaxCellLength)
                    continue;
                var parts = IcdCellSplitter.Split(val).Count - 1;
                if (parts > extraParts[ci]) extraParts[ci] = parts;
            }
        }

        // Base columns keep their exact positions; overflow columns are appended
        // at the far right so nothing downstream shifts.
        var headers = new List<string>(Headers);
        var overflowColStart = new Dictionary<int, int>(); // base col index -> 0-based start in extended array
        foreach (var ci in IcdColumnIndexes)
        {
            if (extraParts[ci] == 0) continue;
            overflowColStart[ci] = headers.Count;
            for (var k = 1; k <= extraParts[ci]; k++)
                headers.Add($"{Headers[ci]}_{k}");
        }
        var headerArray = headers.ToArray();
        int colCount = headerArray.Length;

        var title = partCount > 1
            ? $"{labName} — Payer Policy Validation — {rows.Count:N0} rows (sheet {partIndex} of {partCount})"
            : $"{labName} — Payer Policy Validation — {rows.Count:N0} rows";

        ExcelTheme.WriteTitleBar(ws, 1, colCount, title);
        ExcelTheme.WriteHeaderRow(ws, 2, 1, headerArray);

        var data = rows.Select(r => MapRow(r, colCount, overflowColStart));
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

    private static object[] MapRow(
        PredictionRecord r, int colCount, Dictionary<int, int> overflowColStart)
    {
        var arr = new object[colCount];
        var all = PayerPolicyValidationColumns.All;
        for (var i = 0; i < all.Count; i++)
            arr[i] = all[i].Value(r) ?? string.Empty;

        // Split oversized ICD cells: chunk 0 stays in the base column, the rest go
        // into the appended overflow columns for that base column.
        foreach (var ci in IcdColumnIndexes)
        {
            if (arr[ci] is not string s || s.Length <= IcdCellSplitter.MaxCellLength)
                continue;
            var chunks = IcdCellSplitter.Split(s);
            arr[ci] = chunks[0];
            var start = overflowColStart[ci];
            for (var k = 1; k < chunks.Count; k++)
                arr[start + (k - 1)] = chunks[k];
        }

        for (var i = 0; i < colCount; i++)
            arr[i] ??= string.Empty;
        return arr;
    }

    private static string TruncateSheetName(string name) =>
        name.Length <= 31 ? name : name[..31];
}
