using System.Text.Json;
using LRN.ExcelValidator.Models;

namespace LRN.ExcelValidator.Services;

public interface IColumnSchemaLoader
{
    ColumnSchema LoadFromFile(string jsonPath);
}

public sealed class JsonColumnSchemaLoader : IColumnSchemaLoader
{
    public ColumnSchema LoadFromFile(string jsonPath)
    {
        if (string.IsNullOrWhiteSpace(jsonPath))
            throw new ArgumentException("Schema json path is empty.", nameof(jsonPath));

        if (!File.Exists(jsonPath))
            throw new FileNotFoundException("Schema json not found.", jsonPath);

        var json = File.ReadAllText(jsonPath);
        var schema = JsonSerializer.Deserialize<ColumnSchema>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });

        if (schema == null)
            throw new InvalidOperationException($"Failed to parse schema JSON: {jsonPath}");

        if (schema.HeaderRow <= 0) schema.HeaderRow = 1;
        schema.SchemaName ??= "";

        schema.Columns ??= new();
        foreach (var c in schema.Columns)
        {
            c.Name ??= "";
            c.DataType ??= "string";
            c.Aliases ??= new();
            if (string.IsNullOrWhiteSpace(c.Calculation)) c.Calculation = null;
        }

        return schema;
    }
}
