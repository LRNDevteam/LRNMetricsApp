using System.Security.Cryptography;
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
    /// Reads a CSV file and returns parsed rows using the supplied field mapping.
    /// Works for both Claim Level and Line Level — the mapping drives everything.
    /// </summary>
    public static List<CsvDataRow> ReadCsv(
        string filePath, string labName, string weekFolder, string runId,
        FileTypeMapping mapping, string? originalSourcePath = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        ArgumentNullException.ThrowIfNull(mapping);

        // Use original source path for DB tracking; fall back to filePath if not provided
        var sourceFullPath = string.IsNullOrWhiteSpace(originalSourcePath) ? filePath : originalSourcePath;
        var csvRows = ParseCsvLines(filePath);
        if (csvRows.Count < 2) return [];

        var headers = csvRows[0];
        var headerIndex = BuildHeaderIndex(headers);
        var fileName = Path.GetFileName(sourceFullPath);
        var hashFields = mapping.Fields.Where(f => f.IncludeInHash).ToList();
        var rows = new List<CsvDataRow>(csvRows.Count - 1);

        for (int i = 1; i < csvRows.Count; i++)
        {
            var fields = csvRows[i];
            if (fields.Length == 0 || fields.All(string.IsNullOrWhiteSpace))
                continue;

            var row = new CsvDataRow
            {
                RunId          = runId,
                WeekFolder     = weekFolder,
                SourceFullPath = sourceFullPath,
                FileName       = fileName,
                FileType       = mapping.FileTypeKey,
            };

            // Map only configured fields from CSV to SQL column
            foreach (var fm in mapping.Fields)
            {
                var value = GetField(fields, headerIndex, fm.CsvHeader);
                row.Fields[fm.SqlColumn] = value;
            }

            // Use LabName from config if CSV field is empty
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
            rows.Add(row);
        }

        return rows;
    }

    /// <summary>
    /// Parses CSV lines handling RFC 4180 quoted fields (fields with commas, quotes, newlines).
    /// </summary>
    private static List<string[]> ParseCsvLines(string filePath)
    {
        var result = new List<string[]>();
        using var reader = new StreamReader(filePath, Encoding.UTF8);

        var fields = new List<string>();
        var currentField = new StringBuilder();
        bool inQuotes = false;

        while (true)
        {
            var line = reader.ReadLine();
            if (line is null)
            {
                if (fields.Count > 0 || currentField.Length > 0)
                {
                    fields.Add(currentField.ToString());
                    result.Add(fields.ToArray());
                }
                break;
            }

            int ci = 0;
            if (inQuotes)
            {
                currentField.Append('\n');
            }

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
                {
                    result.Add(fields.ToArray());
                }
                fields.Clear();
            }
        }

        return result;
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
