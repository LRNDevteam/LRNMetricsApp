using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public interface IFeeScheduleRepository
{
    Task<IReadOnlyList<FeeScheduleRow>> GetAllAsync(CancellationToken ct);

    /// <summary>Replaces the whole fee schedule with <paramref name="rows"/> in one transaction.</summary>
    Task ReplaceAsync(IReadOnlyList<FeeScheduleImportRow> rows, string? sourceFile, string? importedBy, CancellationToken ct);
}

/// <summary>
/// LRNMaster.dbo.FeeSchedule (Database/LabMetricsDashboard/FeeSchedule_Setup.sql). The Master File
/// Processor and the AR Workbench copy it into each lab's dbo.ARWB_CptFeeSchedule before a claim sync.
/// </summary>
public sealed class SqlFeeScheduleRepository : IFeeScheduleRepository
{
    private readonly string _connectionString;

    public SqlFeeScheduleRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("DefaultConnection is not configured (LRNMaster).");
    }

    public async Task<IReadOnlyList<FeeScheduleRow>> GetAllAsync(CancellationToken ct)
    {
        const string sql = @"
SELECT FeeScheduleId, HCPCS, Rate, Modifier, FeeYear, EffectiveDate, Indicator, ShortDescription, SourceFile, ImportedOn, ImportedBy
FROM   dbo.FeeSchedule
ORDER  BY HCPCS;";

        var rows = new List<FeeScheduleRow>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new FeeScheduleRow(
                r.GetInt32(0), r.GetString(1), r.GetDecimal(2), Str(r, 3),
                r.IsDBNull(4) ? null : r.GetInt32(4),
                r.IsDBNull(5) ? null : r.GetDateTime(5),
                Str(r, 6), Str(r, 7), Str(r, 8), r.GetDateTime(9), Str(r, 10)));
        }
        return rows;
    }

    public async Task ReplaceAsync(IReadOnlyList<FeeScheduleImportRow> rows, string? sourceFile, string? importedBy, CancellationToken ct)
    {
        var table = new DataTable();
        table.Columns.Add("HCPCS", typeof(string));
        table.Columns.Add("Rate", typeof(decimal));
        table.Columns.Add("Modifier", typeof(string));
        table.Columns.Add("FeeYear", typeof(int));
        table.Columns.Add("EffectiveDate", typeof(DateTime));
        table.Columns.Add("Indicator", typeof(string));
        table.Columns.Add("ShortDescription", typeof(string));
        table.Columns.Add("SourceFile", typeof(string));
        table.Columns.Add("ImportedOn", typeof(DateTime));
        table.Columns.Add("ImportedBy", typeof(string));

        var now = DateTime.UtcNow;
        var file = Trim(sourceFile, 260);
        var by = Trim(importedBy, 256);
        foreach (var row in rows)
        {
            table.Rows.Add(row.Hcpcs, row.Rate, (object?)row.Modifier ?? DBNull.Value, (object?)row.FeeYear ?? DBNull.Value,
                (object?)row.EffectiveDate ?? DBNull.Value, (object?)row.Indicator ?? DBNull.Value, (object?)row.ShortDescription ?? DBNull.Value,
                (object?)file ?? DBNull.Value, now, (object?)by ?? DBNull.Value);
        }

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);
        try
        {
            await using (var clear = new SqlCommand("DELETE FROM dbo.FeeSchedule;", conn, tx) { CommandTimeout = 120 })
                await clear.ExecuteNonQueryAsync(ct);

            using var bulk = new SqlBulkCopy(conn, SqlBulkCopyOptions.CheckConstraints, tx)
            {
                DestinationTableName = "dbo.FeeSchedule",
                BulkCopyTimeout = 300
            };
            foreach (DataColumn c in table.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
            await bulk.WriteToServerAsync(table, ct);

            await tx.CommitAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    private static string? Str(SqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);

    private static string? Trim(string? value, int max)
        => string.IsNullOrWhiteSpace(value) ? null : value.Length <= max ? value : value[..max];
}
