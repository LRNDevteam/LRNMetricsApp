using System.Security.Cryptography;
using System.Text;
using ClaimLineCSVDataCapture.Models;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Reads CSV files and maps columns to SQL fields
/// based on the configurable <see cref="FileTypeMapping"/>.
/// Only fields listed in FieldMappings.json are captured; extra CSV columns are ignored.
/// </summary>
public static class CsvFileReader
{
    /// <summary>
    /// Default number of rows per batch when streaming large CSV files.
    /// Balances memory usage against TVP insert throughput.
    /// </summary>
    internal const int DefaultBatchSize = 50_000;

    /// <summary>
    /// Streams a CSV file and yields batches of parsed rows.
    /// Only one batch is in memory at a time, keeping allocation bounded
    /// regardless of file size (100 MB+, 230 MB+, etc.).
    /// </summary>
    public static IEnumerable<List<CsvDataRow>> ReadCsvBatches(
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

        using var reader = new StreamReader(filePath, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 1024 * 64);

        // Read header row
        var headerRow = ReadNextRecord(reader);
        if (headerRow is null) yield break;

        var headerIndex = BuildHeaderIndex(headerRow);
        var batch = new List<CsvDataRow>(batchSize);

        while (true)
        {
            var fields = ReadNextRecord(reader);
            if (fields is null) break;

            if (fields.Length == 0 || fields.All(string.IsNullOrWhiteSpace))
                continue;

            var row = MapRow(fields, headerIndex, mapping, hashFields,
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
    /// Reads a CSV file and returns all parsed rows.
    /// Retained for small files or backward compatibility.
    /// For large files (100 MB+), prefer <see cref="ReadCsvBatches"/>.
    /// </summary>
    public static List<CsvDataRow> ReadCsv(
        string filePath, string labName, string weekFolder, string runId,
        FileTypeMapping mapping, string? originalSourcePath = null)
    {
        var allRows = new List<CsvDataRow>();
        foreach (var batch in ReadCsvBatches(filePath, labName, weekFolder, runId,
                                             mapping, originalSourcePath))
        {
            allRows.AddRange(batch);
        }
        return allRows;
    }

    /// <summary>Maps a single CSV record to a <see cref="CsvDataRow"/>.</summary>
    private static CsvDataRow MapRow(
        string[] fields, Dictionary<string, int> headerIndex,
        FileTypeMapping mapping, List<FieldMapping> hashFields,
        string runId, string weekFolder, string sourceFullPath,
        string fileName, string labName)
    {
        var row = new CsvDataRow
        {
            RunId          = runId,
            WeekFolder     = weekFolder,
            SourceFullPath = sourceFullPath,
            FileName       = fileName,
            FileType       = mapping.FileTypeKey,
        };

        foreach (var fm in mapping.Fields)
        {
            var value = GetField(fields, headerIndex, fm.CsvHeader);
            if (string.Equals(fm.DataType, "integer", StringComparison.OrdinalIgnoreCase))
                value = TrimDecimalSuffix(value);
            row.Fields[fm.SqlColumn] = value;
        }

        if (row.Fields.TryGetValue("LabName", out var csvLabName)
            && string.IsNullOrWhiteSpace(csvLabName))
        {
            row.Fields["LabName"] = labName;
        }
        else if (!row.Fields.ContainsKey("LabName"))
        {
            row.Fields["LabName"] = labName;
        }

        row.RowHash = ComputeRowHash(row, hashFields);
        return row;
    }

    /// <summary>
    /// Reads the next complete RFC 4180 CSV record from the stream.
    /// Handles quoted fields containing commas, quotes, and newlines.
    /// Returns null at end-of-stream.
    /// </summary>
    private static string[]? ReadNextRecord(StreamReader reader)
    {
        var fields = new List<string>();
        var currentField = new StringBuilder();
        bool inQuotes = false;
        bool hasData = false;

        while (true)
        {
            var line = reader.ReadLine();
            if (line is null)
            {
                if (hasData)
                {
                    fields.Add(currentField.ToString());
                    return fields.ToArray();
                }
                return null;
            }

            hasData = true;
            int ci = 0;
            if (inQuotes)
                currentField.Append('\n');

            while (ci < line.Length)
            {
                char c = line[ci];

                if (inQuotes)
                {
                    if (c == '"')
                    {
                        if (ci + 1 < line.Length && line[ci + 1] == '"')
                        {
                            currentField.Append('"');
                            ci += 2;
                        }
                        else
                        {
                            inQuotes = false;
                            ci++;
                        }
                    }
                    else
                    {
                        currentField.Append(c);
                        ci++;
                    }
                }
                else
                {
                    if (c == '"' && currentField.Length == 0)
                    {
                        inQuotes = true;
                        ci++;
                    }
                    else if (c == ',')
                    {
                        fields.Add(currentField.ToString());
                        currentField.Clear();
                        ci++;
                    }
                    else
                    {
                        currentField.Append(c);
                        ci++;
                    }
                }
            }

            if (!inQuotes)
            {
                fields.Add(currentField.ToString());
                currentField.Clear();

                if (fields.Count > 0 && !fields.All(string.IsNullOrWhiteSpace))
                    return fields.ToArray();

                // Empty row — reset and continue to next record
                fields.Clear();
                hasData = false;
            }
        }
    }

    /// <summary>Builds a case-insensitive header-to-column-index map.</summary>
    private static Dictionary<string, int> BuildHeaderIndex(string[] headers)
    {
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (int ci = 0; ci < headers.Length; ci++)
        {
            var key = headers[ci].Trim();
            map.TryAdd(key, ci);
        }
        return map;
    }

    /// <summary>Gets a field value by header name, returning empty string if not found.</summary>
    private static string GetField(string[] fields, Dictionary<string, int> headerIndex, string headerName)
    {
        if (headerIndex.TryGetValue(headerName, out int idx) && idx < fields.Length)
            return fields[idx].Trim();
        return string.Empty;
    }

    /// <summary>
    /// Strips a spurious decimal suffix (e.g., ".00") from values that should be integers.
    /// CSV exports from some systems write "12345.00" for whole numbers.
    /// </summary>
    private static string TrimDecimalSuffix(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return value;

        // Only strip when the value is a valid decimal whose fractional part is zero
        if (decimal.TryParse(value, System.Globalization.NumberStyles.Any,
                             System.Globalization.CultureInfo.InvariantCulture, out var parsed)
            && parsed == decimal.Truncate(parsed))
        {
            return decimal.Truncate(parsed).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        return value;
    }

    /// <summary>
    /// Computes a SHA256 hash using only the fields marked with IncludeInHash=true.
    /// Uses incremental hashing to avoid large intermediate string allocations.
    /// </summary>
    private static string ComputeRowHash(CsvDataRow row, List<FieldMapping> hashFields)
    {
        var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Span<byte> separatorBytes = stackalloc byte[] { (byte)'|' };

        for (int i = 0; i < hashFields.Count; i++)
        {
            if (i > 0)
                hasher.AppendData(separatorBytes);

            var value = row.Get(hashFields[i].SqlColumn);
            if (value.Length > 0)
            {
                var byteCount = Encoding.UTF8.GetByteCount(value);
                var buffer = byteCount <= 256
                    ? stackalloc byte[byteCount]
                    : new byte[byteCount];
                Encoding.UTF8.GetBytes(value, buffer);
                hasher.AppendData(buffer);
            }
        }

        Span<byte> hash = stackalloc byte[32];
        hasher.GetHashAndReset(hash);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
