using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Status Change Verification and the notification bell.
///
/// The claim sync (dbo.ARWB_usp_LoadClaimsFromSource step 3g) moves an assigned claim that is not
/// completed or closed to WorkflowStatus 'Pending Verification' when its master-file claim status
/// changed, and routes it to one of the lab's RCM Managers (dbo.ARWB_StatusVerification). This file
/// lists that queue, applies the manager's decision, and reads / clears dbo.ARWB_Notification.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const int StatusVerificationMaxRows = 2000;
    private const int NotificationMaxRows = 50;

    /// <summary>LRNMaster role whose holders receive status change verifications.</summary>
    public const string RcmManagerRoleName = ArWorkbenchFeatures.RolePrefix + "RCM Manager";

    /// <summary>
    /// The lab's active RCM Managers (dbo.UserLabs + dbo.UserRoles), as passed to the sync's
    /// @VerificationManagers. Empty when none is set up: the claims still move, addressed to the role.
    /// </summary>
    public async Task<IReadOnlyList<string>> GetRcmManagerUserNamesAsync(int labId, CancellationToken ct)
    {
        const string sql = @"
SELECT DISTINCT u.UserName
FROM dbo.LabUsers u
INNER JOIN dbo.UserLabs ul  ON ul.LabUserID = u.LabUserID AND ul.LabId = @LabId
INNER JOIN dbo.UserRoles ur ON ur.LabUserID = u.LabUserID
INNER JOIN dbo.Roles r      ON r.RoleID     = ur.RoleID
WHERE ISNULL(u.IsActive, 0) = 1
  AND ISNULL(r.IsActive, 0) = 1
  AND r.RoleName = @RoleName
ORDER BY u.UserName;";

        var list = new List<string>();
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, master);
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@RoleName", SqlDbType.NVarChar, 200).Value = RcmManagerRoleName;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            // A comma would split one name in two inside the procedure's list.
            var name = r.GetString(0).Trim();
            if (name.Length > 0 && !name.Contains(',')) list.Add(name);
        }
        return list;
    }

    // ==========================================================================================
    // Queue
    // ==========================================================================================

    public async Task<ArWorkbenchStatusVerificationQueue> GetStatusVerificationQueueAsync(ArWorkbenchStatusVerificationFilter filter, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(filter.LabId, ct);
        var queue = new ArWorkbenchStatusVerificationQueue();
        if (!await TableExistsAsync(connection, "dbo.ARWB_StatusVerification", ct)) return queue;

        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        cmd.Parameters.Add("@Me", SqlDbType.NVarChar, 256).Value = user.UserName;
        cmd.Parameters.Add("@Mine", SqlDbType.Bit).Value = filter.Mine;
        cmd.Parameters.Add("@Top", SqlDbType.Int).Value = StatusVerificationMaxRows + 1;

        var status = (filter.Status ?? "Pending").Trim();
        var where = new List<string>();
        if (status.Equals("Pending", StringComparison.OrdinalIgnoreCase)) where.Add("v.VerificationStatus = 'Pending'");
        else if (status.Equals("Resolved", StringComparison.OrdinalIgnoreCase)) where.Add("v.VerificationStatus = 'Resolved'");
        where.Add("(@Mine = 0 OR v.ManagerUser = @Me OR v.ManagerUser IS NULL)");
        if (!string.IsNullOrWhiteSpace(filter.Search))
        {
            var cols = new[] { "w.ClaimID", "w.PatientName", "w.PayerName", "v.AgentUser", "v.ManagerUser", "v.PreviousSourceStatus", "v.NewSourceStatus" };
            where.Add("(" + string.Join(" OR ", cols.Select(c => $@"{c} LIKE @Search ESCAPE '\'")) + ")");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 210).Value = "%" + EscapeLike(filter.Search.Trim()) + "%";
        }

        cmd.CommandText = $@"
SELECT SUM(CASE WHEN v.VerificationStatus = 'Pending' THEN 1 ELSE 0 END),
       SUM(CASE WHEN v.VerificationStatus = 'Pending' AND v.ManagerUser = @Me THEN 1 ELSE 0 END),
       SUM(CASE WHEN v.VerificationStatus = 'Pending' AND v.ManagerUser IS NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN v.VerificationStatus = 'Resolved' AND v.ResolvedOn >= DATEADD(day, -30, SYSUTCDATETIME()) THEN 1 ELSE 0 END)
FROM dbo.ARWB_StatusVerification v
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = v.ClaimKey
WHERE 1 = 1 {scope};

SELECT TOP (@Top)
       v.StatusVerificationId, w.ClaimKey, w.ClaimID, w.PatientName, w.PayerName, w.DateOfService, w.InsuranceBalance, w.PrimaryDenialCode,
       v.PreviousSourceStatus, v.NewSourceStatus, w.SourceClaimStatus, v.PreviousWorkflowStatus, w.WorkflowStatus,
       v.AgentUser, v.ManagerUser, v.VerificationStatus, v.RaisedOn, v.RefreshRunId,
       v.ResolvedAction, v.ResolvedBy, v.ResolvedOn, v.ResolutionNote
FROM dbo.ARWB_StatusVerification v
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = v.ClaimKey
WHERE {string.Join(" AND ", where)} {scope}
ORDER BY CASE WHEN v.VerificationStatus = 'Pending' THEN 0 ELSE 1 END, v.RaisedOn DESC, v.StatusVerificationId DESC;";

        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            static int I(SqlDataReader x, int i) => x.IsDBNull(i) ? 0 : x.GetInt32(i);
            if (await r.ReadAsync(ct))
            {
                queue.Pending = I(r, 0);
                queue.PendingMine = I(r, 1);
                queue.PendingUnrouted = I(r, 2);
                queue.ResolvedLast30Days = I(r, 3);
            }
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                queue.Rows.Add(new ArWorkbenchStatusVerificationRow
                {
                    StatusVerificationId = r.GetInt64(0), ClaimKey = r.GetInt64(1), ClaimID = r.GetString(2), PatientName = Str(r, 3),
                    PayerName = Str(r, 4), DateOfService = Date(r, 5), InsuranceBalance = r.GetDecimal(6), PrimaryDenialCode = Str(r, 7),
                    PreviousSourceStatus = Str(r, 8), NewSourceStatus = Str(r, 9), CurrentSourceStatus = Str(r, 10),
                    PreviousWorkflowStatus = r.GetString(11), WorkflowStatus = r.GetString(12),
                    AgentUser = Str(r, 13), ManagerUser = Str(r, 14), VerificationStatus = r.GetString(15), RaisedOn = r.GetDateTime(16),
                    RefreshRunId = Int(r, 17), ResolvedAction = Str(r, 18), ResolvedBy = Str(r, 19), ResolvedOn = Date(r, 20), ResolutionNote = Str(r, 21)
                });
            }
        }

        if (queue.Rows.Count > StatusVerificationMaxRows)
        {
            queue.Rows.RemoveAt(queue.Rows.Count - 1);
            queue.Truncated = true;
        }

        var names = await GetDisplayNamesAsync(queue.Rows.SelectMany(x => new[] { x.AgentUser, x.ManagerUser, x.ResolvedBy }), ct);
        string? Name(string? u) => u is not null && names.TryGetValue(u, out var n) ? n : u;
        foreach (var row in queue.Rows)
        {
            row.AgentName = Name(row.AgentUser);
            row.ManagerName = Name(row.ManagerUser);
            row.ResolvedByName = Name(row.ResolvedBy);
        }
        return queue;
    }

    // ==========================================================================================
    // Decision
    // ==========================================================================================

    /// <summary>
    /// Applies one decision to every selected claim still waiting for verification, in one
    /// transaction. ReturnToAgent restores the claim's workflow status before verification (Assigned
    /// or QA Rejected) with the same agent; Unassign returns it to the pool; Complete closes the work.
    /// </summary>
    public async Task<ArWorkbenchStatusVerificationResolveResult> ResolveStatusVerificationAsync(int labId, IReadOnlyList<long> claimKeys, string action,
        string note, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var keys = claimKeys.Where(k => k > 0).Distinct().ToList();
        var result = new ArWorkbenchStatusVerificationResolveResult();
        if (keys.Count == 0) return result;

        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandTimeout = 300;
        var scope = AppendScope(cmd, user);
        cmd.Parameters.Add("@Keys", SqlDbType.NVarChar, -1).Value = string.Join(",", keys);
        cmd.Parameters.Add("@Action", SqlDbType.VarChar, 20).Value = action;
        cmd.Parameters.Add("@Note", SqlDbType.NVarChar, 2000).Value = Truncate(note, 2000);
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);

        cmd.CommandText = $@"
SET NOCOUNT ON;
DECLARE @Now datetime2(0) = SYSUTCDATETIME();
CREATE TABLE #t (ClaimKey bigint NOT NULL PRIMARY KEY, ClaimID nvarchar(200) NOT NULL, VerificationId bigint NOT NULL,
                 PrevWorkflow varchar(30) NOT NULL, AgentUser nvarchar(256) NULL, NewWorkflow varchar(30) NOT NULL);

INSERT INTO #t (ClaimKey, ClaimID, VerificationId, PrevWorkflow, AgentUser, NewWorkflow)
SELECT w.ClaimKey, w.ClaimID, v.StatusVerificationId, v.PreviousWorkflowStatus, w.AssignedAgentUser,
       CASE @Action WHEN 'ReturnToAgent' THEN CASE WHEN w.AssignedAgentUser IS NULL THEN 'Unassigned' ELSE v.PreviousWorkflowStatus END
                    WHEN 'Unassign'      THEN 'Unassigned'
                    ELSE 'Completed' END
FROM dbo.ARWB_Claim w WITH (UPDLOCK, ROWLOCK)
INNER JOIN dbo.ARWB_tvf_ParseKeyList(@Keys) k ON k.ClaimKey = w.ClaimKey
INNER JOIN dbo.ARWB_StatusVerification v WITH (UPDLOCK, ROWLOCK) ON v.ClaimKey = w.ClaimKey AND v.VerificationStatus = 'Pending'
WHERE w.WorkflowStatus = 'Pending Verification' {scope};

UPDATE v
SET v.VerificationStatus = 'Resolved', v.ResolvedAction = @Action, v.ResolvedBy = @User, v.ResolvedByRole = @Role,
    v.ResolvedOn = @Now, v.ResolutionNote = @Note
FROM dbo.ARWB_StatusVerification v
INNER JOIN #t t ON t.VerificationId = v.StatusVerificationId;

UPDATE w
SET w.WorkflowStatus    = t.NewWorkflow,
    w.AssignedAgentUser = CASE WHEN @Action = 'Unassign' THEN NULL ELSE w.AssignedAgentUser END,
    w.AssignedOn        = CASE WHEN @Action = 'Unassign' THEN NULL ELSE w.AssignedOn END,
    w.AssignmentBatchId = CASE WHEN @Action = 'Unassign' THEN NULL ELSE w.AssignmentBatchId END,
    w.AssignmentDueDate = CASE WHEN @Action = 'Unassign' THEN NULL ELSE w.AssignmentDueDate END,
    w.UpdatedOn         = @Now,
    w.UpdatedBy         = @User
FROM dbo.ARWB_Claim w
INNER JOIN #t t ON t.ClaimKey = w.ClaimKey;

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
SELECT t.ClaimKey, @Now, N'Status Verification Resolved',
       LEFT(CASE @Action WHEN 'ReturnToAgent' THEN N'Verified and returned to ' + ISNULL(t.AgentUser, N'the pool')
                         WHEN 'Unassign'      THEN N'Verified and released to the unassigned pool' + ISNULL(N' (was ' + t.AgentUser + N')', N'')
                         ELSE N'Verified and completed: no further follow-up needed' END + N' — ' + @Note, 2000),
       N'Pending Verification', t.NewWorkflow, @User, @Role, 'StatusVerification', t.VerificationId
FROM #t t;

INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientUser, NotificationType, Message, CreatedOn, RelatedEntityType, RelatedEntityId)
SELECT t.ClaimKey, t.AgentUser, 'StatusVerificationResolved',
       LEFT(N'Claim ' + t.ClaimID + CASE @Action WHEN 'ReturnToAgent' THEN N' is back in your queue after status verification'
                                                 WHEN 'Unassign'      THEN N' was released from your queue after status verification'
                                                 ELSE N' was completed by the RCM Manager after status verification' END
            + N': ' + @Note, 1000),
       @Now, 'StatusVerification', t.VerificationId
FROM #t t
WHERE t.AgentUser IS NOT NULL;

DECLARE @recalc TABLE (UpdatedClaims int);
IF EXISTS (SELECT 1 FROM #t)
BEGIN
    DECLARE @Changed nvarchar(max) = STUFF((SELECT N',' + CONVERT(nvarchar(20), ClaimKey) FROM #t FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'');
    INSERT INTO @recalc EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKeyList = @Changed;
END;

SELECT COUNT(*) FROM #t;
DROP TABLE #t;";

        result.Resolved = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
        await tx.CommitAsync(ct);

        result.Skipped = keys.Count - result.Resolved;
        var verb = action switch
        {
            ArWorkbenchStatusVerificationActions.ReturnToAgent => "returned to the agent",
            ArWorkbenchStatusVerificationActions.Unassign => "released to the unassigned pool",
            _ => "completed"
        };
        result.Message = $"{result.Resolved:N0} claim{(result.Resolved == 1 ? "" : "s")} verified and {verb}."
            + (result.Skipped > 0 ? $" {result.Skipped:N0} skipped (no longer waiting for verification, or outside your access)." : "");
        return result;
    }

    // ==========================================================================================
    // Notifications - addressed to the user, or to their workbench role (a manager also reads the
    // manager broadcasts when they are an administrator). A role broadcast is read once for all.
    // ==========================================================================================

    private static string NotificationAudienceSql(ArWorkbenchUserContext user, SqlCommand cmd)
    {
        cmd.Parameters.Add("@Me", SqlDbType.NVarChar, 256).Value = user.UserName;
        cmd.Parameters.Add("@MyRole", SqlDbType.VarChar, 20).Value = user.RoleCode;
        // An administrator stands in for the managers (an unrouted verification must reach someone).
        return user.RoleCode == "admin"
            ? "(n.RecipientUser = @Me OR n.RecipientRole IN (@MyRole, 'manager'))"
            : "(n.RecipientUser = @Me OR n.RecipientRole = @MyRole)";
    }

    public async Task<ArWorkbenchNotificationList> GetNotificationsAsync(int labId, ArWorkbenchUserContext user, bool unreadOnly, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var audience = NotificationAudienceSql(user, cmd);
        cmd.Parameters.Add("@Top", SqlDbType.Int).Value = NotificationMaxRows;
        cmd.Parameters.Add("@UnreadOnly", SqlDbType.Bit).Value = unreadOnly;
        cmd.CommandText = $@"
SELECT COUNT(*) FROM dbo.ARWB_Notification n WHERE n.ReadOn IS NULL AND {audience};

SELECT TOP (@Top) n.NotificationId, n.ClaimKey, c.ClaimID, n.NotificationType, n.Message, n.CreatedOn,
       CAST(CASE WHEN n.ReadOn IS NULL THEN 0 ELSE 1 END AS bit),
       CAST(CASE WHEN n.RecipientUser IS NULL THEN 1 ELSE 0 END AS bit)
FROM dbo.ARWB_Notification n
LEFT JOIN dbo.ARWB_Claim c ON c.ClaimKey = n.ClaimKey
WHERE {audience} AND (@UnreadOnly = 0 OR n.ReadOn IS NULL)
ORDER BY CASE WHEN n.ReadOn IS NULL THEN 0 ELSE 1 END, n.CreatedOn DESC, n.NotificationId DESC;";

        var list = new ArWorkbenchNotificationList();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) list.UnreadCount = r.GetInt32(0);
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Items.Add(new ArWorkbenchNotification
            {
                NotificationId = r.GetInt64(0),
                ClaimKey = r.IsDBNull(1) ? null : r.GetInt64(1),
                ClaimID = Str(r, 2),
                NotificationType = r.GetString(3),
                Message = r.GetString(4),
                CreatedOn = r.GetDateTime(5),
                IsRead = r.GetBoolean(6),
                IsRoleBroadcast = r.GetBoolean(7)
            });
        }
        return list;
    }

    /// <summary>Marks the caller's notifications read (only ones addressed to them); returns how many changed.</summary>
    public async Task<int> MarkNotificationsReadAsync(int labId, IReadOnlyList<long> notificationIds, bool all, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var ids = notificationIds.Where(i => i > 0).Distinct().Take(1000).ToList();
        if (!all && ids.Count == 0) return 0;

        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var audience = NotificationAudienceSql(user, cmd);
        cmd.Parameters.Add("@All", SqlDbType.Bit).Value = all;
        cmd.Parameters.Add("@Ids", SqlDbType.NVarChar, -1).Value = string.Join(",", ids);
        cmd.CommandText = $@"
UPDATE n
SET n.ReadOn = SYSUTCDATETIME(), n.ReadBy = @Me
FROM dbo.ARWB_Notification n
WHERE n.ReadOn IS NULL AND {audience}
  AND (@All = 1 OR n.NotificationId IN (SELECT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@Ids) k));
SELECT @@ROWCOUNT;";
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    private static async Task<bool> TableExistsAsync(SqlConnection connection, string table, CancellationToken ct)
    {
        await using var probe = new SqlCommand("SELECT OBJECT_ID(@T, N'U');", connection);
        probe.Parameters.Add("@T", SqlDbType.NVarChar, 256).Value = table;
        return await probe.ExecuteScalarAsync(ct) is not (null or DBNull);
    }
}
