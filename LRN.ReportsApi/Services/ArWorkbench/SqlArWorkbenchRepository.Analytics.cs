using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T071 Recovery &amp; Financial Analytics (mockup App.views.analytics): recovered vs outstanding by
/// client, payer, panel, denial category, agent and AR queue, plus the Follow-Up Comments Breakdown
/// over every logged follow-up note. One round trip; every result set carries the same scope
/// clause, so a clinic / provider viewer or an agent only sees their own claims.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    public async Task<ArWorkbenchAnalytics> GetAnalyticsAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 180;
        var scope = AppendScope(cmd, user);

        // One recovery rollup per dimension: count, initial AR, recovered, outstanding.
        string Rollup(string column, string where = "1 = 1") => $@"
SELECT {column}, COUNT(*), ISNULL(SUM(w.InitialInsuranceAR), 0), ISNULL(SUM(w.RecoveredAmount), 0), ISNULL(SUM(w.RemainingAR), 0)
FROM dbo.ARWB_Claim w
WHERE {where} {scope}
GROUP BY {column};";

        // Follow-up notes per value of one Comments Framework field: notes, distinct claims, and the
        // claims' current remaining AR counted once per claim (the mockup's fuFieldBreakdown).
        string Breakdown(string column) => $@"
SELECT x.Val, SUM(x.Notes), COUNT(*), ISNULL(SUM(x.RemainingAR), 0)
FROM
(
    SELECT f.{column} AS Val, w.ClaimKey, COUNT(*) AS Notes, MAX(w.RemainingAR) AS RemainingAR
    FROM dbo.ARWB_ClaimFollowUp f
    INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = f.ClaimKey
    WHERE f.IsSystem = 0 AND NULLIF(LTRIM(RTRIM(f.{column})), N'') IS NOT NULL {scope}
    GROUP BY f.{column}, w.ClaimKey
) x
GROUP BY x.Val
ORDER BY SUM(x.Notes) DESC, x.Val;";

        cmd.CommandText = $@"
-- 0. Totals (recovery rate numerator: only claims with a non-zero initial balance)
SELECT COUNT(*), ISNULL(SUM(w.InitialInsuranceAR), 0), ISNULL(SUM(w.RecoveredAmount), 0), ISNULL(SUM(w.RemainingAR), 0),
       ISNULL(SUM(CASE WHEN w.InitialInsuranceAR > 0 THEN w.RecoveredAmount ELSE 0 END), 0)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope};

-- 1. Data refresh
SELECT TOP (1) CompletedOn FROM dbo.ARWB_RefreshRun WHERE RunStatus = 'Succeeded' ORDER BY RefreshRunId DESC;

-- 2..6. Recovery by client, payer, panel, denial category, agent
{Rollup("NULLIF(LTRIM(RTRIM(w.LabName)), N'')")}
{Rollup("NULLIF(LTRIM(RTRIM(w.PayerName)), N'')")}
{Rollup("NULLIF(LTRIM(RTRIM(w.PanelName)), N'')")}
{Rollup("NULLIF(LTRIM(RTRIM(w.DenialCategory)), N'')")}
{Rollup("w.AssignedAgentUser", "NULLIF(w.AssignedAgentUser, N'') IS NOT NULL")}

-- 7. Recovery by AR Queue (top level, in queue order)
SELECT w.ArQueueId, t.QueueLabel, COUNT(*), ISNULL(SUM(w.InitialInsuranceAR), 0), ISNULL(SUM(w.RecoveredAmount), 0), ISNULL(SUM(w.RemainingAR), 0)
FROM dbo.ARWB_Claim w
INNER JOIN dbo.ARWB_ArQueue t ON t.QueueId = w.ArQueueId
WHERE 1 = 1 {scope}
GROUP BY w.ArQueueId, t.QueueLabel, t.SortOrder
ORDER BY t.SortOrder;

-- 8..10. Follow-Up Comments Breakdown
{Breakdown("FollowUpClaimStatus")}
{Breakdown("FixResolution")}
{Breakdown("DenialRootCause")}";

        var a = new ArWorkbenchAnalytics();
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        decimal recoveredWithInitial = 0;
        if (await reader.ReadAsync(ct))
        {
            a.TotalClaims = IntOrZero(reader, 0);
            a.InitialAR = DecOrZero(reader, 1);
            a.Recovered = DecOrZero(reader, 2);
            a.Outstanding = DecOrZero(reader, 3);
            recoveredWithInitial = DecOrZero(reader, 4);
        }
        a.RecoveryRate = ArWorkbenchAnalyticsRules.RecoveryRate(recoveredWithInitial, a.InitialAR);

        await reader.NextResultAsync(ct);
        if (await reader.ReadAsync(ct)) a.DataRefreshedOn = reader.IsDBNull(0) ? null : reader.GetDateTime(0);

        async Task<List<ArWorkbenchRecoveryRow>> ReadRollup(string blankLabel, bool drill)
        {
            await reader.NextResultAsync(ct);
            var rows = new List<ArWorkbenchRecoveryRow>();
            while (await reader.ReadAsync(ct))
            {
                var value = reader.IsDBNull(0) ? null : reader.GetString(0);
                rows.Add(new ArWorkbenchRecoveryRow
                {
                    Label = value ?? blankLabel,
                    Key = drill ? value ?? ArWorkbenchFilterValues.None : null,
                    Count = IntOrZero(reader, 1),
                    InitialAR = DecOrZero(reader, 2),
                    Recovered = DecOrZero(reader, 3),
                    Outstanding = DecOrZero(reader, 4)
                });
            }
            return rows;
        }

        // Client = the lab database itself (one client per lab), so it does not drill.
        a.ByClient = ArWorkbenchAnalyticsRules.TopWithOther(await ReadRollup("(No client)", false));
        a.ByPayer = ArWorkbenchAnalyticsRules.TopWithOther(await ReadRollup("(No payer)", true));
        a.ByPanel = ArWorkbenchAnalyticsRules.TopWithOther(await ReadRollup("(No panel)", true));
        a.ByCategory = ArWorkbenchAnalyticsRules.TopWithOther(await ReadRollup("(No denial category)", true));
        var agents = await ReadRollup("(Unassigned)", true);

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            a.ByQueue.Add(new ArWorkbenchRecoveryRow
            {
                Key = reader.GetString(0),
                Label = reader.GetString(1),
                Count = IntOrZero(reader, 2),
                InitialAR = DecOrZero(reader, 3),
                Recovered = DecOrZero(reader, 4),
                Outstanding = DecOrZero(reader, 5)
            });
        }

        async Task<List<ArWorkbenchFollowUpBreakdownRow>> ReadBreakdown()
        {
            await reader.NextResultAsync(ct);
            var rows = new List<ArWorkbenchFollowUpBreakdownRow>();
            while (await reader.ReadAsync(ct))
                rows.Add(new ArWorkbenchFollowUpBreakdownRow { Label = reader.GetString(0), Notes = IntOrZero(reader, 1), Claims = IntOrZero(reader, 2), Balance = DecOrZero(reader, 3) });
            return rows;
        }
        a.ByClaimStatus = await ReadBreakdown();
        a.ByFixResolution = await ReadBreakdown();
        a.ByDenialRootCause = await ReadBreakdown();
        await reader.DisposeAsync();

        // Agent bars read "First Last"; the key stays the user name the Work Queue filters on.
        var names = await GetDisplayNamesAsync(agents.Select(r => r.Key), ct);
        foreach (var row in agents) row.Label = names.GetValueOrDefault(row.Key!) ?? row.Label;
        a.ByAgent = ArWorkbenchAnalyticsRules.TopWithOther(agents);

        return a;
    }

    private static int IntOrZero(SqlDataReader r, int i) => r.IsDBNull(i) ? 0 : r.GetInt32(i);
    private static decimal DecOrZero(SqlDataReader r, int i) => r.IsDBNull(i) ? 0m : r.GetDecimal(i);
}
