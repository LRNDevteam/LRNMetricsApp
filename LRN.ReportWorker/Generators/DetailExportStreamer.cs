using ClosedXML.Excel;
using LabMetricsDashboard.Services;
using Microsoft.Data.SqlClient;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Chunked Claim/Line Level Excel export.
///
/// SQL side: ONE forward-only <see cref="SqlDataReader"/> over the full filtered,
/// sorted result set — the sort/scan happens exactly once. (A previous version
/// re-issued a fresh "ORDER BY ClaimID ... FETCH NEXT 25000" query per page to
/// keep each round trip short; on labs with an unindexed ClaimLevelData/LineLevelData
/// — NorthWest being the largest — that re-scanned and re-sorted the ENTIRE table
/// on every single page, making the export effectively never finish. A single
/// streaming pass does the sort once no matter the row count.)
///
/// Excel side: rows are still written in <see cref="InsertBatchSize"/> batches
/// (never materialized as one giant list) and split into a new worksheet every
/// <see cref="SheetSplitThreshold"/> rows, exactly as before.
/// </summary>
internal static class DetailExportStreamer
{
    private const int SheetSplitThreshold = 300_000;
    private const int InsertBatchSize     = 10_000;
    private const int CountTimeoutSeconds = 45;

    /// <summary>Large window — NorthWest-scale tables can legitimately take a long time to scan+sort once.</summary>
    private const int QueryTimeoutSeconds = 3600;

    public static async Task<int> WriteAsync(
        string connectionString,
        string dataSql,
        string countSql,
        List<SqlParameter> parameters,
        string labName,
        string title,
        List<(string Label, string? Value)> activeFilters,
        HashSet<string> moneyColumns,
        XLColor tabColor,
        string tempPath,
        Func<byte, Task>? reportProgressAsync,
        CancellationToken ct)
    {
        if (reportProgressAsync is not null) await reportProgressAsync(2);

        // Exact COUNT on multi-million Azure tables can itself be slow — try briefly,
        // then fall back to chunk-based progress so generation starts immediately.
        var totalFiltered = await TryCountAsync(connectionString, countSql, parameters, ct);
        if (reportProgressAsync is not null)
            await reportProgressAsync(totalFiltered is > 0 ? (byte)5 : (byte)3);

        using var wb = new XLWorkbook();
        string[]? headers = null;
        int[] moneyCols = [];
        var exportColCount = 0;
        var totalRows = 0;
        var sheetIndex = 0;
        IXLWorksheet? ws = null;
        var nextRow = 3;
        var sheetRowCount = 0;
        var batch = new List<object?[]>(InsertBatchSize);
        var expectedParts = totalFiltered is > 0
            ? Math.Max(1, (int)Math.Ceiling(totalFiltered.Value / (double)SheetSplitThreshold))
            : 1;
        var flushNumber = 0;

        void Flush()
        {
            if (ws is null || batch.Count == 0) { batch.Clear(); return; }
            ws.Cell(nextRow, 1).InsertData(batch);
            nextRow += batch.Count;
            batch.Clear();
        }

        IXLWorksheet NewSheet()
        {
            sheetIndex++;
            var baseName = title.Length <= 20 ? title.Replace(' ', '_') : "Details";
            var name = sheetIndex == 1 ? baseName : $"{baseName}_P{sheetIndex}";
            if (name.Length > 31) name = name[..31];

            var sheet = wb.AddWorksheet(name);
            sheet.TabColor = tabColor;
            ExcelTheme.ApplyDefaults(sheet);

            var partLabel = sheetIndex > 1
                ? (totalFiltered is > 0
                    ? $" (part {sheetIndex}/{expectedParts})"
                    : $" (part {sheetIndex})")
                : "";
            ExcelTheme.WriteTitleBar(sheet, 1, headers!.Length, $"{title} — {labName}{partLabel}");
            ExcelTheme.WriteHeaderRow(sheet, 2, 1, headers);
            sheet.SheetView.FreezeRows(2);
            return sheet;
        }

        await using (var conn = new SqlConnection(connectionString))
        {
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = QueryTimeoutSeconds };
            foreach (var p in parameters)
                cmd.Parameters.Add(Clone(p));

            await using var reader = await cmd.ExecuteReaderAsync(ct);

            // Sort-helper columns (__SortClaimId etc.) may still be present in the SELECT
            // from earlier keyset-paging support — harmless, just excluded from the export.
            var allNames = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToArray();
            headers = allNames.Where(n => !n.StartsWith("__", StringComparison.Ordinal)).ToArray();
            exportColCount = headers.Length;
            moneyCols = headers
                .Select((name, idx) => (name, Col: idx + 1))
                .Where(x => moneyColumns.Contains(x.name))
                .Select(x => x.Col)
                .ToArray();

            while (await reader.ReadAsync(ct))
            {
                ct.ThrowIfCancellationRequested();

                if (ws is null || sheetRowCount >= SheetSplitThreshold)
                {
                    Flush();
                    if (ws is not null)
                        ApplyMoneyFormats(ws, moneyCols, 3, nextRow - 1);
                    ws = NewSheet();
                    nextRow = 3;
                    sheetRowCount = 0;
                }

                var values = new object?[exportColCount];
                for (var c = 0; c < exportColCount; c++)
                {
                    var v = reader.GetValue(c);
                    values[c] = v is DBNull ? string.Empty : v;
                }
                batch.Add(values);
                sheetRowCount++;
                totalRows++;

                if (batch.Count >= InsertBatchSize)
                {
                    Flush();
                    flushNumber++;
                    if (reportProgressAsync is not null)
                        await reportProgressAsync(ProgressPercent(totalFiltered, totalRows, flushNumber));
                }
            }
        }

        Flush();

        if (ws is not null)
        {
            ApplyMoneyFormats(ws, moneyCols, 3, nextRow - 1);
            if (activeFilters.Count > 0)
                ExcelTheme.WriteFilterSummary(ws, nextRow, Math.Max(2, headers?.Length ?? 2), activeFilters);
        }

        if (wb.Worksheets.Count == 0)
        {
            var empty = wb.AddWorksheet("Details");
            ExcelTheme.ApplyDefaults(empty);
            ExcelTheme.WriteTitleBar(empty, 1, Math.Max(1, headers?.Length ?? 1), $"{title} — {labName}");
            if (headers is { Length: > 0 })
                ExcelTheme.WriteHeaderRow(empty, 2, 1, headers);
            empty.Cell(3, 1).Value = "No records match the selected filters.";
        }

        if (reportProgressAsync is not null) await reportProgressAsync(95);

        using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            wb.SaveAs(fs);

        if (reportProgressAsync is not null) await reportProgressAsync(100);
        return totalRows;
    }

    private static async Task<int?> TryCountAsync(
        string connectionString, string countSql, List<SqlParameter> parameters, CancellationToken ct)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(countSql, conn) { CommandTimeout = CountTimeoutSeconds };
            foreach (var p in parameters)
                cmd.Parameters.Add(Clone(p));
            return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0);
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            // Proceed without a total — progress will climb by flush count instead.
            return null;
        }
    }

    private static byte ProgressPercent(int? totalFiltered, int totalRows, int flushNumber)
    {
        if (totalFiltered is > 0)
            return (byte)Math.Min(90, 5 + totalRows * 85L / totalFiltered.Value);

        // Unknown total: climb toward 90% as batches flush (never claim 100 until save).
        return (byte)Math.Min(90, 5 + flushNumber * 2);
    }

    private static void ApplyMoneyFormats(IXLWorksheet ws, int[] moneyCols, int fromRow, int toRow)
    {
        if (toRow < fromRow || moneyCols.Length == 0) return;
        foreach (var col in moneyCols)
            ws.Range(fromRow, col, toRow, col).Style.NumberFormat.Format = "$#,##0.00";
    }

    private static SqlParameter Clone(SqlParameter p) =>
        new(p.ParameterName, p.Value ?? DBNull.Value);
}
