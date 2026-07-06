using System.Text.Json;

namespace LRN.MasterFileProcessorWorker.Schema;

public static class SchemaLoader
{
    private static readonly JsonSerializerOptions _opts = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    public static SchemaDefinition LoadFromFile(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException("Schema file not found", path);

        var json = File.ReadAllText(path);
        var schema = JsonSerializer.Deserialize<SchemaDefinition>(json, _opts);
        if (schema == null)
            throw new InvalidOperationException($"Invalid schema JSON: {path}");

        // Normalize: if mandatory list not given, derive from required mappings.
        if (schema.LineLevel.MandatoryColumns.Count == 0)
            schema.LineLevel.MandatoryColumns = schema.LineLevel.CommonOutputMappings.Where(m => m.Required).SelectMany(m => m.SourceAliases).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        if (schema.ClaimLevel.MandatoryColumns.Count == 0)
            schema.ClaimLevel.MandatoryColumns = schema.ClaimLevel.CommonOutputMappings.Where(m => m.Required).SelectMany(m => m.SourceAliases).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        return schema;
    }
}
