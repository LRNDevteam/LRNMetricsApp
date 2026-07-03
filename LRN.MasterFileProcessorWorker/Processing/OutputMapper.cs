using System.Globalization;
using LRN.MasterFileProcessorWorker.Schema;

namespace LRN.MasterFileProcessorWorker.Processing;

public static class OutputMapper
{
    public static Dictionary<string, string?> MapRow(IReadOnlyDictionary<string, string?> input, IEnumerable<ColumnMappingDefinition> mappings)
    {
        var output = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

        foreach (var m in mappings)
        {
            var val = FindFirst(input, m.SourceAliases);
            if (string.IsNullOrWhiteSpace(val))
                val = m.DefaultValue;

            output[m.Target] = ConvertTo(val, m.DataType);
        }

        return output;
    }

    public static List<Dictionary<string, string?>> MapRows(IEnumerable<IReadOnlyDictionary<string, string?>> rows, IEnumerable<ColumnMappingDefinition> mappings)
        => rows.Select(r => MapRow(r, mappings)).ToList();

    private static string? FindFirst(IReadOnlyDictionary<string, string?> input, List<string> aliases)
    {
        if (aliases == null || aliases.Count == 0) return null;

        foreach (var a in aliases)
        {
            if (string.IsNullOrWhiteSpace(a)) continue;
            if (input.TryGetValue(a, out var v))
                return v;
        }
        return null;
    }

    private static string? ConvertTo(string? value, string dataType)
    {
        if (string.IsNullOrWhiteSpace(value)) return value;
        dataType = (dataType ?? "string").Trim().ToLowerInvariant();

        try
        {
            switch (dataType)
            {
                case "int":
                case "int32":
                    if (int.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var i))
                        return i.ToString(CultureInfo.InvariantCulture);
                    return value;

                case "long":
                case "int64":
                    if (long.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var l))
                        return l.ToString(CultureInfo.InvariantCulture);
                    return value;

                case "decimal":
                case "number":
                    if (decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
                        return d.ToString(CultureInfo.InvariantCulture);
                    return value;

                case "datetime":
                case "date":
                    if (DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var dt))
                        return dt.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
                    if (DateTime.TryParse(value, out var d2))
                        return d2.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
                    return value;

                default:
                    return value;
            }
        }
        catch
        {
            return value;
        }
    }
}
