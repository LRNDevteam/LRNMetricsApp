using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>What one enrichment pass did, for the run log.</summary>
/// <param name="Skipped">True when nothing ran; <paramref name="Message"/> says why.</param>
/// <param name="DistinctCodes">Distinct raw denial cells found in the table.</param>
/// <param name="RowsUpdated">Claim-level rows that received a normalized code.</param>
/// <param name="RowsDescribed">Claim-level rows that received at least one description.</param>
/// <param name="UnresolvedCodes">Normalized codes the master table had no description for.</param>
/// <param name="RowsCategorized">Rows that received a denial action category.</param>
public sealed record DenialEnrichmentResult(
    bool Skipped,
    string? Message,
    int DistinctCodes,
    long RowsUpdated,
    long RowsDescribed,
    IReadOnlyList<string> UnresolvedCodes,
    long RowsCategorized = 0);

/// <summary>
/// Fills the derived denial columns on a lab's claim-level and line-level tables, immediately after
/// each level's bulk copy commits:
/// <list type="bullet">
///   <item><c>DenialCodeNormalized</c> - the group-prefix-stripped code(s).</item>
///   <item><c>DenialDescription</c> and <c>DenialActionCategory</c> - from LRNMaster.dbo.DenialCategoryMaster,
///         matched on the normalized code; codes it lacks fall back to the Denial-Action masters.</item>
///   <item><c>DenialActionCode</c>, <c>DenialSLA</c>, <c>DenialPriority</c> - from the lab's
///         DenialCodeMaster, then LRNMaster.dbo.DenialMapperSuperMaster, as before.</item>
/// </list>
/// Every value is the text alone (never "code - text"); a multi-code cell joins its values with "; ".
///
/// <para><b>Why after the load rather than in the CSV.</b> The values come from LRNMaster masters,
/// which the CSV exporter has no connection to, and the rule has to apply to every lab including the
/// ones sourced from their own database rather than a workbook. Deriving it here means it lands for
/// all of them without editing twelve lab mapping JSONs, and a master-table change can be replayed
/// by re-running the enrichment alone.</para>
///
/// <para><b>Why set-based.</b> A lab's claim-level table runs to seven figures, but the number of
/// DISTINCT denial cells in it is in the low thousands. The pass reads those distinct values,
/// normalizes and describes them in memory, bulk copies the small result into a temp table and
/// applies it with one joined UPDATE - so the per-row cost is a hash join, not a round trip.</para>
///
/// <para>The columns are created if the lab database has not got them yet, in the same lazily
/// -created, re-runnable style the rest of this repo uses for schema that has to keep step with a
/// deployed script (<c>sql/Labs/_Common/04_DenialNormalization.sql</c>).</para>
///
/// <para>Enrichment never fails the import. The rows are already committed when it runs; a master
/// lookup outage or a permissions gap costs descriptions, not the load, so every failure is
/// reported and swallowed by the caller.</para>
/// </summary>
public sealed class DenialDescriptionEnricher
{
    /// <summary>The raw code the lab's ETL loaded, which everything here is derived from.</summary>
    private const string SourceColumn = "DenialCode";

    /// <summary>Group-prefix-stripped code(s), e.g. "CO10, CO189" -> "10; 189".</summary>
    public const string NormalizedColumn = "DenialCodeNormalized";

    /// <summary>The description of each code, text only, e.g. "Description of 10; Description of 189".</summary>
    public const string DescriptionColumn = "DenialDescription";

    /// <summary>Action category of each code (Denial Category Master, else the Denial-Action masters).</summary>
    public const string ActionCategoryColumn = "DenialActionCategory";

    /// <summary>Action code of each code (Denial-Action masters).</summary>
    public const string ActionCodeColumn = "DenialActionCode";

    /// <summary>SLA of each code (Denial-Action masters).</summary>
    public const string SlaColumn = "DenialSLA";

    /// <summary>Priority of each code (Denial-Action masters).</summary>
    public const string PriorityColumn = "DenialPriority";

    /// <summary>The lab's own Denial-Action master, in the lab database.</summary>
    private const string LabMasterTable = "DenialCodeMaster";

    /// <summary>The Denial-Action Super Master, in LRNMaster.</summary>
    private const string SuperMasterTable = "DenialMapperSuperMaster";

    /// <summary>The Denial Category Master (description + action category), in LRNMaster.</summary>
    private const string CategoryMasterTable = "DenialCategoryMaster";

    /// <summary>Derived text columns besides the normalized code: name, width, and how each is picked.</summary>
    private static readonly (string Column, int Width, Func<DenialDerivedValues, string?> Value)[] DerivedColumns =
    [
        (DescriptionColumn, -1, v => v.Description),
        (ActionCategoryColumn, 2000, v => v.ActionCategory),
        (ActionCodeColumn, 400, v => v.ActionCode),
        (SlaColumn, 200, v => v.Sla),
        (PriorityColumn, 200, v => v.Priority)
    ];

    /// <summary>
    /// A denial cell longer than this is not a denial code list; it is a free-text note that landed
    /// in the wrong column. Truncating the join key rather than widening it keeps the temp table
    /// join cheap and stops one malformed row forcing an nvarchar(max) join for the whole lab.
    /// </summary>
    private const int MaxCodeLength = 1000;

    /// <summary>
    /// Width of the <see cref="NormalizedColumn"/>, and the cap applied to what is written to it.
    /// <para>400 characters is roughly 57 codes at "189, " apiece - far more than any real claim
    /// carries - and it is what lets the column be indexed: a nonclustered index key tops out at
    /// 1700 bytes, so an nvarchar wider than 850 cannot be a key column at all. 400 leaves room
    /// under that ceiling for the index to stay valid rather than merely warned about.</para>
    /// </summary>
    private const int MaxNormalizedLength = 400;

    private const int CommandTimeoutSeconds = 900;

    private readonly ILogger<DenialDescriptionEnricher> _logger;
    private readonly string? _masterConnectionString;

    public DenialDescriptionEnricher(IConfiguration configuration, ILogger<DenialDescriptionEnricher> logger)
    {
        _logger = logger;

        // DefaultConnection is LRNMaster - the same connection LabRegistry reads dbo.Labs from.
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection");
    }

    public async Task<DenialEnrichmentResult> EnrichAsync(
        ResolvedLab lab,
        string sqlTableName,
        CancellationToken ct)
    {
        var target = QuoteTableName(sqlTableName);

        await using var conn = new SqlConnection(lab.ConnectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        if (!await ColumnExistsAsync(conn, sqlTableName, SourceColumn, ct).ConfigureAwait(false))
        {
            return new DenialEnrichmentResult(true,
                $"{sqlTableName} has no {SourceColumn} column; nothing to normalize.",
                0, 0, 0, Array.Empty<string>());
        }

        await EnsureColumnAsync(conn, sqlTableName, target, NormalizedColumn, $"nvarchar({MaxNormalizedLength}) NULL", ct).ConfigureAwait(false);
        foreach (var (column, width, _) in DerivedColumns)
            await EnsureColumnAsync(conn, sqlTableName, target, column, $"{SqlType(width)} NULL", ct).ConfigureAwait(false);

        var rawCodes = await ReadDistinctDenialCodesAsync(conn, target, ct).ConfigureAwait(false);

        if (rawCodes.Count == 0)
        {
            // Still clear the derived columns: a lab whose load does not truncate could be carrying
            // values from a previous run whose denial codes have since gone.
            await ClearDerivedAsync(conn, target, ct).ConfigureAwait(false);

            return new DenialEnrichmentResult(true,
                $"No denial codes present in {sqlTableName}.", 0, 0, 0, Array.Empty<string>());
        }

        var lookup = await BuildDescriptionLookupAsync(conn, lab, ct).ConfigureAwait(false);

        var unresolved = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        var map = new List<(string Raw, string? Normalized, DenialDerivedValues Values)>(rawCodes.Count);

        var overlong = 0;

        foreach (var raw in rawCodes)
        {
            var normalized = DenialCodeNormalizer.NormalizeAll(raw);

            // The column is narrow enough to be indexed, so a pathological cell - a free-text note
            // in the denial column, say - is capped here rather than failing the whole UPDATE with
            // "String or binary data would be truncated".
            if (normalized is { Length: > MaxNormalizedLength })
            {
                normalized = normalized[..MaxNormalizedLength];
                overlong++;
            }

            map.Add((raw, normalized, DenialCodeNormalizer.DeriveAll(raw, lookup, unresolved)));
        }

        if (overlong > 0)
        {
            _logger.LogWarning(
                "Lab {LabId} '{LabName}': {Count} denial code cell(s) normalized to more than {Max} " +
                "characters and were truncated in {Column}. That usually means free text reached the " +
                "denial code column - the raw {Source} value is unchanged.",
                lab.LabId, lab.LabName, overlong, MaxNormalizedLength, NormalizedColumn, SourceColumn);
        }

        // Every derived value is rewritten from the raw column each run, so the pass is idempotent
        // and a re-run after a master-table correction fixes the descriptions in place.
        await ClearDerivedAsync(conn, target, ct).ConfigureAwait(false);

        var (rowsUpdated, rowsDescribed, rowsCategorized) = await ApplyMapAsync(conn, target, map, ct).ConfigureAwait(false);

        if (unresolved.Count > 0)
        {
            _logger.LogWarning(
                "Lab {LabId} '{LabName}': {Count} denial code(s) in {Table} have no description in " +
                "LRNMaster.dbo.{CategoryMaster}, dbo.{LabMaster} or LRNMaster.dbo.{SuperMaster}, and were left undescribed: {Codes}",
                lab.LabId, lab.LabName, unresolved.Count, sqlTableName,
                CategoryMasterTable, LabMasterTable, SuperMasterTable, string.Join(", ", unresolved));
        }

        _logger.LogInformation(
            "Lab {LabId} '{LabName}': normalized {Distinct} distinct denial code cell(s) in {Table}; " +
            "{Updated} row(s) carry a normalized code, {Described} a description and {Categorized} an action category.",
            lab.LabId, lab.LabName, map.Count, sqlTableName, rowsUpdated, rowsDescribed, rowsCategorized);

        return new DenialEnrichmentResult(false, null, map.Count, rowsUpdated, rowsDescribed,
            unresolved.ToList(), rowsCategorized);
    }

    private static string SqlType(int width) => width < 0 ? "nvarchar(max)" : $"nvarchar({width})";

    /// <summary>
    /// Loads the masters into the lookup: the Denial Category Master (description + action
    /// category, by normalized code), then the Denial-Action cascade - the lab's own Denial-Action
    /// master and the Denial-Action Super Master - for action code, SLA, priority and the fallback
    /// description / category.
    /// </summary>
    /// <param name="labConn">
    /// The already-open lab connection. The lab's master lives in the same database as the
    /// claim-level table, so it is read on this connection rather than opening a second one.
    /// </param>
    private async Task<DenialDescriptionLookup> BuildDescriptionLookupAsync(
        SqlConnection labConn, ResolvedLab lab, CancellationToken ct)
    {
        var lookup = new DenialDescriptionLookup();

        // The lab's own Denial-Action master. Absent on a lab that has never imported a classifier,
        // which is normal - the Super Master covers it. Its columns: ActionCode, ActionCategory,
        // Priority, SLADays (each read only when the lab's table has it).
        await ReadMasterAsync(labConn, LabMasterTable, isActiveFiltered: false,
            new MasterColumns("DenialDescription", "ActionCategory", "ActionCode", "SLADays", "Priority", OrderBy: null),
            (code, info) => lookup.AddLab(code, info), ct).ConfigureAwait(false);

        if (string.IsNullOrWhiteSpace(_masterConnectionString))
        {
            _logger.LogWarning(
                "No DefaultConnection (LRNMaster) connection string; only lab {LabId}'s own " +
                "{LabMaster} can supply denial descriptions and actions.", lab.LabId, LabMasterTable);
        }
        else
        {
            await using var masterConn = new SqlConnection(_masterConnectionString);
            await masterConn.OpenAsync(ct).ConfigureAwait(false);

            // Denial Category Master: description + action category. Absent until
            // DenialCategoryMaster_Setup.sql has run, in which case the Denial-Action masters
            // describe every code as before.
            await ReadMasterAsync(masterConn, CategoryMasterTable, isActiveFiltered: false,
                new MasterColumns("Description", "ActionCategory", null, null, null, OrderBy: "DenialCategoryMasterId"),
                (code, info) => lookup.AddCategory(code, info.Description, info.ActionCategory), ct).ConfigureAwait(false);

            // Newest row first, so where the Super Master holds a code twice the latest edit wins.
            await ReadMasterAsync(masterConn, SuperMasterTable, isActiveFiltered: true,
                new MasterColumns("DenialDescription", "ActionCategory", "ActionCode", "SLA", "Priority", OrderBy: "ModifiedOn DESC"),
                (code, info) => lookup.AddSuper(code, info), ct).ConfigureAwait(false);
        }

        if (lookup.IsEmpty)
        {
            _logger.LogWarning(
                "Lab {LabId} '{LabName}': none of LRNMaster.dbo.{CategoryMaster}, {LabMaster} or LRNMaster.dbo.{SuperMaster} " +
                "has any denial codes. Codes will be normalized but not described.",
                lab.LabId, lab.LabName, CategoryMasterTable, LabMasterTable, SuperMasterTable);
        }
        else
        {
            if (lookup.CategoryCodeCount == 0)
            {
                _logger.LogWarning(
                    "Lab {LabId} '{LabName}': LRNMaster.dbo.{CategoryMaster} is missing or empty; denial " +
                    "descriptions and action categories fall back to the Denial-Action masters. Import the " +
                    "denial codes workbook on the Denial Category Master screen.",
                    lab.LabId, lab.LabName, CategoryMasterTable);
            }

            _logger.LogInformation(
                "Lab {LabId} '{LabName}': denial codes available from {CategoryCount} category master code(s), " +
                "{LabCount} lab code(s) and {SuperCount} super master code(s).",
                lab.LabId, lab.LabName, lookup.CategoryCodeCount, lookup.LabCodeCount, lookup.SuperCodeCount);
        }

        return lookup;
    }

    /// <summary>
    /// Which column of a master holds each value; null where the master has no such value. A
    /// column the table does not actually have is read as NULL, so an older lab DenialCodeMaster
    /// without, say, SLADays still supplies what it has.
    /// </summary>
    private sealed record MasterColumns(
        string Description, string? ActionCategory, string? ActionCode, string? Sla, string? Priority, string? OrderBy);

    /// <summary>
    /// Reads one master table into the lookup, or does nothing when that table is not present. A
    /// missing master is an expected state, not an error.
    /// </summary>
    private static async Task ReadMasterAsync(
        SqlConnection conn,
        string tableName,
        bool isActiveFiltered,
        MasterColumns columns,
        Action<string, DenialCodeInfo> add,
        CancellationToken ct)
    {
        await using (var exists = new SqlCommand("SELECT OBJECT_ID(@Name, 'U');", conn))
        {
            exists.Parameters.Add("@Name", SqlDbType.NVarChar, 300).Value = $"dbo.{tableName}";
            if (await exists.ExecuteScalarAsync(ct).ConfigureAwait(false) is null or DBNull) return;
        }

        var present = await GetColumnsAsync(conn, tableName, ct).ConfigureAwait(false);
        string Col(string? name) => name is not null && present.Contains(name)
            ? $"CONVERT(nvarchar(max), [{name}])"
            : "CAST(NULL AS nvarchar(max))";

        // IsActive exists on the Super Master but not on every lab's DenialCodeMaster, so the filter
        // is only applied where the caller knows the column is there.
        var activeFilter = isActiveFiltered && present.Contains("IsActive") ? "AND IsActive = 1" : string.Empty;
        var orderColumn = columns.OrderBy?.Split(' ')[0];
        var orderBy = orderColumn is not null && present.Contains(orderColumn) ? $"ORDER BY {columns.OrderBy}" : string.Empty;

        var sql = $@"
SELECT DenialCode, {Col(columns.Description)}, {Col(columns.ActionCategory)}, {Col(columns.ActionCode)},
       {Col(columns.Sla)}, {Col(columns.Priority)}
FROM   dbo.[{tableName}]
WHERE  DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''
       {activeFilter}
{orderBy};";

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        string? Text(int i) => reader.IsDBNull(i) ? null : reader.GetString(i);

        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            if (reader.IsDBNull(0)) continue;
            add(Convert.ToString(reader.GetValue(0), System.Globalization.CultureInfo.InvariantCulture) ?? string.Empty,
                new DenialCodeInfo(Text(1), Text(2), Text(3), Text(4), Text(5)));
        }
    }

    private static async Task<HashSet<string>> GetColumnsAsync(SqlConnection conn, string tableName, CancellationToken ct)
    {
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using var cmd = new SqlCommand("SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(@Name);", conn);
        cmd.Parameters.Add("@Name", SqlDbType.NVarChar, 300).Value = $"dbo.{tableName}";
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false)) columns.Add(reader.GetString(0));
        return columns;
    }

    private static async Task<List<string>> ReadDistinctDenialCodesAsync(
        SqlConnection conn, string target, CancellationToken ct)
    {
        // DISTINCT over the raw cell, not over the individual codes: the cell is what the UPDATE
        // joins on, and a million-row lab still only has a few thousand distinct cells.
        var sql = $@"
SELECT DISTINCT LEFT(CONVERT(nvarchar(4000), [{SourceColumn}]), {MaxCodeLength})
FROM   {target}
WHERE  [{SourceColumn}] IS NOT NULL
  AND  LTRIM(RTRIM(CONVERT(nvarchar(4000), [{SourceColumn}]))) <> '';";

        var codes = new List<string>();

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = CommandTimeoutSeconds };
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            if (!reader.IsDBNull(0)) codes.Add(reader.GetString(0));
        }

        return codes;
    }

    private static async Task ClearDerivedAsync(SqlConnection conn, string target, CancellationToken ct)
    {
        var columns = new[] { NormalizedColumn }.Concat(DerivedColumns.Select(c => c.Column)).ToList();
        var sql = $@"
UPDATE {target}
SET    {string.Join(",\n       ", columns.Select(c => $"[{c}] = NULL"))}
WHERE  {string.Join("\n   OR  ", columns.Select(c => $"[{c}] IS NOT NULL"))};";

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = CommandTimeoutSeconds };
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Bulk copies the raw-code -> derived-values map into a temp table and applies it with one
    /// joined UPDATE. The temp table and the UPDATE share a connection, so #DenialCodeMap lives
    /// exactly as long as this method does.
    /// </summary>
    private static async Task<(long RowsUpdated, long RowsDescribed, long RowsCategorized)> ApplyMapAsync(
        SqlConnection conn,
        string target,
        IReadOnlyList<(string Raw, string? Normalized, DenialDerivedValues Values)> map,
        CancellationToken ct)
    {
        var derivedDefs = string.Concat(DerivedColumns.Select(c =>
            $",\n    [{c.Column}] {SqlType(c.Width)} COLLATE DATABASE_DEFAULT NULL"));

        var createTemp = $@"
CREATE TABLE #DenialCodeMap
(
    RawCode        nvarchar({MaxCodeLength})       COLLATE DATABASE_DEFAULT NOT NULL,
    NormalizedCode nvarchar({MaxNormalizedLength}) COLLATE DATABASE_DEFAULT NULL{derivedDefs}
);";

        await using (var cmd = new SqlCommand(createTemp, conn) { CommandTimeout = 60 })
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);

        using (var table = new DataTable())
        {
            table.Columns.Add("RawCode", typeof(string));
            table.Columns.Add("NormalizedCode", typeof(string));
            foreach (var (column, _, _) in DerivedColumns) table.Columns.Add(column, typeof(string));

            foreach (var (raw, normalized, values) in map)
            {
                var row = table.NewRow();
                row["RawCode"] = raw;
                row["NormalizedCode"] = (object?)normalized ?? DBNull.Value;
                foreach (var (column, width, pick) in DerivedColumns)
                {
                    // Capped to the column width, so one long multi-code cell cannot fail the UPDATE.
                    var value = pick(values);
                    if (value is not null && width > 0 && value.Length > width) value = value[..width];
                    row[column] = (object?)value ?? DBNull.Value;
                }
                table.Rows.Add(row);
            }

            using var bulk = new SqlBulkCopy(conn)
            {
                DestinationTableName = "#DenialCodeMap",
                BulkCopyTimeout = CommandTimeoutSeconds
            };

            foreach (DataColumn column in table.Columns)
                bulk.ColumnMappings.Add(column.ColumnName, column.ColumnName);

            await bulk.WriteToServerAsync(table, ct).ConfigureAwait(false);
        }

        // The join matches the cell the same way it was read - truncated to MaxCodeLength - so a
        // cell longer than that still finds its row instead of silently missing the map.
        var sets = string.Concat(DerivedColumns.Select(c => $",\n       t.[{c.Column}] = m.[{c.Column}]"));
        var update = $@"
UPDATE t
SET    t.[{NormalizedColumn}] = m.NormalizedCode{sets}
FROM   {target} AS t
JOIN   #DenialCodeMap AS m
       ON m.RawCode = LEFT(CONVERT(nvarchar(4000), t.[{SourceColumn}]), {MaxCodeLength});

SELECT SUM(CASE WHEN [{NormalizedColumn}] IS NOT NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN [{DescriptionColumn}] IS NOT NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN [{ActionCategoryColumn}] IS NOT NULL THEN 1 ELSE 0 END)
FROM   {target};";

        long rowsUpdated = 0, rowsDescribed = 0, rowsCategorized = 0;

        await using (var cmd = new SqlCommand(update, conn) { CommandTimeout = CommandTimeoutSeconds })
        await using (var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false))
        {
            if (await reader.ReadAsync(ct).ConfigureAwait(false))
            {
                rowsUpdated = reader.IsDBNull(0) ? 0 : Convert.ToInt64(reader.GetValue(0));
                rowsDescribed = reader.IsDBNull(1) ? 0 : Convert.ToInt64(reader.GetValue(1));
                rowsCategorized = reader.IsDBNull(2) ? 0 : Convert.ToInt64(reader.GetValue(2));
            }
        }

        await using (var drop = new SqlCommand("DROP TABLE #DenialCodeMap;", conn) { CommandTimeout = 60 })
            await drop.ExecuteNonQueryAsync(ct).ConfigureAwait(false);

        return (rowsUpdated, rowsDescribed, rowsCategorized);
    }

    /// <summary>
    /// Adds the column when the lab database has not had the deployment script applied yet.
    /// Re-runnable, and a no-op on every run after the first.
    /// </summary>
    private async Task EnsureColumnAsync(
        SqlConnection conn, string tableName, string quotedTable,
        string columnName, string definition, CancellationToken ct)
    {
        if (await ColumnExistsAsync(conn, tableName, columnName, ct).ConfigureAwait(false))
            return;

        var sql = $"ALTER TABLE {quotedTable} ADD [{columnName}] {definition};";

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);

        _logger.LogInformation(
            "Added column {Column} to {Table} in database '{Database}'.",
            columnName, tableName, conn.Database);
    }

    private static async Task<bool> ColumnExistsAsync(
        SqlConnection conn, string tableName, string columnName, CancellationToken ct)
    {
        var parts = tableName.Replace("[", "").Replace("]", "").Split('.', 2);
        var schema = parts.Length == 2 ? parts[0] : "dbo";
        var table = parts.Length == 2 ? parts[1] : parts[0];

        const string sql = @"
SELECT COUNT(1)
FROM sys.columns c
JOIN sys.tables t  ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = @Schema AND t.name = @Table AND c.name = @Column;";

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@Schema", SqlDbType.NVarChar, 128).Value = schema;
        cmd.Parameters.Add("@Table", SqlDbType.NVarChar, 128).Value = table;
        cmd.Parameters.Add("@Column", SqlDbType.NVarChar, 128).Value = columnName;

        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false)) > 0;
    }

    private static string QuoteTableName(string tableName)
    {
        var parts = tableName.Replace("[", "").Replace("]", "").Split('.', 2);
        return parts.Length == 2 ? $"[{parts[0]}].[{parts[1]}]" : $"[dbo].[{parts[0]}]";
    }
}
