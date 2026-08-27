using ExcelDataReader;
using System.Text;

namespace LRN.MasterFileProcessorWorker.ExcelValidation;

public interface IExcelHeaderReader
{
    (string? sheetUsed, string[] headers) ReadHeader(string xlsxPath, string sheetCandidatesCsv, int headerRow);
}

public sealed class ExcelDataReaderHeaderReader : IExcelHeaderReader
{
    static ExcelDataReaderHeaderReader()
    {
        // Required for some Excel encodings.
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public (string? sheetUsed, string[] headers) ReadHeader(string xlsxPath, string sheetCandidatesCsv, int headerRow)
    {
        if (!File.Exists(xlsxPath))
            throw new FileNotFoundException("Excel file not found.", xlsxPath);

        var candidates = SplitCandidates(sheetCandidatesCsv);
        if (candidates.Length == 0)
            throw new InvalidOperationException("Sheet candidates list is empty.");

        using var stream = File.Open(xlsxPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = ExcelReaderFactory.CreateReader(stream);

        do
        {
            var currentName = reader.Name ?? "";
            if (!candidates.Any(c => currentName.Equals(c, StringComparison.OrdinalIgnoreCase)))
                continue;

            // advance to header row
            for (int i = 1; i < headerRow; i++)
            {
                if (!reader.Read()) return (currentName, Array.Empty<string>());
            }

            if (!reader.Read()) return (currentName, Array.Empty<string>());

            var headers = new string[reader.FieldCount];
            for (int c = 0; c < reader.FieldCount; c++)
                headers[c] = (reader.GetValue(c)?.ToString() ?? "").Trim();

            return (currentName, TrimTrailingEmpty(headers));
        }
        while (reader.NextResult());

        return (null, Array.Empty<string>());
    }

    private static string[] SplitCandidates(string csv)
        => (csv ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static string[] TrimTrailingEmpty(string[] arr)
    {
        int last = arr.Length - 1;
        while (last >= 0 && string.IsNullOrWhiteSpace(arr[last])) last--;
        return arr.Take(last + 1).ToArray();
    }
}
