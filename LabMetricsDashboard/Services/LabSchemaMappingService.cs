using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using LabMetricsDashboard.Models.LabSchema;

namespace LabMetricsDashboard.Services;

public interface ILabSchemaMappingService
{
    MasterSchema GetMasterSchema(SchemaLevel level);

    /// <summary>Best-guess mapping of a lab's own headers onto the master columns.</summary>
    MappingResult AutoMap(SchemaLevel level, IReadOnlyList<string> labColumns);

    /// <summary>The per-lab schema file the Master File Processor validates that lab's file against.</summary>
    string BuildLabSchemaJson(GenerateRequest request);

    /// <summary>CREATE TABLE for the lab database's landing table for this level.</summary>
    string BuildCreateTableSql(GenerateRequest request);
}

/// <summary>
/// Turns "here are the columns in a new lab's file" into the two artefacts onboarding needs: the
/// lab's schema JSON, and the DDL for its landing table.
///
/// <para>The matching is deliberately layered rather than one fuzzy score. An exact header match and
/// a 78%-similar one are not the same claim, and the screen has to be able to say which it made -
/// an onboarding mistake here silently mis-files a column for every week that follows, so the
/// uncertain ones are worth surfacing as uncertain rather than hiding inside an average.</para>
/// </summary>
public sealed class LabSchemaMappingService : ILabSchemaMappingService
{
    private static readonly JsonSerializerOptions ReadOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly string _schemaFolder;
    private readonly ILogger<LabSchemaMappingService> _logger;
    private readonly Dictionary<SchemaLevel, MasterSchema> _cache = [];
    private readonly Lock _gate = new();

    public LabSchemaMappingService(IConfiguration configuration, IWebHostEnvironment environment,
        ILogger<LabSchemaMappingService> logger)
    {
        _logger = logger;

        // Configurable so a deployment can point at the worker's own Schemas folder and keep one
        // copy; the in-project folder is the fallback so the page works out of the box.
        var configured = configuration["LabSchema:MasterSchemaFolder"];
        _schemaFolder = !string.IsNullOrWhiteSpace(configured) && Directory.Exists(configured)
            ? configured
            : Path.Combine(environment.ContentRootPath, "Schemas");
    }

    public MasterSchema GetMasterSchema(SchemaLevel level)
    {
        lock (_gate)
        {
            if (_cache.TryGetValue(level, out var cached)) return cached;

            var fileName = level == SchemaLevel.ClaimLevel ? "ClaimLevel.schema.json" : "LineLevel.schema.json";
            var path = Path.Combine(_schemaFolder, fileName);

            if (!File.Exists(path))
            {
                _logger.LogError("Master schema '{Path}' not found; the mapping page has nothing to map onto.", path);
                throw new FileNotFoundException($"Master schema not found: {path}");
            }

            var schema = JsonSerializer.Deserialize<MasterSchema>(File.ReadAllText(path), ReadOptions)
                         ?? new MasterSchema();

            _cache[level] = schema;
            return schema;
        }
    }

    // ── Matching ──────────────────────────────────────────────────────────────

    public MappingResult AutoMap(SchemaLevel level, IReadOnlyList<string> labColumns)
    {
        var master = GetMasterSchema(level);
        var result = new MappingResult { Level = level };

        var available = labColumns
            .Where(c => !string.IsNullOrWhiteSpace(c))
            .Select(c => c.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        // A header can only serve one master column, so each round removes what it took. The
        // strongest evidence claims first: otherwise a fuzzy match on "Payer Name" could take the
        // header that the next column matches exactly.
        var claimed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var mappings = master.Columns.Select(column => new ColumnMapping
        {
            MasterColumn = column.Name,
            DataType = column.DataType,
            Required = column.Required,
            IsDerived = column.IsDerived,
            Calculation = column.Calculation
        }).ToList();

        var byName = master.Columns.ToDictionary(c => c.Name, StringComparer.OrdinalIgnoreCase);

        foreach (var kind in new[] { MatchKind.Exact, MatchKind.Alias, MatchKind.Normalized, MatchKind.Fuzzy })
        {
            foreach (var mapping in mappings)
            {
                if (mapping.IsDerived || !string.IsNullOrWhiteSpace(mapping.LabColumn)) continue;
                if (!byName.TryGetValue(mapping.MasterColumn, out var column)) continue;

                var candidates = available.Where(c => !claimed.Contains(c)).ToList();
                var hit = kind switch
                {
                    MatchKind.Exact => candidates.FirstOrDefault(c => c.Equals(column.Name, StringComparison.OrdinalIgnoreCase)),
                    MatchKind.Alias => candidates.FirstOrDefault(c => column.Aliases.Any(a => c.Equals(a, StringComparison.OrdinalIgnoreCase))),
                    MatchKind.Normalized => candidates.FirstOrDefault(c => Normalize(c) == Normalize(column.Name)
                                                                           || column.Aliases.Any(a => Normalize(c) == Normalize(a))),
                    _ => BestFuzzy(candidates, column)
                };

                if (hit is null) continue;

                mapping.LabColumn = hit;
                mapping.Match = kind;
                mapping.Confidence = kind switch
                {
                    MatchKind.Exact => 100,
                    MatchKind.Alias => 95,
                    MatchKind.Normalized => 85,
                    _ => Similarity(Normalize(hit), Normalize(column.Name))
                };

                claimed.Add(hit);
            }
        }

        // Alternatives are offered only where the pick is not certain - a full list against every
        // row would be noise on the 90% the matcher got right.
        foreach (var mapping in mappings)
        {
            if (mapping.IsDerived) continue;
            if (mapping.Match is MatchKind.Exact or MatchKind.Alias) continue;
            if (!byName.TryGetValue(mapping.MasterColumn, out var column)) continue;

            mapping.Alternatives = available
                .Where(c => !string.Equals(c, mapping.LabColumn, StringComparison.OrdinalIgnoreCase))
                .Select(c => (Column: c, Score: Similarity(Normalize(c), Normalize(column.Name))))
                .Where(x => x.Score >= 45)
                .OrderByDescending(x => x.Score)
                .Take(5)
                .Select(x => x.Column)
                .ToList();
        }

        result.Mappings = mappings;
        result.UnmatchedLabColumns = available.Where(c => !claimed.Contains(c)).ToList();
        return result;
    }

    /// <summary>The closest header above the floor, or null. The floor keeps unrelated names unmatched.</summary>
    private static string? BestFuzzy(List<string> candidates, MasterColumn column)
    {
        const int Floor = 72;

        var targets = new List<string> { column.Name };
        targets.AddRange(column.Aliases);

        var best = candidates
            .Select(c => (Column: c, Score: targets.Max(t => Similarity(Normalize(c), Normalize(t)))))
            .OrderByDescending(x => x.Score)
            .FirstOrDefault();

        return best.Column is not null && best.Score >= Floor ? best.Column : null;
    }

    /// <summary>Lower-cased letters and digits only, so "Payer_Name " and "payer name" are one thing.</summary>
    private static string Normalize(string value)
        => new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    /// <summary>Levenshtein similarity as a 0-100 percentage.</summary>
    private static int Similarity(string left, string right)
    {
        if (left.Length == 0 || right.Length == 0) return 0;
        if (left == right) return 100;

        var distance = Levenshtein(left, right);
        var longest = Math.Max(left.Length, right.Length);
        return (int)Math.Round((1.0 - (double)distance / longest) * 100);
    }

    private static int Levenshtein(string left, string right)
    {
        var previous = new int[right.Length + 1];
        var current = new int[right.Length + 1];

        for (var j = 0; j <= right.Length; j++) previous[j] = j;

        for (var i = 1; i <= left.Length; i++)
        {
            current[0] = i;
            for (var j = 1; j <= right.Length; j++)
            {
                var cost = left[i - 1] == right[j - 1] ? 0 : 1;
                current[j] = Math.Min(Math.Min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost);
            }

            (previous, current) = (current, previous);
        }

        return previous[right.Length];
    }

    // ── Generation ────────────────────────────────────────────────────────────

    public string BuildLabSchemaJson(GenerateRequest request)
    {
        // The lab schema lists the lab's OWN headers - it is what the file is validated against.
        // A master column with nothing mapped contributes nothing; a derived one never appears,
        // because it is computed after the file is read, not found in it.
        var columns = request.Mappings
            .Where(m => !string.IsNullOrWhiteSpace(m.LabColumn))
            .GroupBy(m => m.LabColumn.Trim(), StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .Select(m => new Dictionary<string, object>
            {
                ["Name"] = m.LabColumn.Trim(),
                ["Required"] = m.Required,
                ["DataType"] = string.IsNullOrWhiteSpace(m.DataType) ? "string" : m.DataType
            })
            .ToList();

        var document = new Dictionary<string, object>
        {
            ["SchemaName"] = request.Level == SchemaLevel.ClaimLevel ? "Claim Level" : "Line Level",
            ["HeaderRow"] = request.HeaderRow <= 0 ? 1 : request.HeaderRow,
            ["Columns"] = columns
        };

        return JsonSerializer.Serialize(document, WriteOptions);
    }

    public string BuildCreateTableSql(GenerateRequest request)
    {
        var table = request.Level == SchemaLevel.ClaimLevel ? "ClaimLevelData" : "LineLevelData";
        var master = GetMasterSchema(request.Level);

        var sql = new StringBuilder();
        var lab = string.IsNullOrWhiteSpace(request.LabName) ? "the lab" : request.LabName.Trim();

        sql.AppendLine($"-- {table} for {lab}");
        sql.AppendLine("-- Generated by Lab Master Configuration. Run against the LAB's own database.");
        sql.AppendLine("--");
        sql.AppendLine("-- The columns are the MASTER schema's, not the lab's: the processor maps the lab's");
        sql.AppendLine("-- headers onto these canonical names before it writes, so every lab's landing table");
        sql.AppendLine("-- has the same shape and the dashboard can query them all the same way.");
        sql.AppendLine();
        sql.AppendLine($"IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '{table}')");
        sql.AppendLine("BEGIN");
        sql.AppendLine($"    CREATE TABLE dbo.{table}");
        sql.AppendLine("    (");
        sql.AppendLine("        RecordId              INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,");
        sql.AppendLine("        FileLogId             NVARCHAR(500)  NULL,");
        sql.AppendLine("        RunId                 NVARCHAR(500)  NULL,");
        sql.AppendLine("        WeekFolder            NVARCHAR(500)  NULL,");
        sql.AppendLine("        SourceFullPath        NVARCHAR(1000) NULL,");
        sql.AppendLine("        FileName              NVARCHAR(500)  NULL,");
        sql.AppendLine("        FileType              NVARCHAR(100)  NULL,");
        sql.AppendLine("        RowHash               NVARCHAR(64)   NULL,");

        var emitted = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "RecordId", "FileLogId", "RunId", "WeekFolder", "SourceFullPath", "FileName", "FileType", "RowHash"
        };

        var lines = new List<string>();
        foreach (var column in master.Columns)
        {
            var name = SqlName(column.Name);
            if (!emitted.Add(name)) continue;

            lines.Add($"        {name.PadRight(21)} {SqlType(column.DataType).PadRight(14)} NULL");
        }

        sql.AppendLine(string.Join($",{Environment.NewLine}", lines));
        sql.AppendLine("    );");
        sql.AppendLine("END");
        sql.AppendLine("GO");
        sql.AppendLine();

        // The two the pipeline and every report filter on. Without them a lab's first full week is
        // the moment anyone notices the table has no indexes.
        sql.AppendLine($"IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_{table}_RunId')");
        sql.AppendLine($"    CREATE INDEX IX_{table}_RunId ON dbo.{table} (RunId);");
        sql.AppendLine("GO");
        sql.AppendLine();
        sql.AppendLine($"IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_{table}_RowHash')");
        sql.AppendLine($"    CREATE INDEX IX_{table}_RowHash ON dbo.{table} (RowHash);");
        sql.AppendLine("GO");

        return sql.ToString();
    }

    /// <summary>Master names carry spaces ("Patient DOB"); the table columns do not.</summary>
    private static string SqlName(string name)
        => new((name ?? string.Empty).Where(c => char.IsLetterOrDigit(c) || c == '_').ToArray());

    private static string SqlType(string dataType) => (dataType ?? "string").Trim().ToLowerInvariant() switch
    {
        // Dates and numbers land as text on purpose: the source files carry blanks, "N/A" and
        // regional formats, and a typed column rejects the row instead of the value. Conversion
        // happens downstream with TRY_CONVERT, which is what every report already does.
        "decimal" or "money" => "NVARCHAR(500)",
        "int" or "integer" => "NVARCHAR(500)",
        "date" or "datetime" => "NVARCHAR(500)",
        "bool" or "boolean" => "NVARCHAR(50)",
        _ => "NVARCHAR(500)"
    };
}
