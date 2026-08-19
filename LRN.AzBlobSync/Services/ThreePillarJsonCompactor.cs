using System.Text.Json;
using System.Text.Json.Nodes;

namespace LRN.AzBlobSync.Services;

public static class ThreePillarJsonCompactor
{
    private const int MaxRowsPerResultSet = 32;

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

            if (obj["resultSets"] is JsonArray sets)
            {
                foreach (var set in sets)
                {
                    if (set is not JsonArray rows || rows.Count <= MaxRowsPerResultSet)
                        continue;

                    var keep = rows.TakeLast(MaxRowsPerResultSet).Select(r => r?.DeepClone()).ToList();
                    rows.Clear();
                    foreach (var row in keep)
                        rows.Add(row);
                }
            }
        }

        return node?.ToJsonString(new JsonSerializerOptions { WriteIndented = false }) ?? json;
    }
}
