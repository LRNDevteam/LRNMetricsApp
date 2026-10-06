using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>Bulk Update (Excel): the claims a file names, within the caller's scope, with their conflict-check version.</summary>
public sealed partial class SqlArWorkbenchRepository
{
    public async Task<Dictionary<string, ArWorkbenchBulkClaimState>> GetBulkClaimStatesAsync(int labId, IReadOnlyCollection<string> claimIds,
        ArWorkbenchUserContext user, CancellationToken ct)
    {
        var result = new Dictionary<string, ArWorkbenchBulkClaimState>(StringComparer.OrdinalIgnoreCase);
        if (claimIds.Count == 0) return result;

        await using var connection = await OpenLabAsync(labId, ct);
        await using (var create = new SqlCommand("CREATE TABLE #ids (ClaimID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);", connection))
            await create.ExecuteNonQueryAsync(ct);

        var table = new DataTable();
        table.Columns.Add("ClaimID", typeof(string));
        foreach (var id in claimIds.Select(i => i.Trim()).Where(i => i.Length is > 0 and <= 200).Distinct(StringComparer.OrdinalIgnoreCase))
            table.Rows.Add(id);
        using (var bulk = new SqlBulkCopy(connection) { DestinationTableName = "#ids", BulkCopyTimeout = 120 })
            await bulk.WriteToServerAsync(table, ct);

        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 120;
        var scope = AppendScope(cmd, user);
        // Version: the latest activity a PERSON caused (the sync's entries are IsSystem = 1).
        cmd.CommandText = $@"
SELECT w.ClaimKey, w.ClaimID, w.WorkflowStatus, w.AssignedAgentUser, v.ActivityId, v.UserName, v.ActivityOn
FROM #ids i
INNER JOIN dbo.ARWB_Claim w ON w.ClaimID = i.ClaimID
OUTER APPLY (SELECT TOP (1) a.ActivityId, a.UserName, a.ActivityOn
             FROM dbo.ARWB_ClaimActivity a
             WHERE a.ClaimKey = w.ClaimKey AND a.IsSystem = 0
             ORDER BY a.ActivityId DESC) v
WHERE 1 = 1 {scope};";
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var state = new ArWorkbenchBulkClaimState
            {
                ClaimKey = r.GetInt64(0),
                ClaimId = r.GetString(1),
                WorkflowStatus = r.GetString(2),
                AssignedAgentUser = Str(r, 3),
                Version = r.IsDBNull(4) ? 0 : r.GetInt64(4),
                LastActivityBy = Str(r, 5),
                LastActivityOn = r.IsDBNull(6) ? null : r.GetDateTime(6)
            };
            result.TryAdd(state.ClaimId, state);
        }
        return result;
    }
}
