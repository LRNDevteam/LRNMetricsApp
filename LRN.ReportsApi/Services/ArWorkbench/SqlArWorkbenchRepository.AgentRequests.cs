using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Escalation &amp; Reassignment Requests (dbo.ARWB_AgentRequest): an AR agent raises one on a claim in
/// their caseload; a Team Lead, RCM Manager or System Administrator answers it with a note (one or
/// many at once, one shared note), or - for a reassignment - by reassigning the claim, which
/// resolves it in AssignClaimsAsync. Every read and write carries the caller's claim scope.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const int MaxAgentRequestRows = 2000;

    public async Task<(ArWorkbenchSaveStatus Status, string Message, long? RequestId)> CreateAgentRequestAsync(
        int labId, long claimKey, string requestType, string reason, string note, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        var scope = AppendScope(cmd, user);
        cmd.Parameters.Add("@ClaimKey", SqlDbType.BigInt).Value = claimKey;
        cmd.Parameters.Add("@Type", SqlDbType.VarChar, 40).Value = requestType;
        cmd.Parameters.Add("@List", SqlDbType.VarChar, 40).Value = ArWorkbenchAgentRequestRules.ReasonList(requestType);
        cmd.Parameters.Add("@Reason", SqlDbType.NVarChar, 200).Value = reason;
        cmd.Parameters.Add("@Note", SqlDbType.NVarChar, ArWorkbenchAgentRequestRules.MaxNoteLength).Value = note;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        cmd.Parameters.Add("@Activity", SqlDbType.NVarChar, 100).Value = ArWorkbenchAgentRequestRules.RaisedActivity(requestType);

        cmd.CommandText = $@"
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM dbo.ARWB_Claim w WITH (UPDLOCK, ROWLOCK) WHERE w.ClaimKey = @ClaimKey {scope})
BEGIN SELECT 'notfound', CAST(NULL AS bigint), CAST(NULL AS nvarchar(200)); RETURN; END;

DECLARE @CanonReason nvarchar(200) = (SELECT TOP (1) ItemValue FROM dbo.ARWB_MasterListItem
                                      WHERE ListType = @List AND IsActive = 1 AND ItemValue = @Reason);
IF @CanonReason IS NULL BEGIN SELECT 'badreason', CAST(NULL AS bigint), CAST(NULL AS nvarchar(200)); RETURN; END;

IF EXISTS (SELECT 1 FROM dbo.ARWB_AgentRequest WITH (UPDLOCK, HOLDLOCK)
           WHERE ClaimKey = @ClaimKey AND RequestType = @Type AND RequestStatus = 'Pending')
BEGIN SELECT 'duplicate', CAST(NULL AS bigint), CAST(NULL AS nvarchar(200)); RETURN; END;

INSERT INTO dbo.ARWB_AgentRequest (ClaimKey, RequestType, ReasonCategory, RequestNote, RequestedBy, RequestedByRole)
VALUES (@ClaimKey, @Type, @CanonReason, @Note, @User, @Role);
DECLARE @Id bigint = SCOPE_IDENTITY();

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
VALUES (@ClaimKey, @Activity, LEFT(@CanonReason + N' - ' + @Note, 2000), N'Pending', @User, @Role, 'AgentRequest', @Id);

SELECT 'ok', @Id, (SELECT ClaimID FROM dbo.ARWB_Claim WHERE ClaimKey = @ClaimKey);";

        string outcome;
        long? id = null;
        string? claimId = null;
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            await r.ReadAsync(ct);
            outcome = r.GetString(0);
            if (!r.IsDBNull(1)) id = r.GetInt64(1);
            claimId = Str(r, 2);
        }

        if (outcome != "ok")
        {
            await tx.RollbackAsync(ct);
            return outcome switch
            {
                "notfound" => (ArWorkbenchSaveStatus.NotFound, "Claim not found.", null),
                "badreason" => (ArWorkbenchSaveStatus.Invalid, "Choose a reason from the list.", null),
                _ => (ArWorkbenchSaveStatus.Conflict, requestType == ArWorkbenchAgentRequestRules.Escalation
                        ? "This claim already has an escalation waiting for a supervisor."
                        : "This claim already has a reassignment request waiting.", null)
            };
        }
        await tx.CommitAsync(ct);
        return (ArWorkbenchSaveStatus.Ok,
            requestType == ArWorkbenchAgentRequestRules.Escalation
                ? $"Claim {claimId} escalated to a supervisor. A Team Lead, RCM Manager or Administrator will respond."
                : $"Reassignment requested for claim {claimId}. It stays with you until a lead reassigns it.",
            id);
    }

    public async Task<ArWorkbenchAgentRequestQueue> GetAgentRequestsAsync(ArWorkbenchAgentRequestFilter filter, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(filter.LabId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 120;
        var scope = AppendScope(cmd, user);

        var where = new List<string> { "1 = 1" };
        void AddIn(string column, string prefix, IEnumerable<string>? values, int size)
        {
            var list = (values ?? []).Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToList();
            if (list.Count == 0) return;
            for (var i = 0; i < list.Count; i++) cmd.Parameters.Add($"@{prefix}{i}", SqlDbType.NVarChar, size).Value = list[i];
            where.Add($"{column} IN ({string.Join(", ", list.Select((_, i) => $"@{prefix}{i}"))})");
        }
        AddIn("r.RequestType", "Rt", filter.Type, 40);
        AddIn("r.RequestStatus", "Rs", filter.Status, 20);
        AddIn("w.PayerName", "Rp", filter.Payer, 500);
        AddIn("w.AssignedAgentUser", "Ra", filter.Agent, 256);
        AddIn("r.RequestedBy", "Rb", filter.RequestedBy, 256);
        AddIn("w.ArQueueId", "Rq", filter.Queue, 40);
        if (!string.IsNullOrWhiteSpace(filter.Search))
        {
            where.Add("(w.ClaimID LIKE @RSearch OR r.RequestedBy LIKE @RSearch OR w.AssignedAgentUser LIKE @RSearch OR r.RequestNote LIKE @RSearch OR r.ReasonCategory LIKE @RSearch)");
            cmd.Parameters.Add("@RSearch", SqlDbType.NVarChar, 210).Value = "%" + filter.Search.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]") + "%";
        }
        cmd.Parameters.Add("@Max", SqlDbType.Int).Value = MaxAgentRequestRows + 1;
        const string from = "FROM dbo.ARWB_AgentRequest r INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = r.ClaimKey";

        cmd.CommandText = $@"
-- 0. Tiles: everything in scope, whatever the filters
SELECT SUM(CASE WHEN r.RequestStatus = 'Pending' AND r.RequestType = N'{ArWorkbenchAgentRequestRules.Escalation}' THEN 1 ELSE 0 END),
       SUM(CASE WHEN r.RequestStatus = 'Pending' AND r.RequestType = N'{ArWorkbenchAgentRequestRules.Reassignment}' THEN 1 ELSE 0 END),
       SUM(CASE WHEN r.RequestStatus = 'Resolved' THEN 1 ELSE 0 END),
       COUNT(*)
{from} WHERE 1 = 1 {scope};

-- 1. Rows: pending first (oldest pending first - it has waited longest), then newest resolved
SELECT TOP (@Max) r.AgentRequestId, w.ClaimKey, w.ClaimID, w.LabName, w.PayerName, w.AssignedAgentUser, w.InsuranceBalance,
       w.ArQueueId, q.QueueLabel, w.WorkflowStatus, r.RequestType, r.ReasonCategory, r.RequestNote, r.RequestedBy, r.RequestedByRole,
       r.RequestedOn, r.RequestStatus, r.ResolvedBy, r.ResolvedOn, r.ResolutionNote, CAST(CASE WHEN r.BulkBatchId IS NULL THEN 0 ELSE 1 END AS bit)
{from}
LEFT JOIN dbo.ARWB_ArQueue q ON q.QueueId = w.ArQueueId
WHERE {string.Join(" AND ", where)} {scope}
ORDER BY CASE WHEN r.RequestStatus = 'Pending' THEN 0 ELSE 1 END,
         CASE WHEN r.RequestStatus = 'Pending' THEN r.RequestedOn END ASC,
         r.ResolvedOn DESC, r.AgentRequestId DESC;

-- 2..5. Filter options over the scope
SELECT TOP (500) w.PayerName, COUNT(*) {from} WHERE w.PayerName IS NOT NULL {scope} GROUP BY w.PayerName ORDER BY w.PayerName;
SELECT TOP (500) w.AssignedAgentUser, COUNT(*) {from} WHERE w.AssignedAgentUser IS NOT NULL {scope} GROUP BY w.AssignedAgentUser ORDER BY w.AssignedAgentUser;
SELECT TOP (500) r.RequestedBy, COUNT(*) {from} WHERE 1 = 1 {scope} GROUP BY r.RequestedBy ORDER BY r.RequestedBy;
SELECT w.ArQueueId, MAX(q.QueueLabel), COUNT(*) {from} INNER JOIN dbo.ARWB_ArQueue q ON q.QueueId = w.ArQueueId WHERE 1 = 1 {scope} GROUP BY w.ArQueueId, q.SortOrder ORDER BY q.SortOrder;";

        var result = new ArWorkbenchAgentRequestQueue();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            if (await r.ReadAsync(ct))
            {
                result.PendingEscalations = IntOrZero(r, 0);
                result.PendingReassignments = IntOrZero(r, 1);
                result.Resolved = IntOrZero(r, 2);
                result.Total = IntOrZero(r, 3);
            }
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                result.Rows.Add(new ArWorkbenchAgentRequestRow
                {
                    AgentRequestId = r.GetInt64(0), ClaimKey = r.GetInt64(1), ClaimID = r.GetString(2), LabName = Str(r, 3), PayerName = Str(r, 4),
                    AssignedAgentUser = Str(r, 5), InsuranceBalance = DecOrZero(r, 6), ArQueueId = Str(r, 7), ArQueueLabel = Str(r, 8),
                    WorkflowStatus = Str(r, 9), RequestType = r.GetString(10), ReasonCategory = r.GetString(11), RequestNote = r.GetString(12),
                    RequestedBy = r.GetString(13), RequestedByRole = Str(r, 14), RequestedOn = r.GetDateTime(15), RequestStatus = r.GetString(16),
                    ResolvedBy = Str(r, 17), ResolvedOn = r.IsDBNull(18) ? null : r.GetDateTime(18), ResolutionNote = Str(r, 19), IsBulk = r.GetBoolean(20)
                });
            }
            async Task<List<ArWorkbenchFilterOption>> Options(bool labelled)
            {
                await r.NextResultAsync(ct);
                var list = new List<ArWorkbenchFilterOption>();
                while (await r.ReadAsync(ct))
                    if (!r.IsDBNull(0))
                        list.Add(new ArWorkbenchFilterOption { Value = r.GetString(0), Label = labelled ? Str(r, 1) ?? r.GetString(0) : r.GetString(0), Count = r.GetInt32(labelled ? 2 : 1) });
                return list;
            }
            result.Payers = await Options(false);
            result.Agents = await Options(false);
            result.RequestedBy = await Options(false);
            result.Queues = await Options(true);
        }
        if (result.Rows.Count > MaxAgentRequestRows)
        {
            result.Rows.RemoveRange(MaxAgentRequestRows, result.Rows.Count - MaxAgentRequestRows);
            result.Truncated = true;
        }

        // People show as "First Last"; the filters keep the user names they match on.
        var names = await GetDisplayNamesAsync(result.Rows.SelectMany(x => new[] { x.AssignedAgentUser, x.RequestedBy, x.ResolvedBy })
            .Concat(result.Agents.Select(a => a.Value)).Concat(result.RequestedBy.Select(a => a.Value)), ct);
        foreach (var row in result.Rows)
        {
            row.AssignedAgentName = row.AssignedAgentUser is null ? null : names.GetValueOrDefault(row.AssignedAgentUser) ?? row.AssignedAgentUser;
            row.RequestedByName = names.GetValueOrDefault(row.RequestedBy) ?? row.RequestedBy;
            row.ResolvedByName = row.ResolvedBy is null ? null : names.GetValueOrDefault(row.ResolvedBy) ?? row.ResolvedBy;
        }
        foreach (var o in result.Agents.Concat(result.RequestedBy)) o.Label = names.GetValueOrDefault(o.Value) ?? o.Value;
        return result;
    }

    /// <summary>
    /// Marks the given pending requests resolved with one shared note (a BulkBatchId ties a bulk
    /// answer together) and writes one activity entry per request. Requests already resolved, out
    /// of the caller's scope or unknown are skipped and counted.
    /// </summary>
    public async Task<ArWorkbenchAgentRequestResolveResult> ResolveAgentRequestsAsync(int labId, IReadOnlyList<long> requestIds, string note, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandTimeout = 120;
        var scope = AppendScope(cmd, user);
        var idList = new List<string>();
        for (var i = 0; i < requestIds.Count; i++)
        {
            idList.Add($"@Id{i}");
            cmd.Parameters.Add($"@Id{i}", SqlDbType.BigInt).Value = requestIds[i];
        }
        cmd.Parameters.Add("@Note", SqlDbType.NVarChar, ArWorkbenchAgentRequestRules.MaxNoteLength).Value = note;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        cmd.Parameters.Add("@Bulk", SqlDbType.UniqueIdentifier).Value = requestIds.Count > 1 ? Guid.NewGuid() : DBNull.Value;

        cmd.CommandText = $@"
SET NOCOUNT ON;
DECLARE @Now datetime2(0) = SYSUTCDATETIME();
DECLARE @Done TABLE (AgentRequestId bigint, ClaimKey bigint, RequestType varchar(40));

UPDATE r
SET RequestStatus = 'Resolved', ResolvedBy = @User, ResolvedByRole = @Role, ResolvedOn = @Now, ResolutionNote = @Note, BulkBatchId = @Bulk
OUTPUT inserted.AgentRequestId, inserted.ClaimKey, inserted.RequestType INTO @Done
FROM dbo.ARWB_AgentRequest r
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = r.ClaimKey
WHERE r.AgentRequestId IN ({string.Join(", ", idList)}) AND r.RequestStatus = 'Pending' {scope};

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
SELECT d.ClaimKey, @Now,
       CASE d.RequestType WHEN N'{ArWorkbenchAgentRequestRules.Escalation}' THEN N'{ArWorkbenchAgentRequestRules.ResolvedActivity(ArWorkbenchAgentRequestRules.Escalation)}'
                          ELSE N'{ArWorkbenchAgentRequestRules.ResolvedActivity(ArWorkbenchAgentRequestRules.Reassignment)}' END,
       LEFT(@Note, 2000), N'Pending', N'Resolved', @User, @Role, 'AgentRequest', d.AgentRequestId
FROM @Done d;

SELECT COUNT(*) FROM @Done;";

        var resolved = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
        await tx.CommitAsync(ct);
        var skipped = requestIds.Count - resolved;
        return new ArWorkbenchAgentRequestResolveResult
        {
            Resolved = resolved,
            Skipped = skipped,
            Message = $"{resolved:N0} request{(resolved == 1 ? "" : "s")} resolved"
                      + (skipped > 0 ? $"; {skipped:N0} skipped (already resolved or no longer available)." : ".")
        };
    }

    /// <summary>The claim page's Requests tab: every request on the claim, newest first. Scope is checked by the caller.</summary>
    public async Task<List<ArWorkbenchAgentRequestRow>> GetClaimAgentRequestsAsync(int labId, long claimKey, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT AgentRequestId, RequestType, ReasonCategory, RequestNote, RequestedBy, RequestedByRole, RequestedOn,
       RequestStatus, ResolvedBy, ResolvedOn, ResolutionNote, CAST(CASE WHEN BulkBatchId IS NULL THEN 0 ELSE 1 END AS bit)
FROM dbo.ARWB_AgentRequest WHERE ClaimKey = @ClaimKey ORDER BY RequestedOn DESC, AgentRequestId DESC;", connection);
        cmd.Parameters.Add("@ClaimKey", SqlDbType.BigInt).Value = claimKey;
        var rows = new List<ArWorkbenchAgentRequestRow>();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                rows.Add(new ArWorkbenchAgentRequestRow
                {
                    AgentRequestId = r.GetInt64(0), ClaimKey = claimKey, RequestType = r.GetString(1), ReasonCategory = r.GetString(2),
                    RequestNote = r.GetString(3), RequestedBy = r.GetString(4), RequestedByRole = Str(r, 5), RequestedOn = r.GetDateTime(6),
                    RequestStatus = r.GetString(7), ResolvedBy = Str(r, 8), ResolvedOn = r.IsDBNull(9) ? null : r.GetDateTime(9),
                    ResolutionNote = Str(r, 10), IsBulk = r.GetBoolean(11)
                });
            }
        }
        var names = await GetDisplayNamesAsync(rows.SelectMany(x => new[] { x.RequestedBy, x.ResolvedBy }), ct);
        foreach (var row in rows)
        {
            row.RequestedByName = names.GetValueOrDefault(row.RequestedBy) ?? row.RequestedBy;
            row.ResolvedByName = row.ResolvedBy is null ? null : names.GetValueOrDefault(row.ResolvedBy) ?? row.ResolvedBy;
        }
        return rows;
    }
}
