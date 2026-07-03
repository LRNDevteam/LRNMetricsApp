using Microsoft.Extensions.Logging;
using LRN.ExcelValidator.Models;

namespace LRN.ExcelValidator.Services;

public interface IExcelSchemaValidator
{
    SchemaValidationResult Validate(string xlsxPath, string sheetCandidatesCsv, string schemaJsonPath);
}

public sealed class ExcelSchemaValidator : IExcelSchemaValidator
{
    private readonly IColumnSchemaLoader _loader;
    private readonly IExcelHeaderReader _headerReader;
    private readonly ILogger<ExcelSchemaValidator> _logger;

    public ExcelSchemaValidator(IColumnSchemaLoader loader, IExcelHeaderReader headerReader, ILogger<ExcelSchemaValidator> logger)
    {
        _loader = loader;
        _headerReader = headerReader;
        _logger = logger;
    }

    public SchemaValidationResult Validate(string xlsxPath, string sheetCandidatesCsv, string schemaJsonPath)
    {
        var schema = _loader.LoadFromFile(schemaJsonPath);
        var (sheetUsed, headers) = _headerReader.ReadHeader(xlsxPath, sheetCandidatesCsv, schema.HeaderRow);

        var result = new SchemaValidationResult
        {
            SheetUsed = sheetUsed,
            FoundHeaders = headers.ToList()
        };

        if (sheetUsed == null)
        {
            result.MissingRequiredColumns.Add($"Sheet not found. Candidates: {sheetCandidatesCsv}");
            _logger.LogWarning("Schema '{SchemaName}' failed: sheet not found for file {File}", schema.SchemaName, xlsxPath);
            return result;
        }

        var headerSet = new HashSet<string>(headers.Select(Norm), StringComparer.OrdinalIgnoreCase);

        foreach (var col in schema.Columns.Where(c => c.Required))
        {
            var acceptable = new List<string>();
            if (!string.IsNullOrWhiteSpace(col.Name))
                acceptable.Add(col.Name);

            if (col.Aliases != null)
                acceptable.AddRange(col.Aliases.Where(a => !string.IsNullOrWhiteSpace(a)));

            bool found = acceptable.Any(a => headerSet.Contains(Norm(a)));

            if (!found)
                result.MissingRequiredColumns.Add(col.Name);
        }

        if (!result.IsValid)
        {
            _logger.LogWarning("Schema '{SchemaName}' failed for file {File}. Missing={Missing}",
                schema.SchemaName, xlsxPath, string.Join(", ", result.MissingRequiredColumns));
        }

        return result;
    }

    private static string Norm(string s)
    {
        if (string.IsNullOrWhiteSpace(s)) return string.Empty;
        var chars = s.Trim().ToLowerInvariant()
            .Where(char.IsLetterOrDigit)
            .ToArray();
        return new string(chars);
    }
}
