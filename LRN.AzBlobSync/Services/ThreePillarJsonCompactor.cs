using System.Text.Json;
using System.Text.Json.Nodes;

namespace LRN.AzBlobSync.Services;

public static class ThreePillarJsonCompactor
{
    private const int MaxRowsPerChart = 36;

    private static readonly HashSet<string> DropKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "storedProcedure",
        "elapsedMs",
        "generatedUtc",
    };

    public static string Compact(string json)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json);
        }
        catch (JsonException)
        {
            return json.Length > 80_000 ? json[..80_000] : json;
        }

        if (node is JsonObject obj)
        {
            foreach (var key in DropKeys)
                obj.Remove(key);

            // Preferred shape: named charts matching UI graph titles.
            if (obj["charts"] is JsonArray charts)
            {
                foreach (var chart in charts)
                {
                    if (chart is not JsonObject chartObj)
                        continue;
                    if (chartObj["rows"] is not JsonArray rows || rows.Count <= MaxRowsPerChart)
                        continue;

                    TrimArrayKeepLast(rows, MaxRowsPerChart);
                    chartObj["rowCount"] = rows.Count;
                }
            }

            // Legacy anonymous resultSets (older files) — still trim if present.
            if (obj["resultSets"] is JsonArray sets)
            {
                foreach (var set in sets)
                {
                    if (set is not JsonArray rows || rows.Count <= MaxRowsPerChart)
                        continue;
                    TrimArrayKeepLast(rows, MaxRowsPerChart);
                }
            }
        }

        return node?.ToJsonString(new JsonSerializerOptions { WriteIndented = false }) ?? json;
    }

    private static void TrimArrayKeepLast(JsonArray rows, int keep)
    {
        var kept = rows.TakeLast(keep).Select(r => r?.DeepClone()).ToList();
        rows.Clear();
        foreach (var row in kept)
            rows.Add(row);
    }
}
