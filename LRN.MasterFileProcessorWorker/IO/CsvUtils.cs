using System.Text;

namespace LRN.MasterFileProcessorWorker.IO;

public static class CsvUtils
{
    public static string Escape(string? value)
    {
        value ??= string.Empty;
        var mustQuote = value.Contains(',') || value.Contains('"') || value.Contains('\n') || value.Contains('\r');
        if (!mustQuote) return value;
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }

    public static async Task WriteAsync(string path, IReadOnlyList<string> headers, IEnumerable<IReadOnlyDictionary<string, string?>> rows, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? AppContext.BaseDirectory);

        await using var sw = new StreamWriter(path, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        await sw.WriteLineAsync(string.Join(',', headers.Select(Escape)));

        foreach (var row in rows)
        {
            ct.ThrowIfCancellationRequested();
            var line = string.Join(',', headers.Select(h => Escape(row.TryGetValue(h, out var v) ? v : null)));
            await sw.WriteLineAsync(line);
        }
    }

    public static async Task<TabularData> ReadAsync(string path, CancellationToken ct)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("CSV not found", path);

        var data = new TabularData();
        using var sr = new StreamReader(path, Encoding.UTF8);
        var headerLine = await sr.ReadLineAsync(ct);
        if (headerLine == null) return data;

        var headers = ParseLine(headerLine).ToArray();
        foreach (var h in headers) data.Columns.Add(h);

        string? line;
        while ((line = await sr.ReadLineAsync(ct)) != null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            var fields = ParseLine(line).ToArray();
            var row = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < headers.Length; i++)
            {
                row[headers[i]] = i < fields.Length ? fields[i] : null;
            }
            data.Rows.Add(row);
        }

        return data;
    }

    /// <summary>Parses a single CSV line (RFC4180-ish) without external libs.</summary>
    public static IEnumerable<string> ParseLine(string line)
    {
        if (line == null) yield break;

        var sb = new StringBuilder();
        bool inQuotes = false;

        for (int i = 0; i < line.Length; i++)
        {
            var c = line[i];

            if (inQuotes)
            {
                if (c == '"')
                {
                    // Escaped quote
                    if (i + 1 < line.Length && line[i + 1] == '"')
                    {
                        sb.Append('"');
                        i++;
                    }
                    else
                    {
                        inQuotes = false;
                    }
                }
                else
                {
                    sb.Append(c);
                }
            }
            else
            {
                if (c == ',')
                {
                    yield return sb.ToString();
                    sb.Clear();
                }
                else if (c == '"')
                {
                    inQuotes = true;
                }
                else
                {
                    sb.Append(c);
                }
            }
        }

        yield return sb.ToString();
    }
}
