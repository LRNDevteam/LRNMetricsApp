using System.Data;
using System.Text;
using LRN.MasterFileProcessorWorker.ExcelValidation;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace LRN.MasterFileProcessorWorker.Database;

/// <summary>What a source table looked like when checked against its schema JSON.</summary>
public sealed class TableSchemaValidationResult
{
    public string TableName { get; init; } = "";
    public string SchemaName { get; init; } = "";

    /// <summary>Columns the table actually has, in ordinal order.</summary>
    public List<string> FoundColumns { get; } = new();

    /// <summary>Required schema columns with no column in the table, by any accepted name.</summary>
    public List<string> MissingRequiredColumns { get; } = new();

    /// <summary>Optional schema columns with no column in the table. Recorded, never fatal.</summary>
    public List<string> MissingOptionalColumns { get; } = new();

    /// <summary>
    /// Schema column -> the differently-spelled table column it matched. Both sides normalise to
    /// the same token, so the mapping downstream is unaffected; surfaced only so a reader can see
    /// that e.g. "TotalWO" is being satisfied by "Total WO" rather than wonder where it went.
    /// </summary>
    public List<(string SchemaColumn, string TableColumn)> LooseMatches { get; } = new();

    public bool IsValid => MissingRequiredColumns.Count == 0;
}

/// <summary>
/// Reads a lab's claim-level / line-level master data straight out of that lab's own database,
/// for labs whose <c>MasterDataSource</c> is <c>LabDatabase</c> rather than SharePoint.
///
/// <para>
/// The output is a RAW CSV with the table's own column names as its header row - deliberately the
/// same artefact <see cref="ExcelCsvExporter"/> produces from a workbook sheet. That keeps this
/// change additive: <see cref="StandardCsvExporter"/>, the per-lab field mappings, row hashing and
/// <c>LineClaimBulkLoader</c> all run afterwards exactly as they do for a SharePoint lab, and
/// neither the destination tables nor the mapping JSON need to know where the rows came from.
/// </para>
/// <para>
/// Value formatting is not re-implemented here - it calls straight into
/// <see cref="ExcelCsvExporter.ConvertCellToString"/> and <see cref="ExcelCsvExporter.CsvEscape"/>.
/// Two copies of "how a date or a decimal becomes CSV text" would drift, and the symptom would be
/// a lab's amounts parsing differently depending on which source it was fed from.
/// </para>
/// </summary>
public sealed class LabDatabaseMasterReader
{
    private readonly IColumnSchemaLoader _schemaLoader;
    private readonly ILogger<LabDatabaseMasterReader> _logger;

    /// <summary>A full-table read of a wide master table is slow; it is also once per lab per run.</summary>
    private const int CommandTimeoutSeconds = 900;

    public LabDatabaseMasterReader(IColumnSchemaLoader schemaLoader, ILogger<LabDatabaseMasterReader> logger)
    {
        _schemaLoader = schemaLoader;
        _logger = logger;
    }

    /// <summary>
    /// Checks the table carries every column the schema JSON requires, using the SAME normalisation
    /// the workbook validator uses (letters and digits only, case-insensitive). That is what lets
    /// the table's "Total WO" satisfy the schema's "TotalWO" - the two sides have never agreed on
    /// spacing, and the downstream mapping already copes.
    /// </summary>
    public async Task<TableSchemaValidationResult> ValidateTableAsync(
        string connectionString, string tableName, string schemaJsonPath, CancellationToken ct)
    {
        var schema = _schemaLoader.LoadFromFile(schemaJsonPath);
        var columns = await GetColumnNamesAsync(connectionString, tableName, ct).ConfigureAwait(false);

        var result = new TableSchemaValidationResult
        {
            TableName = tableName,
            SchemaName = schema.SchemaName ?? ""
        };
        result.FoundColumns.AddRange(columns);

        if (columns.Count == 0)
        {
            result.MissingRequiredColumns.Add($"Table not found or has no columns: {tableName}");
            return result;
        }

        // normalised name -> the actual column, so a match can report what it matched.
        var byNorm = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var c in columns)
        {
            var n = Norm(c);
            if (n.Length > 0 && !byNorm.ContainsKey(n)) byNorm[n] = c;
        }

        foreach (var col in schema.Columns)
        {
            var acceptable = new List<string>();
            if (!string.IsNullOrWhiteSpace(col.Name)) acceptable.Add(col.Name);
            if (col.Aliases != null)
                acceptable.AddRange(col.Aliases.Where(a => !string.IsNullOrWhiteSpace(a)));

            string? matched = null;
            foreach (var candidate in acceptable)
            {
                if (byNorm.TryGetValue(Norm(candidate), out var actual)) { matched = actual; break; }
            }

            if (matched is null)
            {
                if (col.Required) result.MissingRequiredColumns.Add(col.Name);
                else result.MissingOptionalColumns.Add(col.Name);
                continue;
            }

            if (!string.Equals(matched, col.Name, StringComparison.Ordinal))
                result.LooseMatches.Add((col.Name, matched));
        }

        if (!result.IsValid)
        {
            _logger.LogWarning(
                "Schema '{SchemaName}' failed for table {Table}. Missing required: {Missing}",
                schema.SchemaName, tableName, string.Join(", ", result.MissingRequiredColumns));
        }

        return result;
    }

    /// <summary>Column names of <paramref name="tableName"/> in ordinal order; empty when it does not exist.</summary>
    public async Task<IReadOnlyList<string>> GetColumnNamesAsync(
        string connectionString, string tableName, CancellationToken ct)
    {
        const string sql = @"
SELECT c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(@Table)
ORDER BY c.column_id;";

        var names = new List<string>();

        await using var con = new SqlConnection(connectionString);
        await con.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@Table", tableName);

        await using var rd = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await rd.ReadAsync(ct).ConfigureAwait(false))
            names.Add(rd.GetString(0));

        return names;
    }

    /// <summary>
    /// Streams the whole table into a raw CSV and returns the row count.
    ///
    /// <para>
    /// The whole table, every run: these masters are full extracts, exactly like the weekly
    /// workbook they replace, and the destination is truncated before the load. A delta would need
    /// a run or week column, and the tables carry none.
    /// </para>
    /// <para>
    /// Streamed with <see cref="CommandBehavior.SequentialAccess"/> and written as it reads - a
    /// wide master table is hundreds of thousands of rows, and materialising it first is how this
    /// step would turn into an OutOfMemoryException on the biggest lab.
    /// </para>
    /// </summary>
    public async Task<long> ExportTableToCsvAsync(
        string connectionString, string tableName, string outputCsvPath, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(outputCsvPath)!);

        // QUOTENAME on the parsed parts, not string concatenation: the table name comes from
        // configuration, and it is the only part of this query that is not a parameter.
        var quoted = QuoteTableName(tableName);

        await using var con = new SqlConnection(connectionString);
        await con.OpenAsync(ct).ConfigureAwait(false);

        await using var cmd = new SqlCommand($"SELECT * FROM {quoted};", con)
        {
            CommandTimeout = CommandTimeoutSeconds
        };

        await using var rd = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct)
                                      .ConfigureAwait(false);

        var headers = new string[rd.FieldCount];
        for (var i = 0; i < rd.FieldCount; i++)
            headers[i] = rd.GetName(i);

        // UTF-8 with BOM, matching the workbook exporter's files so anything reading either one
        // sees the same encoding.
        await using var sw = new StreamWriter(outputCsvPath, false, new UTF8Encoding(true), 1 << 16);

        await sw.WriteLineAsync(string.Join(",", headers.Select(ExcelCsvExporter.CsvEscape)))
                .ConfigureAwait(false);

        long rows = 0;
        var values = new string[rd.FieldCount];

        while (await rd.ReadAsync(ct).ConfigureAwait(false))
        {
            ct.ThrowIfCancellationRequested();

            for (var i = 0; i < rd.FieldCount; i++)
            {
                var raw = await rd.IsDBNullAsync(i, ct).ConfigureAwait(false) ? null : rd.GetValue(i);
                values[i] = ExcelCsvExporter.CsvEscape(
                    ExcelCsvExporter.ConvertCellToString(raw, headers[i], isHeaderRow: false));
            }

            await sw.WriteLineAsync(string.Join(",", values)).ConfigureAwait(false);
            rows++;
        }

        await sw.FlushAsync(ct).ConfigureAwait(false);

        _logger.LogInformation("Exported {Rows:N0} rows from {Table} -> {Path}", rows, tableName, outputCsvPath);
        return rows;
    }

    /// <summary>
    /// "dbo.Cove_Claim_Level_Billing_Master" -> "[dbo].[Cove_Claim_Level_Billing_Master]".
    /// Rejects anything that is not a plain one- or two-part identifier, so a configuration value
    /// can never carry a fragment of SQL into the query it names.
    /// </summary>
    internal static string QuoteTableName(string tableName)
    {
        if (string.IsNullOrWhiteSpace(tableName))
            throw new ArgumentException("Source table name is required.", nameof(tableName));

        var parts = tableName.Split('.', StringSplitOptions.TrimEntries);
        if (parts.Length is < 1 or > 2)
            throw new ArgumentException($"Source table name must be 'schema.table' or 'table': {tableName}", nameof(tableName));

        var quoted = parts.Select(p =>
        {
            var bare = p.Trim().Trim('[', ']').Trim();

            // A whitelist, not a blacklist. Bracket-quoting already neutralises a stray ';' or
            // '--' - SQL Server reads "[Claims; DROP TABLE Claims--]" as one identifier and simply
            // fails to find it - but a name like that is a configuration mistake, and the useful
            // behaviour is to say so here rather than surface it later as "Invalid object name".
            var valid = bare.Length > 0
                     && bare.All(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == ' ')
                     && bare.Any(char.IsLetterOrDigit);

            if (!valid)
                throw new ArgumentException($"Invalid identifier in source table name: {tableName}", nameof(tableName));

            return $"[{bare}]";
        });

        return string.Join(".", quoted);
    }

    /// <summary>
    /// Letters and digits only, lower-cased - character for character what
    /// <c>ExcelSchemaValidator.Norm</c> does, so a table and a workbook are judged by one rule.
    /// </summary>
    private static string Norm(string s)
    {
        if (string.IsNullOrWhiteSpace(s)) return string.Empty;
        return new string(s.Trim().ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
    }
}
