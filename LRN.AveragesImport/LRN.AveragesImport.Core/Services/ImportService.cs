using System.Data;
using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Data;
using LRN.AveragesImport.Core.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.AveragesImport.Core.Services;

public interface IImportService
{
    /// <summary>
    /// True when this lab+run has already been generated — either a Success row exists
    /// in AverageImportLog, or the target table already holds rows stamped with the RunId.
    /// </summary>
    Task<bool> IsAlreadyImportedAsync(string runId, int labId, string fileType, CancellationToken ct);

    Task<ImportResult> ImportCptAveragesAsync(
        LabRunInfo run, string source, IReadOnlyList<CptAverageRecord> records, CancellationToken ct);

    Task<ImportResult> ImportPanelAveragesAsync(
        LabRunInfo run, string source, IReadOnlyList<PanelAverageRecord> records, CancellationToken ct);

    /// <summary>Writes a Failed row to AverageImportLog (outside any transaction). Never throws.</summary>
    Task RecordFailureAsync(LabRunInfo run, string fileType, string? source, string error, CancellationToken ct);
}

public sealed class ImportService : IImportService
{
    private readonly ISqlConnectionFactory _connectionFactory;
    private readonly ILogger<ImportService> _logger;
    private readonly IOptions<ImportSettings> _settings;

    public ImportService(
        ISqlConnectionFactory connectionFactory,
        ILogger<ImportService> logger,
        IOptions<ImportSettings> settings)
    {
        _connectionFactory = connectionFactory;
        _logger = logger;
        _settings = settings;
    }

    /// <summary>
    /// Two guards, because either can be true on its own: the log records a run that
    /// legitimately produced zero rows, and the target table records rows whose log
    /// entry was lost. Both are checked so a lab+run is never generated twice.
    /// </summary>
    public async Task<bool> IsAlreadyImportedAsync(string runId, int labId, string fileType, CancellationToken ct)
    {
        var targetTable = fileType == FileTypes.CptAverage ? "CPTAverage" : "PanelAverage";
        var labIdColumn = fileType == FileTypes.CptAverage ? "LabID" : "LabId";

        var sql = $@"
SELECT CASE WHEN EXISTS (
           SELECT 1 FROM AverageImportLog
           WHERE RunId = @RunId AND LabId = @LabId AND FileType = @FileType AND Status = 'Success')
        OR EXISTS (
           SELECT 1 FROM {targetTable}
           WHERE {labIdColumn} = @LabId AND RunId = @RunId)
       THEN 1 ELSE 0 END;";

        await using var connection = _connectionFactory.Create();
        await connection.OpenAsync(ct);

        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@RunId", runId);
        command.Parameters.AddWithValue("@LabId", labId);
        command.Parameters.AddWithValue("@FileType", fileType);

        return (int)(await command.ExecuteScalarAsync(ct) ?? 0) == 1;
    }

    public Task<ImportResult> ImportCptAveragesAsync(
        LabRunInfo run, string source, IReadOnlyList<CptAverageRecord> records, CancellationToken ct)
        => ImportAsync(run, FileTypes.CptAverage, "CPTAverage", "LabID", source,
            BuildCptTable(records, run), records.Count, ct);

    public Task<ImportResult> ImportPanelAveragesAsync(
        LabRunInfo run, string source, IReadOnlyList<PanelAverageRecord> records, CancellationToken ct)
        => ImportAsync(run, FileTypes.PanelAverage, "PanelAverage", "LabId", source,
            BuildPanelTable(records, run), records.Count, ct);

    /// <summary>
    /// Atomic per lab per aggregate: DELETE existing rows for the LabId, bulk-insert the
    /// freshly computed rows, and write the Success log row — all in one SqlTransaction.
    /// </summary>
    private async Task<ImportResult> ImportAsync(
        LabRunInfo run,
        string fileType,
        string targetTable,
        string labIdColumn,
        string source,
        DataTable table,
        int recordCount,
        CancellationToken ct)
    {
        await using var connection = _connectionFactory.Create();
        await connection.OpenAsync(ct);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(ct);

        try
        {
            await using (var delete = new SqlCommand(
                $"DELETE FROM {targetTable} WHERE {labIdColumn} = @LabId;", connection, transaction))
            {
                delete.CommandTimeout = 300;
                delete.Parameters.AddWithValue("@LabId", run.LabId);
                var deleted = await delete.ExecuteNonQueryAsync(ct);
                _logger.LogInformation("Deleted {Deleted} existing {Table} rows for LabId {LabId}",
                    deleted, targetTable, run.LabId);
            }

            using (var bulkCopy = new SqlBulkCopy(connection, SqlBulkCopyOptions.Default, transaction))
            {
                bulkCopy.DestinationTableName = targetTable;
                bulkCopy.BatchSize = _settings.Value.BulkCopyBatchSize;
                bulkCopy.BulkCopyTimeout = 600;
                foreach (DataColumn column in table.Columns)
                    bulkCopy.ColumnMappings.Add(column.ColumnName, column.ColumnName);

                await bulkCopy.WriteToServerAsync(table, ct);
            }

            await InsertLogRowAsync(connection, transaction, run, fileType, source, recordCount, "Success", null, ct);

            await transaction.CommitAsync(ct);

            _logger.LogInformation(
                "Imported {Rows} {FileType} rows for {LabName} (LabId {LabId}, RunId {RunId}) from {Source}",
                recordCount, fileType, run.LabName, run.LabId, run.RunId, source);

            return new ImportResult
            {
                RunId = run.RunId,
                LabId = run.LabId,
                LabName = run.LabName,
                FileType = fileType,
                Status = ImportStatus.Imported,
                RowsImported = recordCount,
                Source = source
            };
        }
        catch (Exception ex)
        {
            try { await transaction.RollbackAsync(CancellationToken.None); }
            catch (Exception rollbackEx)
            {
                _logger.LogError(rollbackEx, "Rollback failed for {FileType} import of RunId {RunId}, LabId {LabId}",
                    fileType, run.RunId, run.LabId);
            }

            _logger.LogError(ex, "Import failed for {FileType}, RunId {RunId}, LabId {LabId}, source {Source} — rolled back",
                fileType, run.RunId, run.LabId, source);

            await RecordFailureAsync(run, fileType, source, ex.Message, ct);

            return new ImportResult
            {
                RunId = run.RunId,
                LabId = run.LabId,
                LabName = run.LabName,
                FileType = fileType,
                Status = ImportStatus.Failed,
                Source = source,
                Error = ex.Message
            };
        }
    }

    public async Task RecordFailureAsync(LabRunInfo run, string fileType, string? source, string error, CancellationToken ct)
    {
        try
        {
            await using var connection = _connectionFactory.Create();
            await connection.OpenAsync(ct);
            await InsertLogRowAsync(connection, transaction: null, run, fileType, source, recordCount: null,
                status: "Failed", error, ct);
        }
        catch (Exception logEx)
        {
            _logger.LogError(logEx, "Could not write Failed row to AverageImportLog for RunId {RunId}, LabId {LabId}, {FileType}",
                run.RunId, run.LabId, fileType);
        }
    }

    /// <summary>
    /// AverageImportLog.FileName predates the move off CSV; it now records the
    /// source table the aggregate was computed from.
    /// </summary>
    private static async Task InsertLogRowAsync(
        SqlConnection connection,
        SqlTransaction? transaction,
        LabRunInfo run,
        string fileType,
        string? source,
        int? recordCount,
        string status,
        string? error,
        CancellationToken ct)
    {
        const string sql = @"
INSERT INTO AverageImportLog (RunId, LabId, LabName, FileType, FileName, RecordCount, Status, ErrorMessage)
VALUES (@RunId, @LabId, @LabName, @FileType, @FileName, @RecordCount, @Status, @ErrorMessage);";

        await using var command = new SqlCommand(sql, connection, transaction);
        command.Parameters.AddWithValue("@RunId", run.RunId);
        command.Parameters.AddWithValue("@LabId", run.LabId);
        command.Parameters.AddWithValue("@LabName", (object?)run.LabName ?? DBNull.Value);
        command.Parameters.AddWithValue("@FileType", fileType);
        command.Parameters.AddWithValue("@FileName", (object?)source ?? DBNull.Value);
        command.Parameters.AddWithValue("@RecordCount", (object?)recordCount ?? DBNull.Value);
        command.Parameters.AddWithValue("@Status", status);
        command.Parameters.AddWithValue("@ErrorMessage", (object?)error ?? DBNull.Value);
        await command.ExecuteNonQueryAsync(ct);
    }

    private static DataTable BuildCptTable(IReadOnlyList<CptAverageRecord> records, LabRunInfo run)
    {
        var table = new DataTable();
        table.Columns.Add("LabID", typeof(int));
        table.Columns.Add("LabName", typeof(string));
        table.Columns.Add("RunId", typeof(string));
        table.Columns.Add("CPTCode", typeof(string));
        table.Columns.Add("AvgUnits", typeof(int));
        table.Columns.Add("PanelName", typeof(string));
        table.Columns.Add("PayerCommonCode", typeof(string));
        table.Columns.Add("PayerDisplayName", typeof(string));
        table.Columns.Add("Global_Payer_ID", typeof(int));
        table.Columns.Add("WindowBasis", typeof(string));
        table.Columns.Add("WindowType", typeof(string));
        table.Columns.Add("StartDate", typeof(DateTime));
        table.Columns.Add("EndDate", typeof(DateTime));
        table.Columns.Add("AsOfDateTime", typeof(DateTime));
        table.Columns.Add("PaidLineCount", typeof(int));
        table.Columns.Add("AvgChargeAmountPerUnit", typeof(decimal));
        table.Columns.Add("AvgPaidAmountPerUnit", typeof(decimal));
        table.Columns.Add("AvgAllowedAmountPerUnit", typeof(decimal));
        table.Columns.Add("AvgPatientPaidAmountPerUnit", typeof(decimal));
        table.Columns.Add("AvgPatientResponsibilityPerUnit", typeof(decimal));
        table.Columns.Add("MedianPaidAmount", typeof(decimal));
        table.Columns.Add("MedianAllowedAmount", typeof(decimal));
        table.Columns.Add("ModePaidAmount", typeof(decimal));
        table.Columns.Add("ModeAllowedAmount", typeof(decimal));
        table.Columns.Add("P25PaidAmount", typeof(decimal));
        table.Columns.Add("P75PaidAmount", typeof(decimal));
        table.Columns.Add("TotalLineCount", typeof(int));
        table.Columns.Add("DeniedLineCount", typeof(int));
        table.Columns.Add("AdjustedLineCount", typeof(int));
        table.Columns.Add("LastSeenDOS", typeof(DateTime));

        foreach (var r in records)
        {
            table.Rows.Add(
                run.LabId,                       // numeric id from SP/config, never from the source data
                Db(r.LabName),
                run.RunId,                       // stamps the run these averages were generated from
                Db(r.CptCode),
                Db(r.AvgUnits),
                Db(r.PanelName),
                Db(r.PayerCommonCode),
                Db(r.PayerDisplayName),
                Db(r.GlobalPayerId),
                Db(r.WindowBasis),
                Db(r.WindowType),
                Db(r.StartDate),
                Db(r.EndDate),
                Db(r.AsOfDateTime),
                Db(r.PaidLineCount),
                Db(r.AvgChargeAmountPerUnit),
                Db(r.AvgPaidAmountPerUnit),
                Db(r.AvgAllowedAmountPerUnit),
                Db(r.AvgPatientPaidAmountPerUnit),
                Db(r.AvgPatientResponsibilityPerUnit),
                Db(r.MedianPaidAmount),
                Db(r.MedianAllowedAmount),
                Db(r.ModePaidAmount),
                Db(r.ModeAllowedAmount),
                Db(r.P25PaidAmount),
                Db(r.P75PaidAmount),
                Db(r.TotalLineCount),
                Db(r.DeniedLineCount),
                Db(r.AdjustedLineCount),
                Db(r.LastSeenDos));
        }

        return table;
    }

    private static DataTable BuildPanelTable(IReadOnlyList<PanelAverageRecord> records, LabRunInfo run)
    {
        var table = new DataTable();
        table.Columns.Add("PanelName", typeof(string));
        table.Columns.Add("PayerID", typeof(string));
        table.Columns.Add("PayerDisplayName", typeof(string));
        table.Columns.Add("WindowBasis", typeof(string));
        table.Columns.Add("WindowType", typeof(string));
        table.Columns.Add("StartDate", typeof(DateTime));
        table.Columns.Add("EndDate", typeof(DateTime));
        table.Columns.Add("AsOfDateTime", typeof(DateTime));
        table.Columns.Add("PaidLineCount", typeof(int));
        table.Columns.Add("AvgChargeAmount", typeof(decimal));
        table.Columns.Add("AvgPaidAmount", typeof(decimal));
        table.Columns.Add("AvgAllowedAmount", typeof(decimal));
        table.Columns.Add("AvgPatientPaidAmount", typeof(decimal));
        table.Columns.Add("AvgPatientResponsibility", typeof(decimal));
        table.Columns.Add("MedianPaidAmount", typeof(decimal));
        table.Columns.Add("MedianAllowedAmount", typeof(decimal));
        table.Columns.Add("ModePaidAmount", typeof(decimal));
        table.Columns.Add("ModeAllowedAmount", typeof(decimal));
        table.Columns.Add("P25PaidAmount", typeof(decimal));
        table.Columns.Add("P75PaidAmount", typeof(decimal));
        table.Columns.Add("TotalLineCount", typeof(int));
        table.Columns.Add("DeniedLineCount", typeof(int));
        table.Columns.Add("AdjustedLineCount", typeof(int));
        table.Columns.Add("LastSeenDOS", typeof(DateTime));
        table.Columns.Add("LabName", typeof(string));
        table.Columns.Add("LabId", typeof(int));
        table.Columns.Add("RunId", typeof(string));

        foreach (var r in records)
        {
            table.Rows.Add(
                Db(r.PanelName),
                Db(r.PayerId),
                Db(r.PayerDisplayName),
                Db(r.WindowBasis),
                Db(r.WindowType),
                Db(r.StartDate),
                Db(r.EndDate),
                Db(r.AsOfDateTime),
                Db(r.PaidLineCount),
                Db(r.AvgChargeAmount),
                Db(r.AvgPaidAmount),
                Db(r.AvgAllowedAmount),
                Db(r.AvgPatientPaidAmount),
                Db(r.AvgPatientResponsibility),
                Db(r.MedianPaidAmount),
                Db(r.MedianAllowedAmount),
                Db(r.ModePaidAmount),
                Db(r.ModeAllowedAmount),
                Db(r.P25PaidAmount),
                Db(r.P75PaidAmount),
                Db(r.TotalLineCount),
                Db(r.DeniedLineCount),
                Db(r.AdjustedLineCount),
                Db(r.LastSeenDos),
                Db(r.LabName),
                run.LabId,                       // numeric id from SP/config, never from the source data
                run.RunId);                      // stamps the run these averages were generated from
        }

        return table;
    }

    private static object Db<T>(T? value) where T : struct => value.HasValue ? value.Value : DBNull.Value;
    private static object Db(string? value) => string.IsNullOrEmpty(value) ? DBNull.Value : value;
}
