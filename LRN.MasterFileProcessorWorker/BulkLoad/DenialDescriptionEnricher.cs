using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>What one enrichment pass did, for the run log.</summary>
/// <param name="Skipped">True when nothing ran; <paramref name="Message"/> says why.</param>
/// <param name="DistinctCodes">Distinct raw denial cells found in the table.</param>
/// <param name="RowsUpdated">Claim-level rows that received a normalized code.</param>
/// <param name="RowsDescribed">Claim-level rows that received at least one description.</param>
/// <param name="UnresolvedCodes">Normalized codes the master table had no description for.</param>
public sealed record DenialEnrichmentResult(
    bool Skipped,
    string? Message,
    int DistinctCodes,
    long RowsUpdated,
    long RowsDescribed,
    IReadOnlyList<string> UnresolvedCodes);

/// <summary>
/// Fills <c>NormalizedDenialCode</c> and <c>DenialDescription</c> on a lab's claim-level table,
/// immediately after the claim-level bulk copy commits.
///
/// <para><b>Why after the load rather than in the CSV.</b> The description comes from
/// LRNMaster.DenialMapperSuperMaster, which the CSV exporter has no connection to, and the rule has
/// to apply to every lab including the ones sourced from their own database rather than a workbook.
/// Deriving it here means it lands for all of them without editing twelve lab mapping JSONs, and a
/// master-table change can be replayed by re-running the enrichment alone.</para>
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

    /// <summary>Group-prefix-stripped code(s), e.g. "CO10, CO189" -> "10, 189".</summary>
    public const string NormalizedColumn = "DenialCodeNormalized";

    /// <summary>Code/description pairs from the masters, e.g. "10 - ...; 189 - ...".</summary>
    public const string DescriptionColumn = "DenialDescription";

    /// <summary>The lab's own Denial-Action master, in the lab database.</summary>
    private const string LabMasterTable = "DenialCodeMaster";

    /// <summary>The Denial-Action Super Master, in LRNMaster.</summary>
    private const string SuperMasterTable = "DenialMapperSuperMaster";

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
        await EnsureColumnAsync(conn, sqlTableName, target, DescriptionColumn, "nvarchar(max) NULL", ct).ConfigureAwait(false);

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
        var map = new List<(string Raw, string? Normalized, string? Description)>(rawCodes.Count);

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

            map.Add((raw, normalized, DenialCodeNormalizer.DescribeAll(raw, lookup, unresolved)));
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

        var (rowsUpdated, rowsDescribed) = await ApplyMapAsync(conn, target, map, ct).ConfigureAwait(false);

        if (unresolved.Count > 0)
        {
            _logger.LogWarning(
                "Lab {LabId} '{LabName}': {Count} denial code(s) in {Table} have no description in " +
                "either dbo.{LabMaster} or LRNMaster.dbo.{SuperMaster}, and were left undescribed: {Codes}",
                lab.LabId, lab.LabName, unresolved.Count, sqlTableName,
                LabMasterTable, SuperMasterTable, string.Join(", ", unresolved));
        }

        _logger.LogInformation(
            "Lab {LabId} '{LabName}': normalized {Distinct} distinct denial code cell(s) in {Table}; " +
            "{Updated} row(s) carry a normalized code and {Described} carry a description.",
            lab.LabId, lab.LabName, map.Count, sqlTableName, rowsUpdated, rowsDescribed);

        return new DenialEnrichmentResult(false, null, map.Count, rowsUpdated, rowsDescribed,
            unresolved.ToList());
    }

    /// <summary>
    /// Loads both description masters into the four-step cascade: the lab's own Denial-Action
    /// master first, then the Denial-Action Super Master, each matched on the raw code before the
    /// normalized one.
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
        // which is normal - the Super Master covers it.
        await ReadDescriptionsAsync(labConn, LabMasterTable, isActiveFiltered: false,
            (code, description) => lookup.AddLab(code, description), ct).ConfigureAwait(false);

        if (string.IsNullOrWhiteSpace(_masterConnectionString))
        {
            _logger.LogWarning(
                "No DefaultConnection (LRNMaster) connection string; only lab {LabId}'s own " +
                "{LabMaster} can supply denial descriptions.", lab.LabId, LabMasterTable);
        }
        else
        {
            await using var masterConn = new SqlConnection(_masterConnectionString);
            await masterConn.OpenAsync(ct).ConfigureAwait(false);

            await ReadDescriptionsAsync(masterConn, SuperMasterTable, isActiveFiltered: true,
                (code, description) => lookup.AddSuper(code, description), ct).ConfigureAwait(false);
        }

        if (lookup.IsEmpty)
        {
            _logger.LogWarning(
                "Lab {LabId} '{LabName}': neither {LabMaster} nor LRNMaster.dbo.{SuperMaster} has any " +
                "denial descriptions. Codes will be normalized but not described. Import the Denial " +
                "Action Classifier to populate them.",
                lab.LabId, lab.LabName, LabMasterTable, SuperMasterTable);
        }
        else
        {
            _logger.LogInformation(
                "Lab {LabId} '{LabName}': denial descriptions available from {LabCount} lab code(s) " +
                "and {SuperCount} super master code(s).",
                lab.LabId, lab.LabName, lookup.LabCodeCount, lookup.SuperCodeCount);
        }

        return lookup;
    }

    /// <summary>
    /// Reads DenialCode/DenialDescription out of one master table, or does nothing when that table
    /// is not present. A missing master is an expected state, not an error.
    /// </summary>
    private static async Task ReadDescriptionsAsync(
        SqlConnection conn,
        string tableName,
        bool isActiveFiltered,
        Action<string, string> add,
        CancellationToken ct)
    {
        // IsActive exists on the Super Master but not on every lab's DenialCodeMaster, so the filter
        // is only applied where the caller knows the column is there.
        var activeFilter = isActiveFiltered ? "AND IsActive = 1" : string.Empty;

        var sql = $@"
IF OBJECT_ID('dbo.{tableName}', 'U') IS NOT NULL
    SELECT DenialCode, DenialDescription
    FROM   dbo.[{tableName}]
    WHERE  DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''
      AND  DenialDescription IS NOT NULL AND LTRIM(RTRIM(DenialDescription)) <> ''
      {activeFilter};";

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            if (reader.IsDBNull(0) || reader.IsDBNull(1)) continue;
            add(reader.GetString(0), reader.GetString(1));
        }
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
        var sql = $@"
UPDATE {target}
SET    [{NormalizedColumn}] = NULL,
       [{DescriptionColumn}] = NULL
WHERE  [{NormalizedColumn}] IS NOT NULL
   OR  [{DescriptionColumn}] IS NOT NULL;";

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = CommandTimeoutSeconds };
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Bulk copies the raw-code -> derived-values map into a temp table and applies it with one
    /// joined UPDATE. The temp table and the UPDATE share a connection, so #DenialCodeMap lives
    /// exactly as long as this method does.
    /// </summary>
    private static async Task<(long RowsUpdated, long RowsDescribed)> ApplyMapAsync(
        SqlConnection conn,
        string target,
        IReadOnlyList<(string Raw, string? Normalized, string? Description)> map,
        CancellationToken ct)
    {
        var createTemp = $@"
CREATE TABLE #DenialCodeMap
(
    RawCode        nvarchar({MaxCodeLength})       COLLATE DATABASE_DEFAULT NOT NULL,
    NormalizedCode nvarchar({MaxNormalizedLength}) COLLATE DATABASE_DEFAULT NULL,
    Description    nvarchar(max)                   COLLATE DATABASE_DEFAULT NULL
);";

        await using (var cmd = new SqlCommand(createTemp, conn) { CommandTimeout = 60 })
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);

        using (var table = new DataTable())
        {
            table.Columns.Add("RawCode", typeof(string));
            table.Columns.Add("NormalizedCode", typeof(string));
            table.Columns.Add("Description", typeof(string));

            foreach (var (raw, normalized, description) in map)
            {
                table.Rows.Add(
                    raw,
                    (object?)normalized ?? DBNull.Value,
                    (object?)description ?? DBNull.Value);
            }

            using var bulk = new SqlBulkCopy(conn)
            {
                DestinationTableName = "#DenialCodeMap",
                BulkCopyTimeout = CommandTimeoutSeconds
            };

            bulk.ColumnMappings.Add("RawCode", "RawCode");
            bulk.ColumnMappings.Add("NormalizedCode", "NormalizedCode");
            bulk.ColumnMappings.Add("Description", "Description");

            await bulk.WriteToServerAsync(table, ct).ConfigureAwait(false);
        }

        // The join matches the cell the same way it was read - truncated to MaxCodeLength - so a
        // cell longer than that still finds its row instead of silently missing the map.
        var update = $@"
UPDATE t
SET    t.[{NormalizedColumn}] = m.NormalizedCode,
       t.[{DescriptionColumn}] = m.Description
FROM   {target} AS t
JOIN   #DenialCodeMap AS m
       ON m.RawCode = LEFT(CONVERT(nvarchar(4000), t.[{SourceColumn}]), {MaxCodeLength});

SELECT SUM(CASE WHEN [{NormalizedColumn}] IS NOT NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN [{DescriptionColumn}] IS NOT NULL THEN 1 ELSE 0 END)
FROM   {target};";

        long rowsUpdated = 0, rowsDescribed = 0;

        await using (var cmd = new SqlCommand(update, conn) { CommandTimeout = CommandTimeoutSeconds })
        await using (var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false))
        {
            if (await reader.ReadAsync(ct).ConfigureAwait(false))
            {
                rowsUpdated = reader.IsDBNull(0) ? 0 : Convert.ToInt64(reader.GetValue(0));
                rowsDescribed = reader.IsDBNull(1) ? 0 : Convert.ToInt64(reader.GetValue(1));
            }
        }

        await using (var drop = new SqlCommand("DROP TABLE #DenialCodeMap;", conn) { CommandTimeout = 60 })
            await drop.ExecuteNonQueryAsync(ct).ConfigureAwait(false);

        return (rowsUpdated, rowsDescribed);
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
