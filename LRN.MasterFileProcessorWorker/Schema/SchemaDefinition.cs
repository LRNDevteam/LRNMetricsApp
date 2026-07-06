namespace LRN.MasterFileProcessorWorker.Schema;

public sealed class SchemaDefinition
{
    public string LabName { get; set; } = string.Empty;

    /// <summary>
    /// If the input is Excel and has separate sheets, specify them here.
    /// If claim sheet name is empty, claim level will be derived from line level by grouping by ClaimKey.
    /// </summary>
    public InputDefinition Input { get; set; } = new();

    public string ClaimKey { get; set; } = "ClaimId";

    public LevelDefinition LineLevel { get; set; } = new();
    public LevelDefinition ClaimLevel { get; set; } = new();

    public sealed class InputDefinition
    {
        public string LineLevelSheetName { get; set; } = "Line";
        public string ClaimLevelSheetName { get; set; } = "";
        public int HeaderRow { get; set; } = 1;
    }

    public sealed class LevelDefinition
    {
        public List<string> MandatoryColumns { get; set; } = new();
        public List<ColumnMappingDefinition> CommonOutputMappings { get; set; } = new();
    }
}

public sealed class ColumnMappingDefinition
{
    public string Target { get; set; } = string.Empty;

    /// <summary>
    /// Aliases for the source column (case-insensitive). First match wins.
    /// </summary>
    public List<string> SourceAliases { get; set; } = new();

    public bool Required { get; set; }

    /// <summary>
    /// string | int | decimal | datetime
    /// </summary>
    public string DataType { get; set; } = "string";

    /// <summary>
    /// Optional default value if source is missing/empty.
    /// </summary>
    public string? DefaultValue { get; set; }
}
