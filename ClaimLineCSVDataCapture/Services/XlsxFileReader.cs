using ClaimLineCSVDataCapture.Models;
using ClosedXML.Excel;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Reads .xlsx workbooks and maps columns to SQL fields based on the configurable
/// <see cref="FileTypeMapping"/> — the XLSX counterpart to <see cref="CsvFileReader"/>.
/// Used for file types that arrive as Excel workbooks instead of CSV (e.g.,
/// RisingTides "ClientPaidList"). Only fields listed in the mapping JSON are captured;
/// extra columns in the workbook are ignored.
/// </summary>
public static class XlsxFileReader
{
    /// <summary>
    /// Default number of rows per batch when streaming large workbooks.
    /// Matches <see cref="CsvFileReader.DefaultBatchSize"/>.
    /// </summary>
    internal const int DefaultBatchSize = 50_000;

    /// <summary>
    /// Reads the first worksheet of an .xlsx workbook and yields batches of parsed rows.
    /// The first non-empty row is treated as the header row; all subsequent rows are
    /// mapped using <paramref name="mapping"/>.
    /// </summary>
    public static IEnumerable<List<CsvDataRow>> ReadXlsxBatches(
        string filePath, string labName, string weekFolder, string runId,
        FileTypeMapping mapping, string? originalSourcePath = null,
        int batchSize = DefaultBatchSize)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        ArgumentNullException.ThrowIfNull(mapping);
        if (batchSize <= 0) batchSize = DefaultBatchSize;

        var sourceFullPath = string.IsNullOrWhiteSpace(originalSourcePath) ? filePath : originalSourcePath;
        var fileName = Path.GetFileName(sourceFullPath);
        var hashFields = mapping.Fields.Where(f => f.IncludeInHash).ToList();

        using var workbook = new XLWorkbook(filePath);
        var worksheet = workbook.Worksheets.First();

        var lastColumn = worksheet.LastColumnUsed()?.ColumnNumber() ?? 0;
        if (lastColumn <= 0)
            yield break;

        // RowsUsed() skips fully-blank rows and is ordered by row number.
        using var rowEnumerator = worksheet.RowsUsed().GetEnumerator();

        if (!rowEnumerator.MoveNext())
            yield break;

        // First non-empty row = header row.
        var headerRow = ReadRowValues(rowEnumerator.Current, lastColumn);
        var headerIndex = CsvFileReader.BuildHeaderIndex(headerRow);

        var batch = new List<CsvDataRow>(batchSize);

        while (rowEnumerator.MoveNext())
        {
            var fields = ReadRowValues(rowEnumerator.Current, lastColumn);

            if (fields.Length == 0 || fields.All(string.IsNullOrWhiteSpace))
                continue;

            var row = CsvFileReader.MapRow(fields, headerIndex, mapping, hashFields,
                            runId, weekFolder, sourceFullPath, fileName, labName);
            batch.Add(row);

            if (batch.Count >= batchSize)
            {
                yield return batch;
                batch = new List<CsvDataRow>(batchSize);
            }
        }

        if (batch.Count > 0)
            yield return batch;
    }

    /// <summary>
    /// Opens an .xlsx workbook and returns the header row (first non-empty row of the
    /// first worksheet) as trimmed strings, without reading any data rows.
    /// Used for diagnostic logging — e.g., confirming the workbook opens and showing
    /// which headers were actually found vs. what the field mapping expects.
    /// Returns an empty array if the workbook/worksheet has no used cells.
    /// </summary>
    public static string[] PeekHeaders(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);

        using var workbook = new XLWorkbook(filePath);
        var worksheet = workbook.Worksheets.First();

        var lastColumn = worksheet.LastColumnUsed()?.ColumnNumber() ?? 0;
        if (lastColumn <= 0)
            return [];

        var firstRow = worksheet.RowsUsed().FirstOrDefault();
        if (firstRow is null)
            return [];

        return ReadRowValues(firstRow, lastColumn);
    }

    /// <summary>
    /// Reads an .xlsx workbook and returns all parsed rows.
    /// For large workbooks, prefer <see cref="ReadXlsxBatches"/>.
    /// </summary>
    public static List<CsvDataRow> ReadXlsx(
        string filePath, string labName, string weekFolder, string runId,
        FileTypeMapping mapping, string? originalSourcePath = null)
    {
        var allRows = new List<CsvDataRow>();
        foreach (var batch in ReadXlsxBatches(filePath, labName, weekFolder, runId,
                                              mapping, originalSourcePath))
        {
            allRows.AddRange(batch);
        }
        return allRows;
    }

    /// <summary>
    /// Reads cells 1..<paramref name="lastColumn"/> of a row as trimmed strings,
    /// using each cell's display formatting (so dates/numbers render the same
    /// way they appear in Excel). <paramref name="lastColumn"/> is the worksheet's
    /// last used column, so every row produces a consistent field-count aligned
    /// with the header row.
    /// </summary>
    private static string[] ReadRowValues(IXLRow row, int lastColumn)
    {
        var values = new string[lastColumn];
        for (int c = 1; c <= lastColumn; c++)
        {
            var cell = row.Cell(c);
            values[c - 1] = cell.IsEmpty() ? string.Empty : cell.GetFormattedString().Trim();
        }
        return values;
    }
}
