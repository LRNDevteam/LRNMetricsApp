using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public interface IDenialCategoryMasterRepository
{
    Task<IReadOnlyList<DenialCategoryMasterRow>> GetCategoriesAsync(CancellationToken ct);
    Task<IReadOnlyList<NonCollectibleDenialRow>> GetNonCollectibleAsync(CancellationToken ct);

    /// <summary>
    /// Replaces the rows of each master whose list is not null, in one transaction: either both
    /// sheets are saved or neither is. A null list leaves that table as it is.
    /// </summary>
    Task ReplaceAsync(IReadOnlyList<DenialCodeImportRow>? categories, IReadOnlyList<DenialCodeImportRow>? nonCollectible,
        string? createdBy, CancellationToken ct);
}

/// <summary>
/// LRNMaster.dbo.DenialCategoryMaster and dbo.NonCollectibleDenialMaster
/// (SqlScripts/DenialCategoryMaster_Setup.sql).
/// </summary>
public sealed class SqlDenialCategoryMasterRepository : IDenialCategoryMasterRepository
{
    private readonly string _connectionString;

    public SqlDenialCategoryMasterRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("DefaultConnection is not configured (LRNMaster).");
    }

    public async Task<IReadOnlyList<DenialCategoryMasterRow>> GetCategoriesAsync(CancellationToken ct)
    {
        const string sql = @"
SELECT DenialCategoryMasterId, DenialCode, Description, ActionCategory, CreatedOn, CreatedBy
FROM   dbo.DenialCategoryMaster
ORDER  BY ActionCategory, DenialCode;";

        var rows = new List<DenialCategoryMasterRow>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new DenialCategoryMasterRow(
                r.GetInt32(0), r.GetString(1), NullableString(r, 2), NullableString(r, 3), r.GetDateTime(4), NullableString(r, 5)));
        }
        return rows;
    }

    public async Task<IReadOnlyList<NonCollectibleDenialRow>> GetNonCollectibleAsync(CancellationToken ct)
    {
        const string sql = @"
SELECT NonCollectibleDenialMasterId, DenialCode, Description, CreatedOn, CreatedBy
FROM   dbo.NonCollectibleDenialMaster
ORDER  BY DenialCode;";

        var rows = new List<NonCollectibleDenialRow>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new NonCollectibleDenialRow(
                r.GetInt32(0), r.GetString(1), NullableString(r, 2), r.GetDateTime(3), NullableString(r, 4)));
        }
        return rows;
    }

    public async Task ReplaceAsync(IReadOnlyList<DenialCodeImportRow>? categories, IReadOnlyList<DenialCodeImportRow>? nonCollectible,
        string? createdBy, CancellationToken ct)
    {
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);

        try
        {
            if (categories is not null)
            {
                await ExecAsync(conn, tx, "DELETE FROM dbo.DenialCategoryMaster;", ct);
                foreach (var row in categories)
                {
                    await using var cmd = new SqlCommand(@"
INSERT INTO dbo.DenialCategoryMaster (DenialCode, Description, ActionCategory, CreatedOn, CreatedBy)
VALUES (@Code, @Description, @Category, SYSUTCDATETIME(), @CreatedBy);", conn, tx);
                    cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 50).Value = row.DenialCode;
                    cmd.Parameters.Add("@Description", SqlDbType.NVarChar, 1000).Value = Db(row.Description, 1000);
                    cmd.Parameters.Add("@Category", SqlDbType.NVarChar, 300).Value = Db(row.ActionCategory, 300);
                    cmd.Parameters.Add("@CreatedBy", SqlDbType.NVarChar, 256).Value = Db(createdBy, 256);
                    await cmd.ExecuteNonQueryAsync(ct);
                }
            }

            if (nonCollectible is not null)
            {
                await ExecAsync(conn, tx, "DELETE FROM dbo.NonCollectibleDenialMaster;", ct);
                foreach (var row in nonCollectible)
                {
                    await using var cmd = new SqlCommand(@"
INSERT INTO dbo.NonCollectibleDenialMaster (DenialCode, Description, CreatedOn, CreatedBy)
VALUES (@Code, @Description, SYSUTCDATETIME(), @CreatedBy);", conn, tx);
                    cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 50).Value = row.DenialCode;
                    cmd.Parameters.Add("@Description", SqlDbType.NVarChar, 1000).Value = Db(row.Description, 1000);
                    cmd.Parameters.Add("@CreatedBy", SqlDbType.NVarChar, 256).Value = Db(createdBy, 256);
                    await cmd.ExecuteNonQueryAsync(ct);
                }
            }

            await tx.CommitAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    private static async Task ExecAsync(SqlConnection conn, SqlTransaction tx, string sql, CancellationToken ct)
    {
        await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 60 };
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static string? NullableString(SqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);

    private static object Db(string? value, int max)
        => string.IsNullOrWhiteSpace(value) ? DBNull.Value : (value.Length <= max ? value : value[..max]);
}
