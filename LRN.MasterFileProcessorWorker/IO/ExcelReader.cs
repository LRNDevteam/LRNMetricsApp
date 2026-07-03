using ClosedXML.Excel;

namespace LRN.MasterFileProcessorWorker.IO;

public static class ExcelReader
{
    public static TabularData ReadSheet(string path, string sheetName, int headerRow)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("Excel file not found", path);

        using var wb = new XLWorkbook(path);
        var ws = wb.Worksheets.FirstOrDefault(s => string.Equals(s.Name, sheetName, StringComparison.OrdinalIgnoreCase))
                 ?? wb.Worksheets.First();

        var data = new TabularData();

        var firstRow = ws.Row(headerRow);
        var lastCol = firstRow.LastCellUsed()?.Address.ColumnNumber ?? 0;
        if (lastCol == 0) return data;

        var headers = new List<string>();
        for (int c = 1; c <= lastCol; c++)
        {
            var header = firstRow.Cell(c).GetString().Trim();
            if (string.IsNullOrWhiteSpace(header))
                header = $"Column{c}";

            headers.Add(header);
            data.Columns.Add(header);
        }

        var lastRow = ws.LastRowUsed()?.RowNumber() ?? headerRow;
        for (int r = headerRow + 1; r <= lastRow; r++)
        {
            var row = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
            bool any = false;
            for (int c = 1; c <= lastCol; c++)
            {
                var val = ws.Row(r).Cell(c).GetValue<string?>();
                if (!string.IsNullOrWhiteSpace(val)) any = true;
                row[headers[c - 1]] = string.IsNullOrWhiteSpace(val) ? null : val;
            }
            if (any) data.Rows.Add(row);
        }

        return data;
    }

    public static bool HasSheet(string path, string sheetName)
    {
        using var wb = new XLWorkbook(path);
        return wb.Worksheets.Any(s => string.Equals(s.Name, sheetName, StringComparison.OrdinalIgnoreCase));
    }
}
