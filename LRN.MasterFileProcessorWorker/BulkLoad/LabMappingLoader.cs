using System.Text.Json;
using System.Text.RegularExpressions;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

public sealed class LabMappingValidationException : Exception
{
    public LabMappingValidationException(IReadOnlyList<string> errors)
        : base("Lab mapping validation failed:" + Environment.NewLine +
               string.Join(Environment.NewLine, errors.Select(e => "  - " + e)))
    {
        Errors = errors;
    }

    public IReadOnlyList<string> Errors { get; }
}

/// <summary>
/// Loads and validates every <c>Schemas/LabMappings/*.json</c> at startup.
/// <para>
/// Validation is fail-fast and names the offending file in every message, because a mapping mistake
/// otherwise surfaces as silent NULL columns days later.
/// </para>
/// </summary>
public sealed class LabMappingLoader
{
    // Whitelist for anything that reaches a SQL statement as an identifier. Config-supplied table
    // names are never concatenated into SQL until they have passed this AND been confirmed against
    // sys.tables at load time (see LineClaimBulkLoader.EnsureTableExistsAsync).
    private static readonly Regex TableNamePattern =
        new(@"^\[?(?<schema>[A-Za-z_][A-Za-z0-9_]*)\]?\.\[?(?<table>[A-Za-z_][A-Za-z0-9_]*)\]?$", RegexOptions.Compiled);

    private static readonly Regex ColumnNamePattern =
        new(@"^[A-Za-z_][A-Za-z0-9_]*$", RegexOptions.Compiled);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    private readonly ILogger<LabMappingLoader> _logger;

    public LabMappingLoader(ILogger<LabMappingLoader> logger) => _logger = logger;

    /// <summary>Loads every mapping in the folder. Throws if any file fails validation.</summary>
    public IReadOnlyList<LabMappingConfig> LoadAll(string folderPath)
    {
        if (!Directory.Exists(folderPath))
            throw new DirectoryNotFoundException($"Lab mappings folder not found: {folderPath}");

        // Case-insensitive: the folder mixes ".json" and ".Json".
        var files = Directory
            .EnumerateFiles(folderPath, "*.*", SearchOption.TopDirectoryOnly)
            .Where(f => f.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
            .OrderBy(f => f, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (files.Count == 0)
            throw new InvalidOperationException($"No lab mapping JSON files found in {folderPath}");

        var configs = new List<LabMappingConfig>(files.Count);
        var errors = new List<string>();

        foreach (var file in files)
        {
            LabMappingConfig? config;

            try
            {
                config = JsonSerializer.Deserialize<LabMappingConfig>(File.ReadAllText(file), JsonOptions);
            }
            catch (JsonException ex)
            {
                errors.Add($"{Path.GetFileName(file)}: not valid JSON - {ex.Message}");
                continue;
            }

            if (config is null)
            {
                errors.Add($"{Path.GetFileName(file)}: deserialized to null.");
                continue;
            }

            config.SourceFile = Path.GetFileName(file);
            Validate(config, errors);
            configs.Add(config);
        }

        if (errors.Count > 0)
            throw new LabMappingValidationException(errors);

        _logger.LogInformation(
            "Loaded {Count} lab mapping file(s) from {Folder}: {Files}",
            configs.Count, folderPath, string.Join(", ", configs.Select(c => c.SourceFile)));

        return configs;
    }

    private static void Validate(LabMappingConfig config, List<string> errors)
    {
        var file = config.SourceFile;

        if (config.LineLevel is null && config.ClaimLevel is null)
        {
            errors.Add($"{file}: neither LineLevel nor ClaimLevel is present.");
            return;
        }

        ValidateLevel(file, FileTypes.LineLevel, config.LineLevel, errors);
        ValidateLevel(file, FileTypes.ClaimLevel, config.ClaimLevel, errors);
    }

    private static void ValidateLevel(string file, string levelName, LevelMapping? level, List<string> errors)
    {
        if (level is null)
            return;

        // A level that is switched off is not required to be fully configured - that is the point of
        // the toggle. Only validate what the enabled path will actually use.
        if (!level.Enabled)
            return;

        if (level.BulkCopyToTable)
        {
            if (string.IsNullOrWhiteSpace(level.SqlTableName))
            {
                errors.Add($"{file} [{levelName}]: BulkCopyToTable is true but SqlTableName is missing.");
            }
            else if (!TableNamePattern.IsMatch(level.SqlTableName.Trim()))
            {
                errors.Add($"{file} [{levelName}]: SqlTableName '{level.SqlTableName}' is not a valid 'schema.table' identifier.");
            }

            if (level.Fields.Count == 0)
                errors.Add($"{file} [{levelName}]: BulkCopyToTable is true but Fields is empty.");
        }

        if (level.BatchSize <= 0)
            errors.Add($"{file} [{levelName}]: BatchSize must be greater than zero (was {level.BatchSize}).");

        // 0 means "wait forever" in SqlBulkCopy; a stuck load would block the whole run.
        if (level.BulkCopyTimeoutSeconds <= 0)
            errors.Add($"{file} [{levelName}]: BulkCopyTimeoutSeconds must be greater than zero (was {level.BulkCopyTimeoutSeconds}).");

        var seenCsv = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var seenSql = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var field in level.Fields)
        {
            if (string.IsNullOrWhiteSpace(field.CsvHeader))
                errors.Add($"{file} [{levelName}]: a field has an empty CsvHeader (SqlColumn='{field.SqlColumn}').");

            if (string.IsNullOrWhiteSpace(field.SqlColumn))
            {
                errors.Add($"{file} [{levelName}]: a field has an empty SqlColumn (CsvHeader='{field.CsvHeader}').");
                continue;
            }

            var sqlColumn = field.SqlColumn.Trim();

            if (!ColumnNamePattern.IsMatch(sqlColumn))
                errors.Add($"{file} [{levelName}]: SqlColumn '{sqlColumn}' is not a valid SQL identifier.");

            // LabID/LabName are the exception: they are audit columns AND legitimately arrive in the
            // CSV, so the mapping is allowed to carry them. The loader stamps them either way.
            if (AuditColumns.IsPipelineOwned(sqlColumn) &&
                !sqlColumn.Equals(AuditColumns.LabId, StringComparison.OrdinalIgnoreCase) &&
                !sqlColumn.Equals(AuditColumns.LabName, StringComparison.OrdinalIgnoreCase))
            {
                errors.Add($"{file} [{levelName}]: SqlColumn '{sqlColumn}' is stamped by the pipeline and must not be mapped from the CSV.");
            }

            // A repeated CsvHeader is legitimate fan-out: one source column can feed several target
            // columns (e.g. "Payment Posted Date" -> PostingDate AND PaymentPostedDate). Only a
            // repeated SqlColumn is an error, because two fields would fight over one destination.
            if (!string.IsNullOrWhiteSpace(field.CsvHeader))
                seenCsv.Add(field.CsvHeader.Trim());

            if (!seenSql.Add(sqlColumn))
                errors.Add($"{file} [{levelName}]: duplicate SqlColumn '{sqlColumn}'.");
        }

        if (level.BulkCopyToTable && level.Fields.Count > 0 && level.Fields.All(f => !f.IncludeInHash))
            errors.Add($"{file} [{levelName}]: no field is flagged IncludeInHash, so every RowHash would be identical.");
    }
}
