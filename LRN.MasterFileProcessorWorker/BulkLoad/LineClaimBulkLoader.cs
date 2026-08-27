using System.Data;
using System.Diagnostics;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

public sealed record BulkLoadResult(
    bool Skipped,
    string? SkipReason,
    long RowsRead,
    long RowsInTable,
    TimeSpan Duration,
    IReadOnlyList<string> MissingCsvHeaders,
    IReadOnlyList<string> UnmappedCsvHeaders);

/// <summary>
/// Loads one standardized CSV into a lab's line-level or claim-level table.
/// </summary>
/// <remarks>
/// <para><b>Strategy: TRUNCATE, bulk copy and verify in one transaction.</b></para>
/// <list type="number">
///   <item>TRUNCATE the destination.</item>
///   <item>SqlBulkCopy the CSV straight into it, enlisted in the same transaction.</item>
///   <item>Count the destination and compare with the CSV row count - still inside the transaction.</item>
///   <item>Commit only on a match; otherwise roll back and the table is exactly as it was.</item>
/// </list>
/// <para>This replaced a staging-table-then-swap design. Staging gave the same rollback guarantee
/// but stored a second full copy of every lab's data: on NWL_LRN the two staging tables held 3.3 GB
/// of a 31 GB database and contributed to filling the PRIMARY filegroup. A single transaction gives
/// the same safety at half the storage.</para>
/// <para>The trade is a TABLOCK on the destination for the duration of the load - roughly 25s for a
/// 1.2M row lab - during which readers block unless the database has read-committed snapshot on.
/// The load runs once per lab per run, so that window is acceptable.</para>
/// <para>Truncate scope is per run per level. Discovery confirmed the pipeline produces exactly one
/// line-level and one claim-level CSV per lab per run, so per-file and per-run truncation are
/// equivalent today; keeping it per-load is safe as long as that stays true. If a run ever produces
/// two files of the same level, this must move to truncate-once-per-run.</para>
/// </remarks>
public sealed class LineClaimBulkLoader
{
    private readonly ILogger<LineClaimBulkLoader> _logger;

    public LineClaimBulkLoader(ILogger<LineClaimBulkLoader> logger) => _logger = logger;

    public async Task<BulkLoadResult> LoadAsync(
        ResolvedLab lab,
        LevelMapping level,
        string fileType,
        string csvPath,
        AuditColumns.AuditValues audit,
        CancellationToken ct)
    {
        var stopwatch = Stopwatch.StartNew();

        if (!File.Exists(csvPath))
        {
            return new BulkLoadResult(true, $"CSV not found: {csvPath}", 0, 0, stopwatch.Elapsed,
                Array.Empty<string>(), Array.Empty<string>());
        }

        var target = QuoteTableName(level.SqlTableName);

        await using var conn = new SqlConnection(lab.ConnectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        await EnsureTableExistsAsync(conn, level.SqlTableName, ct).ConfigureAwait(false);

        // AdditionalFields is opt-in on the table, not in config: a lab database that has not had
        // sql/Labs/_Common/03_AdditionalFields.sql applied must keep loading exactly as before
        // rather than fail every row with 'Invalid column name'.
        var captureAdditionalFields = level.CaptureAdditionalFields
            && await ColumnExistsAsync(conn, level.SqlTableName, AuditColumns.AdditionalFields, ct).ConfigureAwait(false);

        if (level.CaptureAdditionalFields && !captureAdditionalFields)
        {
            _logger.LogWarning(
                "Lab {LabId} [{FileType}]: {Table} has no {Column} column, so unmapped CSV columns will be dropped. " +
                "Run sql/Labs/_Common/03_AdditionalFields.sql against this database to capture them.",
                lab.LabId, fileType, level.SqlTableName, AuditColumns.AdditionalFields);
        }

        long rowsRead;
        long finalCount;
        IReadOnlyList<string> missing;
        IReadOnlyList<string> unmapped;

        // TRUNCATE, load and verify all inside ONE transaction. Nothing is committed until the
        // destination row count matches the CSV, so a failure mid-load rolls the table back to
        // exactly what it held before - the same guarantee the old staging table provided, without
        // storing a second copy of every lab's data.
        await using (var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct).ConfigureAwait(false))
        {
            try
            {
                if (level.TruncateBeforeLoad)
                    await ExecuteAsync(conn, tx, $"TRUNCATE TABLE {target};", ct).ConfigureAwait(false);

                using (var reader = new CsvBulkDataReader(csvPath, level.Fields, audit,
                                                          captureAdditionalFields: captureAdditionalFields))
                {
                    missing = reader.MissingCsvHeaders;
                    unmapped = reader.UnmappedCsvHeaders;

                    if (missing.Count > 0)
                    {
                        _logger.LogWarning(
                            "Lab {LabId} [{FileType}]: {Count} mapped field(s) are absent from the CSV and will load as NULL: {Fields}",
                            lab.LabId, fileType, missing.Count, string.Join(", ", missing));
                    }

                    if (reader.ExcludedSensitiveHeaders.Count > 0)
                    {
                        _logger.LogWarning(
                            "Lab {LabId} [{FileType}]: {Count} CSV column(s) DROPPED and not captured, per the sensitive-column policy: {Columns}",
                            lab.LabId, fileType, reader.ExcludedSensitiveHeaders.Count,
                            string.Join(", ", reader.ExcludedSensitiveHeaders));
                    }

                    if (unmapped.Count > 0)
                    {
                        _logger.LogWarning(
                            "Lab {LabId} [{FileType}]: {Count} CSV column(s) have no mapping and will be {Fate}: {Columns}",
                            lab.LabId, fileType, unmapped.Count,
                            captureAdditionalFields ? $"captured as JSON in {AuditColumns.AdditionalFields}" : "dropped",
                            string.Join(", ", unmapped));
                    }

                    // The transaction is passed in, so UseInternalTransaction must NOT be set - the
                    // two are mutually exclusive and SqlBulkCopy would throw.
                    using var bulk = new SqlBulkCopy(
                        conn,
                        SqlBulkCopyOptions.TableLock | SqlBulkCopyOptions.KeepNulls,
                        tx)
                    {
                        DestinationTableName = target,
                        BatchSize = level.BatchSize,
                        BulkCopyTimeout = level.BulkCopyTimeoutSeconds,
                        EnableStreaming = true
                    };

                    // Explicit, by name, for every column - never ordinal.
                    foreach (var columnName in reader.ColumnNames)
                        bulk.ColumnMappings.Add(columnName, columnName);

                    await bulk.WriteToServerAsync(reader, ct).ConfigureAwait(false);
                    rowsRead = reader.RowsRead;

                    // Information, not a warning: trailing blank rows are normal in these
                    // workbooks. It is logged because it is the difference between the row count
                    // in the file and the row count in the table.
                    if (reader.BlankRowsSkipped > 0)
                    {
                        _logger.LogInformation(
                            "Lab {LabId} [{FileType}]: skipped {Skipped} empty row(s); loaded {Loaded}.",
                            lab.LabId, fileType, reader.BlankRowsSkipped, rowsRead);
                    }

                    // One aggregated warning rather than one per row - this can run to six figures.
                    if (reader.RowsMissingIdentity > 0)
                    {
                        _logger.LogWarning(
                            "Lab {LabId} [{FileType}]: {Count} row(s) carried data but no {Columns}. " +
                            "Loaded anyway. First at CSV line(s): {Lines}.",
                            lab.LabId, fileType, reader.RowsMissingIdentity,
                            string.Join("/", reader.IdentityColumns),
                            string.Join(", ", reader.MissingIdentitySampleLines));
                    }
                }

                // Counted inside the transaction so a mismatch can still be rolled back.
                finalCount = await CountAsync(conn, target, ct, tx).ConfigureAwait(false);

                if (finalCount != rowsRead)
                {
                    throw new InvalidOperationException(
                        $"Lab {lab.LabId} [{fileType}]: {level.SqlTableName} would hold {finalCount} rows " +
                        $"but the CSV had {rowsRead}. Rolled back - the table is unchanged.");
                }

                await tx.CommitAsync(ct).ConfigureAwait(false);
            }
            catch
            {
                await tx.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
                throw;
            }
        }

        if (rowsRead == 0)
        {
            _logger.LogWarning(
                "Lab {LabId} [{FileType}]: CSV {Csv} contained no data rows.",
                lab.LabId, fileType, Path.GetFileName(csvPath));

            return new BulkLoadResult(true, "CSV contained no data rows.", 0, 0,
                stopwatch.Elapsed, missing, unmapped);
        }

        stopwatch.Stop();

        _logger.LogInformation(
            "Lab {LabId} [{FileType}]: loaded {Rows} rows into {Table} in {Ms} ms.",
            lab.LabId, fileType, finalCount, level.SqlTableName, stopwatch.ElapsedMilliseconds);

        return new BulkLoadResult(false, null, rowsRead, finalCount, stopwatch.Elapsed, missing, unmapped);
    }

    /// <summary>
    /// Confirms a config-supplied table name exists before it is ever concatenated into a statement.
    /// The name has already passed the identifier whitelist in <see cref="LabMappingLoader"/>; this
    /// is the second gate.
    /// </summary>
    private static async Task EnsureTableExistsAsync(SqlConnection conn, string tableName, CancellationToken ct)
    {
        var parts = tableName.Replace("[", "").Replace("]", "").Split('.', 2);
        var schema = parts.Length == 2 ? parts[0] : "dbo";
        var table = parts.Length == 2 ? parts[1] : parts[0];

        const string sql = @"
SELECT COUNT(1)
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = @Schema AND t.name = @Table;";

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@Schema", SqlDbType.NVarChar, 128).Value = schema;
        cmd.Parameters.Add("@Table", SqlDbType.NVarChar, 128).Value = table;

        var count = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false));

        if (count == 0)
        {
            throw new InvalidOperationException(
                $"Table {tableName} does not exist in database '{conn.Database}'. Run the sql/ deployment scripts for this lab first.");
        }
    }

    /// <summary>True when the table carries the column. Used to keep an optional column optional.</summary>
    private static async Task<bool> ColumnExistsAsync(SqlConnection conn, string tableName, string columnName, CancellationToken ct)
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

    private static async Task ExecuteAsync(SqlConnection conn, SqlTransaction? tx, string sql, CancellationToken ct, int timeoutSeconds = 120)
    {
        await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = timeoutSeconds };
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    private static async Task<long> CountAsync(SqlConnection conn, string quotedTable, CancellationToken ct,
                                               SqlTransaction? tx = null)
    {
        await using var cmd = new SqlCommand($"SELECT COUNT_BIG(1) FROM {quotedTable};", conn, tx) { CommandTimeout = 300 };
        return Convert.ToInt64(await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false));
    }

    private static string QuoteTableName(string tableName)
    {
        var parts = tableName.Replace("[", "").Replace("]", "").Split('.', 2);
        return parts.Length == 2 ? $"[{parts[0]}].[{parts[1]}]" : $"[dbo].[{parts[0]}]";
    }
}
