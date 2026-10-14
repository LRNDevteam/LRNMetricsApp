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
}
