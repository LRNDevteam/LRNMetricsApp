namespace LRN.ExcelValidator.Models;

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

    public string DataType { get; set; } = "string";

    public List<string> Aliases { get; set; } = new();

    public string? Calculation { get; set; }
}

public sealed class SchemaValidationResult
{
    public bool IsValid => SheetUsed != null && MissingRequiredColumns.Count == 0;

    public string? SheetUsed { get; set; }
    public List<string> MissingRequiredColumns { get; set; } = new();
    public List<string> FoundHeaders { get; set; } = new();
}
