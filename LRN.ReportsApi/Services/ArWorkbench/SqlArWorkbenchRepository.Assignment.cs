using System.Data;
using System.Text.Json;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Assignment Management, following the mockup (App.views.assignment, App.actions.assignClaim):
///   - a batch draws from the pool of UNASSIGNED claims that still carry an open insurance balance;
///   - assigning moves an Unassigned or Completed claim to Assigned (a claim mid-QA keeps its status);
///   - a claim with no open insurance balance can still be given to an agent, flagged ad hoc;
///   - reassigning records the previous agent, and resolves the claim's pending reassignment request;
///   - every change is written to dbo.ARWB_ClaimActivity, then dbo.ARWB_usp_RecalculateClaimState
///     re-derives the claim's queue.
/// Every claim read or written goes through <see cref="AppendScope"/>.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    public const int MaxClaimsPerAssignment = 5000;
    private const int DefaultUntouchedDays = 45;

    private static readonly JsonSerializerOptions CriteriaJson = new(JsonSerializerDefaults.Web);

    /// <summary>The batch pool: unassigned, open insurance balance - narrowed by the criteria.</summary>
    private static ArWorkbenchClaimFilter PoolFilter(int labId, ArWorkbenchBatchCriteria? c) => new()
    {
        LabId = labId,
        Status = ["Unassigned"],
        Agent = [ArWorkbenchClaimFilter.UnassignedAgent],
        OpenInsuranceArOnly = true,
        Category = c?.Category ?? [],
        Payer = c?.Payer ?? [],
        Panel = c?.Panel ?? [],
        Priority = c?.Priority ?? [],
        Clinic = c?.Clinic ?? [],
        Aging = c?.Aging ?? [],
        TflRiskOnly = c?.TflRiskOnly ?? false
    };

    // ==========================================================================================
    // Agents (LRNMaster) and workload (lab database)
    // ==========================================================================================

    /// <summary>
    /// Users with access to the lab (dbo.UserLabs) who hold an AR Workbench role, with their derived
    /// role code. Assignable = AR Agent or Team Lead, the people the mockup's agent list holds.
    /// </summary>
    public async Task<IReadOnlyList<ArWorkbenchAgent>> GetAgentsAsync(int labId, CancellationToken ct)
    {
        const string sql = @"
SELECT u.UserName,
       NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(u.FirstName, ''), ' ', ISNULL(u.LastName, '')))), '') AS DisplayName,
       r.RoleName, fa.FeatureKey
FROM dbo.LabUsers u
INNER JOIN dbo.UserLabs ul          ON ul.LabUserID = u.LabUserID AND ul.LabId = @LabId
INNER JOIN dbo.UserRoles ur         ON ur.LabUserID = u.LabUserID
INNER JOIN dbo.Roles r              ON r.RoleID     = ur.RoleID
INNER JOIN dbo.RoleFeatureAccess fa ON fa.RoleId    = r.RoleID
WHERE ISNULL(u.IsActive, 0) = 1
  AND ISNULL(r.IsActive, 0) = 1
  AND r.RoleName LIKE @RolePrefix + N'%'
  AND fa.FeatureKey LIKE N'ARWorkbench.%'
  AND fa.IsEnabled = 1;";

        var users = new Dictionary<string, (string? Name, Dictionary<string, HashSet<string>> Roles)>(StringComparer.OrdinalIgnoreCase);
        await using (var master = new SqlConnection(_masterConnectionString))
        {
            await master.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, master);
            cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
            cmd.Parameters.Add("@RolePrefix", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.RolePrefix;
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var userName = r.GetString(0);
                if (!users.TryGetValue(userName, out var entry))
                    users[userName] = entry = (Str(r, 1), new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase));
                if (!entry.Roles.TryGetValue(r.GetString(2), out var keys))
                    entry.Roles[r.GetString(2)] = keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                keys.Add(r.GetString(3));
            }
        }

        var agents = new List<ArWorkbenchAgent>();
        foreach (var (userName, (name, roles)) in users)
        {
            // As in GetUserContextAsync: a role counts once it has ARWorkbench.Access.
            var counted = roles.Where(x => x.Value.Contains(ArWorkbenchFeatures.Access)).ToList();
            if (counted.Count == 0) continue;
            var features = new HashSet<string>(counted.SelectMany(x => x.Value), StringComparer.OrdinalIgnoreCase);
            var code = DeriveRoleCode(new ArWorkbenchPermissions
            {
                Assign = features.Contains(ArWorkbenchFeatures.Assign),
                EditClaim = features.Contains(ArWorkbenchFeatures.EditClaim),
                QaDecide = features.Contains(ArWorkbenchFeatures.QaDecide),
                Approve = features.Contains(ArWorkbenchFeatures.Approve),
                ManageUsers = features.Contains(ArWorkbenchFeatures.ManageUsers),
                ViewAudit = features.Contains(ArWorkbenchFeatures.ViewAudit)
            });
            if (code is not ("agent" or "lead")) continue;
            agents.Add(new ArWorkbenchAgent
            {
                UserName = userName,
                DisplayName = name ?? userName,
                RoleCode = code,
                RoleLabel = code == "lead" ? "Team Lead" : "AR Agent",
                IsAssignable = true
            });
        }
        return agents.OrderBy(a => a.DisplayName, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public async Task<ArWorkbenchAssignmentOverview> GetAssignmentOverviewAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var agents = (await GetAgentsAsync(labId, ct)).ToList();

        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        var pool = BuildClaimFilter(cmd, PoolFilter(labId, null));

        cmd.CommandText = $@"
DECLARE @Untouched int = COALESCE(TRY_CONVERT(int, (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('UntouchedDays', N'{DefaultUntouchedDays}'))), {DefaultUntouchedDays});
SELECT @Untouched;

-- 1. workload per agent
SELECT w.AssignedAgentUser,
       SUM(CASE WHEN w.IsWorkComplete = 0 AND w.IsOpenInsuranceAR = 1 THEN 1 ELSE 0 END),
       ISNULL(SUM(CASE WHEN w.IsWorkComplete = 0 AND w.IsOpenInsuranceAR = 1 THEN w.RemainingAR ELSE 0 END), 0),
       SUM(CASE WHEN w.WorkflowStatus = 'Submitted for QA' THEN 1 ELSE 0 END),
       COUNT(*)
FROM dbo.ARWB_Claim w
WHERE w.AssignedAgentUser IS NOT NULL {scope}
GROUP BY w.AssignedAgentUser;

-- 2. the unassigned open pool, and how much of it is stale
SELECT COUNT(*), ISNULL(SUM(w.RemainingAR), 0),
       ISNULL(SUM(s.Stale), 0)
FROM dbo.ARWB_Claim w
-- Same definition of untouched as the Unassigned Claims table (UntouchedSinceSql).
CROSS APPLY (SELECT Stale = CASE WHEN {UntouchedSinceSql()} <= DATEADD(day, -@Untouched, SYSUTCDATETIME()) THEN 1 ELSE 0 END) s
WHERE {pool} {scope};

-- 3. assigned claims that still carry an open balance (the reassign table)
SELECT COUNT(*) FROM dbo.ARWB_Claim w WHERE w.AssignedAgentUser IS NOT NULL AND w.IsOpenInsuranceAR = 1 {scope};

-- 4. open batches, pending reassignment requests
SELECT COUNT(*) FROM dbo.ARWB_AssignmentBatch WHERE BatchStatus = 'Open';
SELECT COUNT(*) FROM dbo.ARWB_AgentRequest x INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = x.ClaimKey
WHERE x.RequestType = 'Reassignment Request' AND x.RequestStatus = 'Pending' {scope};

-- 5..10. batch criteria options over the pool, with counts (NULL = the 'none' option)
SELECT w.DenialCategory, COUNT(*) FROM dbo.ARWB_Claim w WHERE {pool} {scope} GROUP BY w.DenialCategory ORDER BY w.DenialCategory;
SELECT w.PayerName,      COUNT(*) FROM dbo.ARWB_Claim w WHERE {pool} {scope} GROUP BY w.PayerName      ORDER BY w.PayerName;
SELECT w.PanelName,      COUNT(*) FROM dbo.ARWB_Claim w WHERE {pool} {scope} GROUP BY w.PanelName      ORDER BY w.PanelName;
SELECT w.ClinicName,     COUNT(*) FROM dbo.ARWB_Claim w WHERE {pool} {scope} GROUP BY w.ClinicName     ORDER BY w.ClinicName;
SELECT p.Priority, ISNULL(c.Claims, 0)
FROM (VALUES ('High', 1), ('Medium', 2), ('Low', 3)) p (Priority, Ord)
OUTER APPLY (SELECT Claims = COUNT(*) FROM dbo.ARWB_Claim w WHERE w.Priority = p.Priority AND {pool} {scope}) c
ORDER BY p.Ord;
SELECT m.ItemValue, ISNULL(c.Claims, 0)
FROM dbo.ARWB_MasterListItem m
OUTER APPLY (SELECT Claims = COUNT(*) FROM dbo.ARWB_Claim w WHERE w.AgingBucket = m.ItemValue AND {pool} {scope}) c
WHERE m.ListType = 'AGING_BUCKET' AND m.IsActive = 1 ORDER BY m.SortOrder;";

        var overview = new ArWorkbenchAssignmentOverview();
        var workload = new Dictionary<string, (int Open, decimal Ar, int Qa, int Total)>(StringComparer.OrdinalIgnoreCase);

        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            if (await r.ReadAsync(ct)) overview.UntouchedDays = r.GetInt32(0);
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) workload[r.GetString(0)] = (r.GetInt32(1), r.GetDecimal(2), r.GetInt32(3), r.GetInt32(4));
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct))
            {
                overview.UnassignedOpenCount = r.GetInt32(0);
                overview.UnassignedOpenAR = r.GetDecimal(1);
                overview.UnassignedStaleCount = r.GetInt32(2);
            }
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct)) overview.AssignedOpenCount = r.GetInt32(0);
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct)) overview.OpenBatchCount = r.GetInt32(0);
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct)) overview.PendingReassignmentRequests = r.GetInt32(0);

            async Task<List<ArWorkbenchFilterOption>> OptionsAsync(string? noneLabel)
            {
                await r.NextResultAsync(ct);
                var list = new List<ArWorkbenchFilterOption>();
                while (await r.ReadAsync(ct))
                {
                    var count = r.GetInt32(1);
                    if (r.IsDBNull(0))
                    {
                        if (noneLabel is not null && count > 0) list.Insert(0, new() { Value = ArWorkbenchFilterValues.None, Label = noneLabel, Count = count });
                        continue;
                    }
                    list.Add(new() { Value = r.GetString(0), Label = r.GetString(0), Count = count });
                }
                return list;
            }

            overview.PoolOptions.Categories = await OptionsAsync("(No denial)");
            overview.PoolOptions.Payers = await OptionsAsync("(No payer)");
            overview.PoolOptions.Panels = await OptionsAsync("(No panel)");
            overview.PoolOptions.Clinics = await OptionsAsync("(No clinic)");
            overview.PoolOptions.Priorities = await OptionsAsync(null);
            overview.PoolOptions.AgingBuckets = await OptionsAsync(null);
        }

        foreach (var a in agents)
        {
            if (!workload.TryGetValue(a.UserName, out var w)) continue;
            (a.OpenClaims, a.OpenInsuranceAR, a.AwaitingQa, a.TotalAssigned) = w;
        }

        // People still holding claims who are no longer assignable (role removed, left the lab):
        // shown so their caseload can be moved, never offered as a target.
        var former = workload.Keys.Where(k => !agents.Any(a => string.Equals(a.UserName, k, StringComparison.OrdinalIgnoreCase))).ToList();
        if (former.Count > 0)
        {
            var names = await GetDisplayNamesAsync(former, ct);
            agents.AddRange(former.Select(k => new ArWorkbenchAgent
            {
                UserName = k,
                DisplayName = names.TryGetValue(k, out var n) ? n : k,
                RoleLabel = "Not assignable",
                IsAssignable = false,
                OpenClaims = workload[k].Open,
                OpenInsuranceAR = workload[k].Ar,
                AwaitingQa = workload[k].Qa,
                TotalAssigned = workload[k].Total
            }));
        }

        overview.Agents = agents;
        return overview;
    }

    public async Task<ArWorkbenchBatchPreview> PreviewBatchAsync(int labId, ArWorkbenchBatchCriteria criteria, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        var where = BuildClaimFilter(cmd, PoolFilter(labId, criteria));
        cmd.CommandText = $@"
SELECT COUNT(*), ISNULL(SUM(w.RemainingAR), 0),
       ISNULL(SUM(CASE WHEN w.IsTflRisk = 1 THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN w.Priority = 'High' THEN 1 ELSE 0 END), 0)
FROM dbo.ARWB_Claim w WHERE {where} {scope};";

        await using var r = await cmd.ExecuteReaderAsync(ct);
        await r.ReadAsync(ct);
        return new ArWorkbenchBatchPreview { ClaimCount = r.GetInt32(0), TotalInsuranceAR = r.GetDecimal(1), TflRiskCount = r.GetInt32(2), HighPriorityCount = r.GetInt32(3) };
    }

    // ==========================================================================================
    // Assign / reassign
    // ==========================================================================================

    /// <summary>Creates a named batch from the claims matching the criteria and assigns them, in one transaction.</summary>
    public async Task<ArWorkbenchAssignResult> CreateBatchAsync(int labId, ArWorkbenchBatchCreateRequest request, ArWorkbenchAgent agent, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        // The pool is re-read under an update lock: what was previewed may have changed, and two
        // leads must not batch the same claim.
        var keys = new List<long>();
        decimal total = 0;
        await using (var select = connection.CreateCommand())
        {
            select.Transaction = tx;
            var scope = AppendScope(select, user);
            var where = BuildClaimFilter(select, PoolFilter(labId, request.Criteria));
            select.Parameters.Add("@Max", SqlDbType.Int).Value = Math.Clamp(request.MaxClaims ?? MaxClaimsPerAssignment, 1, MaxClaimsPerAssignment);
            select.CommandText = $@"
SELECT TOP (@Max) w.ClaimKey, w.RemainingAR
FROM dbo.ARWB_Claim w WITH (UPDLOCK, ROWLOCK)
WHERE {where} {scope}
ORDER BY w.RemainingAR DESC, w.ClaimKey;";
            await using var r = await select.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct)) { keys.Add(r.GetInt64(0)); total += r.GetDecimal(1); }
        }

        if (keys.Count == 0)
            return new ArWorkbenchAssignResult { Message = "No unassigned claims with an open insurance balance match these criteria any more. Refresh the preview." };

        var summary = CriteriaSummary(request.Criteria);
        var batchName = string.IsNullOrWhiteSpace(request.BatchName) ? $"{agent.DisplayName} · {summary}" : request.BatchName.Trim();

        int batchId;
        string batchNumber;
        await using (var insert = new SqlCommand(@"
INSERT INTO dbo.ARWB_AssignmentBatch (BatchName, AgentUser, DueDate, CriteriaJson, ClaimCount, TotalInsuranceAR, CreatedBy)
OUTPUT inserted.AssignmentBatchId, inserted.BatchNumber
VALUES (@Name, @Agent, @Due, @Criteria, @Count, @Total, @User);", connection, tx))
        {
            insert.Parameters.Add("@Name", SqlDbType.NVarChar, 200).Value = Truncate(batchName, 200);
            insert.Parameters.Add("@Agent", SqlDbType.NVarChar, 256).Value = agent.UserName;
            insert.Parameters.Add("@Due", SqlDbType.Date).Value = (object?)request.DueDate?.Date ?? DBNull.Value;
            insert.Parameters.Add("@Criteria", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(request.Criteria, CriteriaJson);
            insert.Parameters.Add("@Count", SqlDbType.Int).Value = keys.Count;
            insert.Parameters.Add("@Total", SqlDbType.Decimal).Value = total;
            insert.Parameters["@Total"].Precision = 18;
            insert.Parameters["@Total"].Scale = 2;
            insert.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
            await using var r = await insert.ExecuteReaderAsync(ct);
            await r.ReadAsync(ct);
            batchId = r.GetInt32(0);
            batchNumber = r.GetString(1);
        }

        var result = await AssignCoreAsync(connection, tx, keys, agent, user, request.Note, request.DueDate, batchId, batchNumber, ct);
        await tx.CommitAsync(ct);

        result.AssignmentBatchId = batchId;
        result.BatchNumber = batchNumber;
        result.Message = $"{batchNumber}: assigned {result.AssignedCount:N0} claim{(result.AssignedCount == 1 ? "" : "s")} to {agent.DisplayName}.";
        return result;
    }

    /// <summary>Assigns or reassigns the selected claims (the shared Assign dialog).</summary>
    public async Task<ArWorkbenchAssignResult> AssignClaimsAsync(int labId, ArWorkbenchAssignRequest request, ArWorkbenchAgent agent, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var keys = request.ClaimKeys.Where(k => k > 0).Distinct().ToList();
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        var result = await AssignCoreAsync(connection, tx, keys, agent, user, request.Note, request.DueDate, null, null, ct);
        await tx.CommitAsync(ct);

        var parts = new List<string>();
        if (result.AssignedCount > 0) parts.Add($"{result.AssignedCount:N0} assigned");
        if (result.ReassignedCount > 0) parts.Add($"{result.ReassignedCount:N0} reassigned");
        if (result.UnchangedCount > 0) parts.Add($"{result.UnchangedCount:N0} already with {agent.DisplayName}");
        if (result.SkippedCount > 0) parts.Add($"{result.SkippedCount:N0} not found or outside your access");
        result.Message = parts.Count == 0 ? "Nothing to assign." : $"{string.Join(", ", parts)} — {agent.DisplayName}.";
        if (result.AdHocCount > 0) result.Message += $" {result.AdHocCount:N0} had no open insurance balance and were assigned ad hoc.";
        if (result.ResolvedRequestCount > 0) result.Message += $" {result.ResolvedRequestCount:N0} pending reassignment request{(result.ResolvedRequestCount == 1 ? " was" : "s were")} resolved.";
        return result;
    }

    /// <summary>The one implementation of assigning: lock, log, update, resolve requests, reclassify.</summary>
    private static async Task<ArWorkbenchAssignResult> AssignCoreAsync(SqlConnection connection, SqlTransaction tx, IReadOnlyList<long> keys,
        ArWorkbenchAgent agent, ArWorkbenchUserContext user, string? note, DateTime? dueDate, int? batchId, string? batchNumber, CancellationToken ct)
    {
        var result = new ArWorkbenchAssignResult();
        if (keys.Count == 0) return result;

        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandTimeout = 300;
        var scope = AppendScope(cmd, user);
        var keyList = string.Join(",", keys);
        cmd.Parameters.Add("@Keys", SqlDbType.NVarChar, -1).Value = keyList;
        cmd.Parameters.Add("@Agent", SqlDbType.NVarChar, 256).Value = agent.UserName;
        cmd.Parameters.Add("@AgentName", SqlDbType.NVarChar, 256).Value = agent.DisplayName;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        cmd.Parameters.Add("@Note", SqlDbType.NVarChar, 1000).Value = string.IsNullOrWhiteSpace(note) ? DBNull.Value : Truncate(note.Trim(), 1000);
        cmd.Parameters.Add("@Due", SqlDbType.Date).Value = (object?)dueDate?.Date ?? DBNull.Value;
        cmd.Parameters.Add("@BatchId", SqlDbType.Int).Value = (object?)batchId ?? DBNull.Value;
        cmd.Parameters.Add("@BatchNumber", SqlDbType.VarChar, 20).Value = (object?)batchNumber ?? DBNull.Value;

        cmd.CommandText = $@"
SET NOCOUNT ON;
CREATE TABLE #t (ClaimKey bigint NOT NULL PRIMARY KEY, PrevAgent nvarchar(256) NULL, PrevStatus varchar(30) NOT NULL,
                 IsOpenAR bit NOT NULL, RemainingAR decimal(18,2) NOT NULL);

INSERT INTO #t (ClaimKey, PrevAgent, PrevStatus, IsOpenAR, RemainingAR)
SELECT w.ClaimKey, w.AssignedAgentUser, w.WorkflowStatus, w.IsOpenInsuranceAR, w.RemainingAR
FROM dbo.ARWB_Claim w WITH (UPDLOCK, ROWLOCK)
INNER JOIN dbo.ARWB_tvf_ParseKeyList(@Keys) k ON k.ClaimKey = w.ClaimKey
WHERE 1 = 1 {scope};

DECLARE @Found int = @@ROWCOUNT;
DECLARE @Unchanged int = (SELECT COUNT(*) FROM #t WHERE PrevAgent = @Agent);
DELETE #t WHERE PrevAgent = @Agent;

DECLARE @Suffix nvarchar(1100) = CASE WHEN @Note IS NULL THEN N'' ELSE N' — ' + @Note END;

IF @BatchId IS NOT NULL
    INSERT INTO dbo.ARWB_AssignmentBatchClaim (AssignmentBatchId, ClaimKey, PreviousAgentUser, InsuranceARAtAssignment)
    SELECT @BatchId, ClaimKey, PrevAgent, RemainingAR FROM #t;

UPDATE w
SET w.AssignedAgentUser     = @Agent,
    w.AssignedOn            = SYSUTCDATETIME(),
    w.AssignedBy            = @User,
    w.AssignmentBatchId     = @BatchId,          -- a hand reassignment takes the claim out of its batch
    w.AssignmentDueDate     = @Due,
    w.WorkflowStatus        = CASE WHEN w.WorkflowStatus IN ('Unassigned', 'Completed') THEN 'Assigned' ELSE w.WorkflowStatus END,
    w.AdHocFollowUpAssigned = CASE WHEN t.IsOpenAR = 0 THEN 1 ELSE w.AdHocFollowUpAssigned END,
    w.UpdatedOn             = SYSUTCDATETIME(),
    w.UpdatedBy             = @User
FROM dbo.ARWB_Claim w
INNER JOIN #t t ON t.ClaimKey = w.ClaimKey;

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
SELECT t.ClaimKey,
       CASE WHEN t.PrevAgent IS NULL THEN N'Claim Assigned' ELSE N'Reassigned' END,
       LEFT(CASE WHEN t.PrevAgent IS NULL
                 THEN N'Assigned to ' + @AgentName + ISNULL(N' via batch ' + @BatchNumber, N'') + @Suffix + N'.'
                 ELSE N'Reassigned from ' + t.PrevAgent + N' to ' + @AgentName + ISNULL(N' via batch ' + @BatchNumber, N'') + @Suffix + N'.' END, 2000),
       ISNULL(t.PrevAgent, N'Unassigned'), @Agent, @User, @Role,
       CASE WHEN @BatchId IS NULL THEN NULL ELSE 'AssignmentBatch' END, @BatchId
FROM #t t;

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
SELECT t.ClaimKey, N'Status Changed', N'Workflow status moved to Assigned.', t.PrevStatus, N'Assigned', @User, @Role,
       CASE WHEN @BatchId IS NULL THEN NULL ELSE 'AssignmentBatch' END, @BatchId
FROM #t t WHERE t.PrevStatus IN ('Unassigned', 'Completed');

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, UserName, RoleCode)
SELECT t.ClaimKey, N'Ad-Hoc Assignment',
       LEFT(N'Assigned to ' + @AgentName + N' for follow-up despite no open insurance balance' + @Suffix + N'.', 2000), @User, @Role
FROM #t t WHERE t.IsOpenAR = 0;

-- Reassigning answers an agent's Request Reassignment: resolve it so it leaves the requests queue.
DECLARE @Resolved TABLE (ClaimKey bigint NOT NULL);
UPDATE r
SET r.RequestStatus  = 'Resolved',
    r.ResolvedBy     = @User,
    r.ResolvedByRole = @Role,
    r.ResolvedOn     = SYSUTCDATETIME(),
    r.ResolutionNote = COALESCE(r.ResolutionNote, LEFT(N'Resolved by reassigning to ' + @AgentName + N'.', 2000))
OUTPUT inserted.ClaimKey INTO @Resolved (ClaimKey)
FROM dbo.ARWB_AgentRequest r
INNER JOIN #t t ON t.ClaimKey = r.ClaimKey
WHERE r.RequestType = 'Reassignment Request' AND r.RequestStatus = 'Pending';

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, UserName, RoleCode, RelatedEntityType)
SELECT ClaimKey, N'Reassignment Request Resolved', LEFT(N'Resolved by reassigning to ' + @AgentName + N'.', 2000), @User, @Role, 'AgentRequest'
FROM @Resolved;

-- Queue, flags and LastTouchedOn come from the one implementation of those rules.
IF EXISTS (SELECT 1 FROM #t)
BEGIN
    DECLARE @Changed nvarchar(max) = STUFF((SELECT N',' + CONVERT(nvarchar(20), ClaimKey) FROM #t FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'');
    EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKeyList = @Changed;
END;

SELECT Assigned   = (SELECT COUNT(*) FROM #t WHERE PrevAgent IS NULL),
       Reassigned = (SELECT COUNT(*) FROM #t WHERE PrevAgent IS NOT NULL),
       AdHoc      = (SELECT COUNT(*) FROM #t WHERE IsOpenAR = 0),
       Unchanged  = @Unchanged,
       Found      = @Found,
       Resolved   = (SELECT COUNT(*) FROM @Resolved);

DROP TABLE #t;";

        await using var r = await cmd.ExecuteReaderAsync(ct);
        // The final SELECT is the only result set the caller reads; skip anything before it.
        do
        {
            if (r.FieldCount == 6 && string.Equals(r.GetName(0), "Assigned", StringComparison.Ordinal) && await r.ReadAsync(ct))
            {
                result.AssignedCount = r.GetInt32(0);
                result.ReassignedCount = r.GetInt32(1);
                result.AdHocCount = r.GetInt32(2);
                result.UnchangedCount = r.GetInt32(3);
                result.SkippedCount = keys.Count - r.GetInt32(4);
                result.ResolvedRequestCount = r.GetInt32(5);
            }
        } while (await r.NextResultAsync(ct));
        return result;
    }

    // ==========================================================================================
    // Batches
    // ==========================================================================================

    private const string BatchSelect = @"
SELECT b.AssignmentBatchId, b.BatchNumber, b.BatchName, b.AgentUser, b.DueDate, b.CriteriaJson, b.ClaimCount, b.TotalInsuranceAR,
       b.BatchStatus, b.CreatedBy, b.CreatedOn,
       ISNULL(s.RemainingAR, 0), ISNULL(s.Completed, 0), ISNULL(s.Away, 0), ISNULL(s.Members, 0)
FROM dbo.ARWB_AssignmentBatch b
OUTER APPLY
(
    -- The batch's own agent is joined in here: SQL Server rejects an aggregate whose expression
    -- mixes an outer column (b.AgentUser) with inner ones (error 8124).
    SELECT RemainingAR = SUM(c.RemainingAR),
           Completed   = SUM(CASE WHEN c.IsWorkComplete = 1 THEN 1 ELSE 0 END),
           Away        = SUM(CASE WHEN ISNULL(c.AssignedAgentUser, N'') <> ob.AgentUser THEN 1 ELSE 0 END),
           Members     = COUNT(*)
    FROM dbo.ARWB_AssignmentBatchClaim bc
    INNER JOIN dbo.ARWB_AssignmentBatch ob ON ob.AssignmentBatchId = bc.AssignmentBatchId
    INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = bc.ClaimKey
    WHERE bc.AssignmentBatchId = b.AssignmentBatchId
) s";

    public async Task<IReadOnlyList<ArWorkbenchBatch>> GetBatchesAsync(int labId, string? status, int top, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Parameters.Add("@Top", SqlDbType.Int).Value = Math.Clamp(top, 1, 500);
        var where = "";
        if (!string.IsNullOrWhiteSpace(status) && !string.Equals(status, "all", StringComparison.OrdinalIgnoreCase))
        {
            where = " WHERE b.BatchStatus = @Status";
            cmd.Parameters.Add("@Status", SqlDbType.VarChar, 20).Value = status.Trim();
        }
        cmd.CommandText = BatchSelect.Replace("SELECT b.AssignmentBatchId", "SELECT TOP (@Top) b.AssignmentBatchId") + where + " ORDER BY b.AssignmentBatchId DESC;";

        var batches = new List<ArWorkbenchBatch>();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct)) batches.Add(ReadBatch(r));
        await NameAgentsAsync(batches, ct);
        return batches;
    }

    public async Task<ArWorkbenchBatchDetail?> GetBatchDetailAsync(int labId, int batchId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user, "c");
        cmd.Parameters.Add("@BatchId", SqlDbType.Int).Value = batchId;
        cmd.CommandText = $@"
{BatchSelect} WHERE b.AssignmentBatchId = @BatchId;

SELECT c.ClaimKey, c.ClaimID, c.PayerName, c.DenialCategory, c.Priority, bc.InsuranceARAtAssignment, c.RemainingAR,
       c.WorkflowStatus, c.IsWorkComplete, c.AssignedAgentUser, bc.PreviousAgentUser, c.LastFollowUpDate
FROM dbo.ARWB_AssignmentBatchClaim bc
INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = bc.ClaimKey
WHERE bc.AssignmentBatchId = @BatchId {scope}
ORDER BY c.IsWorkComplete, bc.InsuranceARAtAssignment DESC, c.ClaimKey;

-- The running log: everything that happened to the batch's claims since it was created.
SELECT TOP (300) a.ActivityOn, a.ClaimKey, c.ClaimID, a.ActionType, a.Detail, a.UserName, a.IsSystem
FROM dbo.ARWB_ClaimActivity a
INNER JOIN dbo.ARWB_AssignmentBatchClaim bc ON bc.ClaimKey = a.ClaimKey AND bc.AssignmentBatchId = @BatchId
INNER JOIN dbo.ARWB_AssignmentBatch b ON b.AssignmentBatchId = bc.AssignmentBatchId
INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = a.ClaimKey
WHERE a.ActivityOn >= b.CreatedOn {scope}
ORDER BY a.ActivityOn DESC, a.ActivityId DESC;";

        var detail = new ArWorkbenchBatchDetail();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            if (!await r.ReadAsync(ct)) return null;
            detail.Batch = ReadBatch(r);

            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                detail.Claims.Add(new ArWorkbenchBatchClaim
                {
                    ClaimKey = r.GetInt64(0),
                    ClaimID = r.GetString(1),
                    PayerName = Str(r, 2),
                    DenialCategory = Str(r, 3),
                    Priority = Str(r, 4),
                    InsuranceARAtAssignment = r.GetDecimal(5),
                    RemainingAR = r.GetDecimal(6),
                    WorkflowStatus = r.GetString(7),
                    IsWorkComplete = r.GetBoolean(8),
                    CurrentAgentUser = Str(r, 9),
                    PreviousAgentUser = Str(r, 10),
                    LastFollowUpDate = Date(r, 11)
                });
            }

            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                detail.Log.Add(new ArWorkbenchBatchLogEntry
                {
                    ActivityOn = DateTime.SpecifyKind(r.GetDateTime(0), DateTimeKind.Utc),
                    ClaimKey = r.GetInt64(1),
                    ClaimID = r.GetString(2),
                    ActionType = r.GetString(3),
                    Detail = Str(r, 4),
                    UserName = r.GetString(5),
                    IsSystem = r.GetBoolean(6)
                });
            }
        }

        await NameAgentsAsync([detail.Batch], ct);
        var names = await GetDisplayNamesAsync(detail.Claims.Select(c => c.CurrentAgentUser), ct);
        foreach (var c in detail.Claims)
            if (c.CurrentAgentUser is not null && names.TryGetValue(c.CurrentAgentUser, out var n)) c.CurrentAgentName = n;
        return detail;
    }

    /// <summary>Cancels an open batch. Its claims stay with their agents; only the batch stops being tracked as open work.</summary>
    public async Task<ArWorkbenchSaveResult> CancelBatchAsync(int labId, int batchId, string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
UPDATE dbo.ARWB_AssignmentBatch SET BatchStatus = 'Cancelled', CompletedOn = SYSUTCDATETIME()
WHERE AssignmentBatchId = @BatchId AND BatchStatus = 'Open';
SELECT @@ROWCOUNT, (SELECT BatchNumber FROM dbo.ARWB_AssignmentBatch WHERE AssignmentBatchId = @BatchId);", connection);
        cmd.Parameters.Add("@BatchId", SqlDbType.Int).Value = batchId;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        await r.ReadAsync(ct);
        var number = Str(r, 1);
        if (number is null) return ArWorkbenchSaveResult.NotFound("That batch no longer exists.");
        return r.GetInt32(0) == 0
            ? ArWorkbenchSaveResult.Conflict($"{number} is not open, so it cannot be cancelled.")
            : ArWorkbenchSaveResult.Ok($"{number} cancelled. Its claims stay with their agents.");
    }

    private static ArWorkbenchBatch ReadBatch(SqlDataReader r)
    {
        ArWorkbenchBatchCriteria? criteria = null;
        if (!r.IsDBNull(5))
        {
            try { criteria = JsonSerializer.Deserialize<ArWorkbenchBatchCriteria>(r.GetString(5), CriteriaJson); }
            catch (JsonException) { /* a hand-edited row: show the batch without its criteria */ }
        }

        var members = r.GetInt32(14);
        var completed = r.GetInt32(12);
        var stored = r.GetString(8);
        var due = Date(r, 4);
        var allDone = members > 0 && completed >= members;
        return new ArWorkbenchBatch
        {
            AssignmentBatchId = r.GetInt32(0),
            BatchNumber = r.GetString(1),
            BatchName = r.GetString(2),
            AgentUser = r.GetString(3),
            DueDate = due,
            Criteria = criteria,
            CriteriaSummary = criteria is null ? "" : CriteriaSummary(criteria),
            ClaimCount = members > 0 ? members : r.GetInt32(6),
            TotalInsuranceAR = r.GetDecimal(7),
            RemainingAR = r.GetDecimal(11),
            CompletedCount = completed,
            ReassignedAwayCount = r.GetInt32(13),
            CompletionPct = members == 0 ? 0 : (int)Math.Round(100.0 * completed / members),
            // Completion is live, not stored: a claim reopened by a new denial puts the batch back to Open.
            BatchStatus = stored == "Cancelled" ? "Cancelled" : allDone ? "Completed" : "Open",
            IsOverdue = stored != "Cancelled" && !allDone && due is { } d && d.Date < DateTime.UtcNow.Date,
            CreatedBy = r.GetString(9),
            CreatedOn = DateTime.SpecifyKind(r.GetDateTime(10), DateTimeKind.Utc)
        };
    }

    private async Task NameAgentsAsync(IReadOnlyList<ArWorkbenchBatch> batches, CancellationToken ct)
    {
        var names = await GetDisplayNamesAsync(batches.Select(b => b.AgentUser), ct);
        foreach (var b in batches) b.AgentName = names.TryGetValue(b.AgentUser, out var n) ? n : b.AgentUser;
    }

    /// <summary>"Medical Necessity · 2 payers · High" - the batch's label in lists.</summary>
    internal static string CriteriaSummary(ArWorkbenchBatchCriteria c)
    {
        static string Part(List<string> values, string singular, string plural) =>
            values.Count == 0 ? "" : values.Count == 1 ? (values[0] == ArWorkbenchFilterValues.None ? $"no {singular}" : values[0]) : $"{values.Count} {plural}";

        var parts = new[]
        {
            Part(c.Category, "category", "categories"),
            Part(c.Payer, "payer", "payers"),
            Part(c.Panel, "panel", "panels"),
            Part(c.Clinic, "clinic", "clinics"),
            Part(c.Priority, "priority", "priorities"),
            Part(c.Aging, "aging bucket", "aging buckets"),
            c.TflRiskOnly ? "TFL at risk" : ""
        }.Where(p => p.Length > 0).ToList();
        return parts.Count == 0 ? "All unassigned" : string.Join(" · ", parts);
    }
}
