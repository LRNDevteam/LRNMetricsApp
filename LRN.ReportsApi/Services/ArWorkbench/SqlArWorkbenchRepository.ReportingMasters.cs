using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// The reporting team's denial masters - LRNMaster.dbo.DenialCategoryMaster (code, description,
/// categorization) and dbo.NonCollectibleDenialMaster (the Denial Category Master screen in LRN
/// Metrics) - copied into the lab's dbo.ARWB_ReportingDenialMaster right before a claim sync, which
/// then applies them to the category map, the Non-Collectible list and every claim (05, step 3b2).
/// The Master File Processor does the same copy before its own sync.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private async Task CopyReportingDenialMastersAsync(SqlConnection lab, CancellationToken ct)
    {
        if (!await TableExistsAsync(lab, "dbo.ARWB_ReportingDenialMaster", ct)) return;   // lab scripts not updated yet

        var rows = new DataTable();
        rows.Columns.Add("MasterKind", typeof(string));
        rows.Columns.Add("DenialCode", typeof(string));
        rows.Columns.Add("Description", typeof(string));
        rows.Columns.Add("ActionCategory", typeof(string));

        const string sql = @"
IF OBJECT_ID(N'dbo.DenialCategoryMaster', N'U') IS NOT NULL
    SELECT 'Category', DenialCode, Description, ActionCategory FROM dbo.DenialCategoryMaster
    WHERE NULLIF(LTRIM(RTRIM(DenialCode)), N'') IS NOT NULL;
ELSE
    SELECT CAST(NULL AS varchar(20)), CAST(NULL AS nvarchar(50)), CAST(NULL AS nvarchar(1000)), CAST(NULL AS nvarchar(300)) WHERE 1 = 0;
IF OBJECT_ID(N'dbo.NonCollectibleDenialMaster', N'U') IS NOT NULL
    SELECT 'NonCollectible', DenialCode, Description, CAST(NULL AS nvarchar(300)) FROM dbo.NonCollectibleDenialMaster
    WHERE NULLIF(LTRIM(RTRIM(DenialCode)), N'') IS NOT NULL;";

        await using (var master = new SqlConnection(_masterConnectionString))
        {
            await master.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, master) { CommandTimeout = 120 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            do
            {
                while (await r.ReadAsync(ct))
                    rows.Rows.Add(r.GetString(0), r.GetString(1).Trim(), r.IsDBNull(2) ? null : r.GetString(2), r.IsDBNull(3) ? null : r.GetString(3));
            } while (await r.NextResultAsync(ct));
        }

        // Replace in one transaction: a failed copy leaves the previous copy in place.
        await using var tx = (SqlTransaction)await lab.BeginTransactionAsync(ct);
        await using (var clear = new SqlCommand("DELETE FROM dbo.ARWB_ReportingDenialMaster;", lab, tx))
            await clear.ExecuteNonQueryAsync(ct);
        if (rows.Rows.Count > 0)
        {
            using var bulk = new SqlBulkCopy(lab, SqlBulkCopyOptions.Default, tx) { DestinationTableName = "dbo.ARWB_ReportingDenialMaster", BulkCopyTimeout = 120 };
            foreach (DataColumn c in rows.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
            await bulk.WriteToServerAsync(rows, ct);
        }
        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// LRNMaster.dbo.FeeSchedule (LRN Metrics > Master Values > Fees Schedule Import) -> the lab's
    /// dbo.ARWB_CptFeeSchedule. When the rates changed every line is re-priced here (the sync only
    /// prices the lines it reloads); the sync's claim-state recalculation then rolls them into Revenue
    /// Expectation and Recovery Status. Same copy as the Master File Processor's. An empty master
    /// (nothing imported yet) leaves the lab's rates alone.
    /// </summary>
    private async Task CopyFeeScheduleAsync(SqlConnection lab, CancellationToken ct)
    {
        if (!await TableExistsAsync(lab, "dbo.ARWB_CptFeeSchedule", ct)) return;

        var master = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
        string? source = null;
        await using (var conn = new SqlConnection(_masterConnectionString))
        {
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.FeeSchedule', N'U') IS NOT NULL
    SELECT HCPCS, Rate, SourceFile FROM dbo.FeeSchedule WHERE NULLIF(LTRIM(RTRIM(HCPCS)), N'') IS NOT NULL;", conn) { CommandTimeout = 120 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                master[r.GetString(0).Trim()] = r.GetDecimal(1);
                source ??= r.IsDBNull(2) ? null : r.GetString(2);
            }
        }
        if (master.Count == 0) return;

        var current = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
        await using (var cmd = new SqlCommand("SELECT CPTCode, Rate FROM dbo.ARWB_CptFeeSchedule WHERE Modifier IS NULL;", lab) { CommandTimeout = 120 })
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct)) current[r.GetString(0).Trim()] = r.GetDecimal(1);

        if (current.Count == master.Count && master.All(kv => current.TryGetValue(kv.Key, out var rate) && rate == kv.Value))
            return;

        var rows = new DataTable();
        rows.Columns.Add("CPTCode", typeof(string));
        rows.Columns.Add("Rate", typeof(decimal));
        rows.Columns.Add("EffectiveFrom", typeof(DateTime));
        rows.Columns.Add("RateSource", typeof(string));
        rows.Columns.Add("UpdatedOn", typeof(DateTime));
        rows.Columns.Add("UpdatedBy", typeof(string));
        var rateSource = "Fees Schedule Import" + (string.IsNullOrWhiteSpace(source) ? "" : ": " + source);
        if (rateSource.Length > 100) rateSource = rateSource[..100];
        var now = DateTime.UtcNow;
        // Effective from 1900: the schedule prices every date of service.
        foreach (var kv in master)
            rows.Rows.Add(kv.Key, kv.Value, new DateTime(1900, 1, 1), rateSource, now, "AR Workbench Data Processing");

        await using (var tx = (SqlTransaction)await lab.BeginTransactionAsync(ct))
        {
            await using (var clear = new SqlCommand("DELETE FROM dbo.ARWB_CptFeeSchedule;", lab, tx) { CommandTimeout = 120 })
                await clear.ExecuteNonQueryAsync(ct);
            using (var bulk = new SqlBulkCopy(lab, SqlBulkCopyOptions.Default, tx) { DestinationTableName = "dbo.ARWB_CptFeeSchedule", BulkCopyTimeout = 120 })
            {
                foreach (DataColumn c in rows.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
                await bulk.WriteToServerAsync(rows, ct);
            }
            await tx.CommitAsync(ct);
        }

        await using var price = new SqlCommand("dbo.ARWB_usp_PriceClaimLines", lab) { CommandType = CommandType.StoredProcedure, CommandTimeout = 1800 };
        await price.ExecuteNonQueryAsync(ct);
    }
}
