using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Tile counts for My Work and Follow-Up Management, matching the mockup's MW_QUICK_FILTERS and
/// Follow-Up windows. Each tile's list is the same claims query with the matching filter
/// (BuildClaimFilter), so a tile and the table behind it always agree.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    public async Task<ArWorkbenchWorkSummary> GetWorkSummaryAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        for (var i = 0; i < AwaitingPayerResolutions.Length; i++)
            cmd.Parameters.Add($"@Ap{i}", SqlDbType.NVarChar, 200).Value = AwaitingPayerResolutions[i];
        var awaiting = string.Join(", ", AwaitingPayerResolutions.Select((_, i) => $"@Ap{i}"));

        cmd.CommandText = $@"
DECLARE @Today date = CONVERT(date, SYSUTCDATETIME());

SELECT
    TotalAssigned       = COUNT(*),
    DueToday            = ISNULL(SUM(CASE WHEN w.NextFollowUpDate = @Today THEN 1 ELSE 0 END), 0),
    Overdue             = ISNULL(SUM(CASE WHEN w.NextFollowUpDate < @Today AND w.IsFinanciallyClosed = 0 THEN 1 ELSE 0 END), 0),
    HighPriority        = ISNULL(SUM(CASE WHEN w.Priority = 'High' AND w.IsFinanciallyClosed = 0 THEN 1 ELSE 0 END), 0),
    RefollowupRequired  = ISNULL(SUM(CASE WHEN w.ArQueueId = 'refollowup' THEN 1 ELSE 0 END), 0),
    CipResponseReceived = ISNULL(SUM(CASE WHEN w.ArQueueId = 'cipresponse' THEN 1 ELSE 0 END), 0),
    AwaitingPayer       = ISNULL(SUM(CASE WHEN w.FixResolution IN ({awaiting}) AND w.IsFinanciallyClosed = 0 THEN 1 ELSE 0 END), 0),
    SubmittedForQa      = ISNULL(SUM(CASE WHEN w.WorkflowStatus = 'Submitted for QA' THEN 1 ELSE 0 END), 0),
    QaRejected          = ISNULL(SUM(CASE WHEN w.WorkflowStatus = 'QA Rejected' THEN 1 ELSE 0 END), 0)
FROM dbo.ARWB_Claim w
WHERE w.AssignedAgentUser IS NOT NULL {scope};

SELECT
    ActionableAll        = COUNT(*),
    ActionableOverdue    = ISNULL(SUM(CASE WHEN w.NextFollowUpDate < @Today THEN 1 ELSE 0 END), 0),
    ActionableDueToday   = ISNULL(SUM(CASE WHEN w.NextFollowUpDate = @Today THEN 1 ELSE 0 END), 0),
    ActionableUpcoming   = ISNULL(SUM(CASE WHEN w.NextFollowUpDate > @Today THEN 1 ELSE 0 END), 0),
    ActionableNoFollowUp = ISNULL(SUM(CASE WHEN w.NextFollowUpDate IS NULL THEN 1 ELSE 0 END), 0)
FROM dbo.ARWB_Claim w
WHERE w.IsFollowUpActionable = 1 {scope};";

        var s = new ArWorkbenchWorkSummary();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct))
        {
            s.TotalAssigned = r.GetInt32(0);
            s.DueToday = r.GetInt32(1);
            s.Overdue = r.GetInt32(2);
            s.HighPriority = r.GetInt32(3);
            s.RefollowupRequired = r.GetInt32(4);
            s.CipResponseReceived = r.GetInt32(5);
            s.AwaitingPayer = r.GetInt32(6);
            s.SubmittedForQa = r.GetInt32(7);
            s.QaRejected = r.GetInt32(8);
        }
        await r.NextResultAsync(ct);
        if (await r.ReadAsync(ct))
        {
            s.ActionableAll = r.GetInt32(0);
            s.ActionableOverdue = r.GetInt32(1);
            s.ActionableDueToday = r.GetInt32(2);
            s.ActionableUpcoming = r.GetInt32(3);
            s.ActionableNoFollowUp = r.GetInt32(4);
        }
        return s;
    }
}
