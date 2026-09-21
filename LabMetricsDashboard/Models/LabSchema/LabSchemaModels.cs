using System.Text.Json.Serialization;

namespace LabMetricsDashboard.Models.LabSchema;

/// <summary>Which of the two master schemas a request is about.</summary>
public enum SchemaLevel
{
    ClaimLevel,
    LineLevel
}

/// <summary>
/// A master schema file (ClaimLevel.schema.json / LineLevel.schema.json) as it sits on disk.
/// Mirrors LRN.MasterFileProcessorWorker.ExcelValidation.ColumnSchema - the worker is the consumer
/// of what this page produces, so the shape is copied rather than reinvented.
/// </summary>
public sealed class MasterSchema
{
    public string SchemaName { get; set; } = string.Empty;
    public int HeaderRow { get; set; } = 1;
    public List<MasterColumn> Columns { get; set; } = [];
}

public sealed class MasterColumn
{
    public string Name { get; set; } = string.Empty;
    public bool Required { get; set; }
    public string DataType { get; set; } = "string";
    public List<string> Aliases { get; set; } = [];

    /// <summary>Set when the master derives the value instead of reading it, e.g. "A + B".</summary>
    public string? Calculation { get; set; }

    /// <summary>A derived column is never mapped from the lab's file - it is computed downstream.</summary>
    [JsonIgnore]
    public bool IsDerived => !string.IsNullOrWhiteSpace(Calculation);
}

/// <summary>How a suggestion was arrived at, so the screen can show why and rank confidence.</summary>
public enum MatchKind
{
    None,
    Exact,
    Alias,
    Normalized,
    Fuzzy
}

/// <summary>One master column, with whatever lab column the matcher believes belongs to it.</summary>
public sealed class ColumnMapping
{
    public string MasterColumn { get; set; } = string.Empty;
    public string DataType { get; set; } = "string";
    public bool Required { get; set; }
    public bool IsDerived { get; set; }
    public string? Calculation { get; set; }

    /// <summary>The lab's own header, or empty when nothing matched.</summary>
    public string LabColumn { get; set; } = string.Empty;

    public MatchKind Match { get; set; } = MatchKind.None;

    /// <summary>0-100. Drives the badge and the "needs a look" ordering.</summary>
    public int Confidence { get; set; }

    /// <summary>Other headers that also looked plausible, offered when the top pick is uncertain.</summary>
    public List<string> Alternatives { get; set; } = [];
}

/// <summary>What the page posts back when it wants the artefacts generated.</summary>
public sealed class GenerateRequest
{
    public string LabName { get; set; } = string.Empty;
    public SchemaLevel Level { get; set; }
    public int HeaderRow { get; set; } = 1;
    public List<GenerateMapping> Mappings { get; set; } = [];
}

public sealed class GenerateMapping
{
    public string MasterColumn { get; set; } = string.Empty;
    public string LabColumn { get; set; } = string.Empty;
    public string DataType { get; set; } = "string";
    public bool Required { get; set; }
}

/// <summary>The auto-map result for one level: every master column, plus the headers left over.</summary>
public sealed class MappingResult
{
    public SchemaLevel Level { get; set; }
    public List<ColumnMapping> Mappings { get; set; } = [];

    /// <summary>Headers in the uploaded file that no master column claimed - usually lab extras.</summary>
    public List<string> UnmatchedLabColumns { get; set; } = [];

    public int MappedCount => Mappings.Count(m => !string.IsNullOrWhiteSpace(m.LabColumn));
    public int MissingRequiredCount => Mappings.Count(m => m.Required && !m.IsDerived && string.IsNullOrWhiteSpace(m.LabColumn));
}
