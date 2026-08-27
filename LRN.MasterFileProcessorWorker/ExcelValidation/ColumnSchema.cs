namespace LRN.MasterFileProcessorWorker.ExcelValidation;

public sealed class ColumnSchema
{
    public string SchemaName { get; set; } = "";
    public int HeaderRow { get; set; } = 1;
    public List<ColumnSpec> Columns { get; set; } = new();
}

public sealed class ColumnSpec
{
    public string Name { get; set; } = "";
    public bool Required { get; set; } = false;

    // Optional for future: "string","datetime","int","decimal","bool"
    public string DataType { get; set; } = "string";

    // Alternative header names accepted for this column
    public List<string> Aliases { get; set; } = new();

    // Optional calculated expression, e.g. "A + B" (A/B are common schema column names)
    public string? Calculation { get; set; }
}

public sealed class SchemaValidationResult
{
    public bool IsValid => SheetUsed != null && MissingRequiredColumns.Count == 0;

    public string? SheetUsed { get; set; }
    public List<string> MissingRequiredColumns { get; set; } = new();
    public List<string> FoundHeaders { get; set; } = new();
}
