using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T061 / T062 CIP - Client Escalations (mockup approveCipCase, rejectCipCaseToAgent,
/// submitCipClientResponse, reviewCipClientResponse). A case is created by a follow-up note with
/// Fix / Resolution "CIP - Client Escalations" (Awaiting QA) and released by QA (Pending Approval):
///   Pending Approval  -- approve        --> Sent to Client
///                     -- reject (reason) --> Returned to Agent (never reaches the client; claim reopens)
///   Sent to Client    -- respond (client) --> Client Responded
///   Client Responded  -- approve-response --> Returned to Agent (claim reopens; CIP Response queue)
///                     -- insufficient (reason) --> Sent to Client, round + 1 (reason shown to the client)
/// Every action writes dbo.ARWB_CipCaseHistory and the claim's activity, then recalculates the claim.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    public static readonly string[] CipQueueStatuses = ["Pending Approval", "Sent to Client", "Client Responded", "Returned to Agent"];

    private static readonly Dictionary<string, string> CipSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["claimId"] = "w.ClaimID", ["payerName"] = "w.PayerName", ["caseStatus"] = "StatusOrder", ["roundNumber"] = "c.RoundNumber",
        ["cipCategory"] = "c.CipCategory", ["insuranceBalance"] = "w.InsuranceBalance", ["requestedOn"] = "c.RequestedOn",
        ["clientRespondedOn"] = "c.ClientRespondedOn", ["requestedBy"] = "c.RequestedBy",
        ["caseNumber"] = "c.CipCaseId", ["patientId"] = "w.PatientID", ["dateOfService"] = "w.DateOfService", ["labName"] = "w.LabName",
        ["requiredInfo"] = "c.RequiredInfo", ["arQueue"] = "q.QueueLabel", ["cipComment"] = "c.CipComment", ["feedback"] = "c.LastReviewNote"
    };

    private const string CipRowColumns = @"c.CipCaseId, c.CaseNumber, w.ClaimKey, w.ClaimID, w.LabName, w.PayerName, w.PatientID, w.DateOfService, w.ClinicName,
       c.CaseStatus, c.RoundNumber, c.CipCategory, c.RequiredInfo, c.CipComment, w.InsuranceBalance, w.ArQueueId, q.QueueLabel,
       c.RequestedBy, c.RequestedOn, c.FollowUpDate, c.OriginalAgentUser, c.LastReviewDecision, c.LastReviewNote, c.LastReviewedBy, c.LastReviewedOn,
       c.ClientResponseText, c.ClientRespondedBy, c.ClientRespondedOn, c.ClosedOn, w.ReferringProvider";

    private static ArWorkbenchCipCaseRow ReadCipRow(SqlDataReader r) => new()
    {
        CipCaseId = r.GetInt64(0), CaseNumber = r.GetString(1), ClaimKey = r.GetInt64(2), ClaimID = r.GetString(3), LabName = Str(r, 4),
        PayerName = Str(r, 5), PatientID = Str(r, 6), DateOfService = Date(r, 7), ClinicName = Str(r, 8), CaseStatus = r.GetString(9),
        RoundNumber = r.GetInt32(10), CipCategory = r.GetString(11), RequiredInfo = r.GetString(12), CipComment = r.GetString(13),
        InsuranceBalance = r.GetDecimal(14), ArQueueId = Str(r, 15), ArQueueLabel = Str(r, 16), RequestedBy = r.GetString(17),
        RequestedOn = r.GetDateTime(18), FollowUpDate = Date(r, 19), OriginalAgentUser = Str(r, 20), LastReviewDecision = Str(r, 21),
        LastReviewNote = Str(r, 22), LastReviewedBy = Str(r, 23), LastReviewedOn = Date(r, 24), ClientResponseText = Str(r, 25),
        ClientRespondedBy = Str(r, 26), ClientRespondedOn = Date(r, 27), ClosedOn = Date(r, 28), ReferringProvider = Str(r, 29)
    };

    /// <param name="clientView">The client's Escalation Requests: only cases that reached the client
    /// (Sent to Client onwards), never Awaiting QA / Pending Approval or one rejected internally.</param>
    public async Task<ArWorkbenchCipQueue> GetCipQueueAsync(ArWorkbenchCipFilter filter, ArWorkbenchUserContext user, bool clientView, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(filter.LabId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 120;
        var scope = AppendScope(cmd, user);
        var where = new List<string>();
        var visible = clientView
            ? "c.CaseStatus IN ('Sent to Client', 'Client Responded') OR (c.CaseStatus = 'Returned to Agent' AND c.ClientRespondedOn IS NOT NULL)"
            : "c.CaseStatus <> 'Awaiting QA'";
        where.Add($"({visible})");

        void AddIn(string column, string prefix, IEnumerable<string>? values, int size)
        {
            var list = (values ?? []).Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToList();
            if (list.Count == 0) return;
            for (var i = 0; i < list.Count; i++) cmd.Parameters.Add($"@{prefix}{i}", SqlDbType.NVarChar, size).Value = list[i];
            where.Add($"{column} IN ({string.Join(", ", list.Select((_, i) => $"@{prefix}{i}"))})");
        }
        AddIn("c.CaseStatus", "Cs", filter.Status, 30);
        AddIn("c.CipCategory", "Cc", filter.Category, 200);
        AddIn("w.PayerName", "Py", filter.Payer, 500);
        if (!string.IsNullOrWhiteSpace(filter.Search))
        {
            where.Add("(w.ClaimID LIKE @Search OR c.CaseNumber LIKE @Search OR w.PatientID LIKE @Search OR c.RequestedBy LIKE @Search OR c.CipComment LIKE @Search)");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 210).Value = "%" + filter.Search.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]") + "%";
        }

        var page = Math.Max(1, filter.Page);
        var pageSize = Math.Clamp(filter.PageSize, 5, 1000);
        var order = CipSortColumns.TryGetValue(filter.SortBy ?? string.Empty, out var col) ? col : "StatusOrder";
        var dir = filter.SortDesc ? "DESC" : "ASC";
        // Tie-breakers for a stable page order, minus the sort column itself: SQL Server rejects a
        // column listed twice in one ORDER BY (error 169) - e.g. sorting by requestedOn or caseNumber.
        var tieBreak = string.Join("", new[] { "c.RequestedOn", "c.CipCaseId" }.Where(t => t != order).Select(t => ", " + t));
        cmd.Parameters.Add("@Offset", SqlDbType.Int).Value = (page - 1) * pageSize;
        cmd.Parameters.Add("@PageSize", SqlDbType.Int).Value = pageSize;
        var whereSql = string.Join(" AND ", where);

        cmd.CommandText = $@"
SELECT SUM(CASE WHEN c.CaseStatus = 'Awaiting QA' THEN 1 ELSE 0 END),
       SUM(CASE WHEN c.CaseStatus = 'Pending Approval' THEN 1 ELSE 0 END),
       SUM(CASE WHEN c.CaseStatus = 'Sent to Client' THEN 1 ELSE 0 END),
       SUM(CASE WHEN c.CaseStatus = 'Client Responded' THEN 1 ELSE 0 END),
       SUM(CASE WHEN c.CaseStatus = 'Returned to Agent' THEN 1 ELSE 0 END)
FROM dbo.ARWB_CipCase c
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey
WHERE ({visible}) {scope};

SELECT COUNT(*) FROM dbo.ARWB_CipCase c INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey WHERE {whereSql} {scope};

SELECT {CipRowColumns}
FROM (SELECT c0.*, StatusOrder = CASE c0.CaseStatus WHEN 'Client Responded' THEN 0 WHEN 'Pending Approval' THEN 1 WHEN 'Sent to Client' THEN 2 WHEN 'Awaiting QA' THEN 3 ELSE 4 END
      FROM dbo.ARWB_CipCase c0) c
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey
LEFT JOIN dbo.ARWB_ArQueue q ON q.QueueId = w.ArQueueId
WHERE {whereSql} {scope}
ORDER BY {order} {dir}{tieBreak}
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";

        var queue = new ArWorkbenchCipQueue { Rows = new ArWorkbenchPagedResult<ArWorkbenchCipCaseRow> { Page = page, PageSize = pageSize } };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        static int I(SqlDataReader x, int i) => x.IsDBNull(i) ? 0 : x.GetInt32(i);
        if (await r.ReadAsync(ct))
            queue.Counts = new ArWorkbenchCipCounts { AwaitingQa = I(r, 0), PendingApproval = I(r, 1), SentToClient = I(r, 2), ClientResponded = I(r, 3), ReturnedToAgent = I(r, 4) };
        await r.NextResultAsync(ct);
        if (await r.ReadAsync(ct)) queue.Rows.TotalCount = r.GetInt32(0);
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) queue.Rows.Items.Add(ReadCipRow(r));
        await r.DisposeAsync();

        var docs = await GetCipDocumentsAsync(filter.LabId, queue.Rows.Items.Select(i => i.CipCaseId).ToList(), ct);
        foreach (var item in queue.Rows.Items) item.Attachments = docs.GetValueOrDefault(item.CipCaseId) ?? new();
        return queue;
    }

    /// <summary>The claim's CIP cases with their history (claim page CIP tab), scope already checked by the caller.</summary>
    public async Task<List<ArWorkbenchCipCaseDetail>> GetClaimCipCasesAsync(int labId, long claimKey, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand($@"
SELECT {CipRowColumns}
FROM dbo.ARWB_CipCase c
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey
LEFT JOIN dbo.ARWB_ArQueue q ON q.QueueId = w.ArQueueId
WHERE c.ClaimKey = @K ORDER BY c.RequestedOn DESC, c.CipCaseId DESC;

SELECT h.CipCaseId, h.RoundNumber, h.ActionOn, h.Actor, h.ActorRole, h.ActionName, h.Note, h.IsBulkAction
FROM dbo.ARWB_CipCaseHistory h
INNER JOIN dbo.ARWB_CipCase c ON c.CipCaseId = h.CipCaseId
WHERE c.ClaimKey = @K ORDER BY h.ActionOn, h.CipCaseHistoryId;", connection);
        cmd.Parameters.Add("@K", SqlDbType.BigInt).Value = claimKey;
        var cases = new List<ArWorkbenchCipCaseDetail>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) cases.Add(new ArWorkbenchCipCaseDetail { Case = ReadCipRow(r) });
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var detail = cases.FirstOrDefault(c => c.Case.CipCaseId == r.GetInt64(0));
            detail?.History.Add(new ArWorkbenchCipHistoryEntry
            {
                RoundNumber = r.GetInt32(1), ActionOn = r.GetDateTime(2), Actor = r.GetString(3), ActorRole = Str(r, 4),
                ActionName = r.GetString(5), Note = Str(r, 6), IsBulkAction = r.GetBoolean(7)
            });
        }
        await r.DisposeAsync();
        var docs = await GetCipDocumentsAsync(labId, cases.Select(c => c.Case.CipCaseId).ToList(), ct);
        foreach (var c in cases) c.Case.Attachments = docs.GetValueOrDefault(c.Case.CipCaseId) ?? new();
        return cases;
    }

    /// <summary>One CIP action in its own transaction. Outcome: ok | notfound | wrongstage.</summary>
    public async Task<(string Outcome, string CaseNumber, string? NewStatus)> CipActionAsync(int labId, long cipCaseId, ArWorkbenchCipAction action, string? note,
        ArWorkbenchUserContext user, Guid? bulkBatchId, CancellationToken ct)
    {
        var (from, to, history, activity) = ArWorkbenchCipRules.Transition(action);
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandTimeout = 120;
        var scope = AppendScope(cmd, user);
        var p = cmd.Parameters;
        p.Add("@CaseId", SqlDbType.BigInt).Value = cipCaseId;
        p.Add("@From", SqlDbType.VarChar, 30).Value = from;
        p.Add("@To", SqlDbType.VarChar, 30).Value = to;
        p.Add("@Action", SqlDbType.VarChar, 30).Value = action.ToString();
        p.Add("@History", SqlDbType.NVarChar, 100).Value = history;
        p.Add("@Activity", SqlDbType.NVarChar, 100).Value = activity;
        p.Add("@Note", SqlDbType.NVarChar, 4000).Value = (object?)note ?? DBNull.Value;
        p.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        p.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        p.Add("@Bulk", SqlDbType.UniqueIdentifier).Value = (object?)bulkBatchId ?? DBNull.Value;

        cmd.CommandText = $@"
SET NOCOUNT ON;
DECLARE @ClaimKey bigint, @Status varchar(30), @Round int, @CaseNumber varchar(30), @OrigAgent nvarchar(256);
SELECT @ClaimKey = c.ClaimKey, @Status = c.CaseStatus, @Round = c.RoundNumber, @CaseNumber = c.CaseNumber, @OrigAgent = c.OriginalAgentUser
FROM dbo.ARWB_CipCase c WITH (UPDLOCK, ROWLOCK)
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey
WHERE c.CipCaseId = @CaseId {scope};
IF @ClaimKey IS NULL BEGIN SELECT 'notfound', N'', CAST(NULL AS varchar(30)); RETURN; END;
IF @Status <> @From BEGIN SELECT 'wrongstage', @CaseNumber, @Status; RETURN; END;

DECLARE @Now datetime2(0) = SYSUTCDATETIME();
DECLARE @NewRound int = CASE WHEN @Action = 'Insufficient' THEN @Round + 1 ELSE @Round END;

UPDATE dbo.ARWB_CipCase
SET CaseStatus = @To,
    RoundNumber = @NewRound,
    LastReviewDecision = CASE @Action WHEN 'Approve' THEN 'approved' WHEN 'Reject' THEN 'rejected' WHEN 'ApproveResponse' THEN 'approved'
                                      WHEN 'Insufficient' THEN 'insufficient' ELSE LastReviewDecision END,
    LastReviewNote     = CASE WHEN @Action = 'Respond' THEN LastReviewNote ELSE @Note END,
    LastReviewedBy     = CASE WHEN @Action = 'Respond' THEN LastReviewedBy ELSE @User END,
    LastReviewedByRole = CASE WHEN @Action = 'Respond' THEN LastReviewedByRole ELSE @Role END,
    LastReviewedOn     = CASE WHEN @Action = 'Respond' THEN LastReviewedOn ELSE @Now END,
    ClientResponseText    = CASE WHEN @Action = 'Respond' THEN @Note ELSE ClientResponseText END,
    ClientRespondedBy     = CASE WHEN @Action = 'Respond' THEN @User ELSE ClientRespondedBy END,
    ClientRespondedByRole = CASE WHEN @Action = 'Respond' THEN @Role ELSE ClientRespondedByRole END,
    ClientRespondedOn     = CASE WHEN @Action = 'Respond' THEN @Now ELSE ClientRespondedOn END,
    ClosedOn = CASE WHEN @To = 'Returned to Agent' THEN @Now ELSE ClosedOn END
WHERE CipCaseId = @CaseId;

INSERT INTO dbo.ARWB_CipCaseHistory (CipCaseId, RoundNumber, ActionOn, Actor, ActorRole, ActionName, Note, IsBulkAction, BulkBatchId)
VALUES (@CaseId, @NewRound, @Now, @User, @Role, @History, @Note, CASE WHEN @Bulk IS NULL THEN 0 ELSE 1 END, @Bulk);

DECLARE @Prev varchar(30) = (SELECT WorkflowStatus FROM dbo.ARWB_Claim WITH (UPDLOCK) WHERE ClaimKey = @ClaimKey);
INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
VALUES (@ClaimKey, @Now, @Activity, LEFT(@CaseNumber + N': ' + ISNULL(@Note, N'-'), 2000), @Status, @To, @User, @Role, 'CipCase', @CaseId);

-- Back to the agent: the claim reopens (Assigned) for the agent who raised it when it has none.
IF @To = 'Returned to Agent'
BEGIN
    UPDATE dbo.ARWB_Claim
    SET WorkflowStatus = CASE WHEN WorkflowStatus IN ('Completed', 'Unassigned') THEN 'Assigned' ELSE WorkflowStatus END,
        AssignedAgentUser = COALESCE(AssignedAgentUser, @OrigAgent),
        AssignedOn = CASE WHEN AssignedAgentUser IS NULL AND @OrigAgent IS NOT NULL THEN @Now ELSE AssignedOn END,
        EscalationApproved = 0,
        UpdatedOn = @Now, UpdatedBy = @User
    WHERE ClaimKey = @ClaimKey;
    IF @Prev IN ('Completed', 'Unassigned')
        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode)
        VALUES (@ClaimKey, @Now, N'CIP Case Returned to Agent', CASE WHEN @Action = 'ApproveResponse'
                    THEN N'Client-provided information accepted; reopened for the AR agent.' ELSE N'CIP escalation not sent to the client; reopened for the AR agent.' END,
                @Prev, N'Assigned', @User, @Role);
END;

IF @Action = 'Respond'
    INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientRole, NotificationType, Message, CreatedOn, RelatedEntityType, RelatedEntityId)
    VALUES (@ClaimKey, 'lead', 'CipClientResponded', N'The client responded to ' + @CaseNumber + N'. Review it in CIP Escalations.', @Now, 'CipCase', @CaseId);

DECLARE @recalc TABLE (UpdatedClaims int);
INSERT INTO @recalc EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKey = @ClaimKey;

SELECT 'ok', @CaseNumber, @To;";

        string outcome, caseNumber;
        string? newStatus;
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            await r.ReadAsync(ct);
            outcome = r.GetString(0);
            caseNumber = r.GetString(1);
            newStatus = r.IsDBNull(2) ? null : r.GetString(2);
        }
        if (outcome == "ok") await tx.CommitAsync(ct); else await tx.RollbackAsync(ct);
        return (outcome, caseNumber, newStatus);
    }

    /// <summary>T063: Denial Workflow external escalations -> CIP cases (script 09). Preview counts without writing.</summary>
    public async Task<ArWorkbenchLegacyCipResult> ConvertLegacyEscalationsAsync(int labId, string runBy, bool previewOnly, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using (var probe = new SqlCommand("SELECT OBJECT_ID(N'dbo.ARWB_usp_ConvertLegacyEscalations', N'P');", connection))
        {
            if (await probe.ExecuteScalarAsync(ct) is null or DBNull)
                throw new InvalidOperationException("The legacy conversion is not installed for this lab. Run LRN.ReportsApi/Sql/ArWorkbench/09_ARWB_Legacy_Cip_Conversion.sql in the lab database.");
        }
        await using var cmd = new SqlCommand("dbo.ARWB_usp_ConvertLegacyEscalations", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 600 };
        cmd.Parameters.Add("@RunBy", SqlDbType.NVarChar, 256).Value = Truncate(runBy, 256);
        cmd.Parameters.Add("@PreviewOnly", SqlDbType.Bit).Value = previewOnly;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var result = new ArWorkbenchLegacyCipResult();
        if (await r.ReadAsync(ct))
        {
            static int I(SqlDataReader x, int i) => x.IsDBNull(i) ? 0 : Convert.ToInt32(x.GetValue(i));
            result.Candidates = I(r, 0); result.Converted = I(r, 1); result.SentToClient = I(r, 2); result.ClientResponded = I(r, 3);
            result.ReturnedToAgent = I(r, 4); result.NoMatchingClaim = I(r, 5); result.Note = Str(r, 6);
        }
        return result;
    }

    /// <summary>The cases' current stages (bulk: each gets the action for its own stage), within scope.</summary>
    public async Task<Dictionary<long, string>> GetCipStatusesAsync(int labId, IReadOnlyCollection<long> caseIds, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var result = new Dictionary<long, string>();
        if (caseIds.Count == 0) return result;
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        cmd.Parameters.Add("@Ids", SqlDbType.NVarChar, -1).Value = string.Join(",", caseIds);
        cmd.CommandText = $@"
SELECT c.CipCaseId, c.CaseStatus
FROM dbo.ARWB_CipCase c INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey
WHERE c.CipCaseId IN (SELECT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@Ids) k) {scope};";
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) result[r.GetInt64(0)] = r.GetString(1);
        return result;
    }
}

public enum ArWorkbenchCipAction { Approve, Reject, Respond, ApproveResponse, Insufficient }

public static class ArWorkbenchCipRules
{
    public const int NoteMaxLength = 4000;

    /// <summary>From-stage, to-stage, history and activity wording for each action.</summary>
    public static (string From, string To, string History, string Activity) Transition(ArWorkbenchCipAction action) => action switch
    {
        ArWorkbenchCipAction.Approve => ("Pending Approval", "Sent to Client", "Approved for Client", "CIP Approved for Client"),
        ArWorkbenchCipAction.Reject => ("Pending Approval", "Returned to Agent", "Rejected - Returned to Agent", "CIP Rejected - Returned to Agent"),
        ArWorkbenchCipAction.Respond => ("Sent to Client", "Client Responded", "Client Responded", "CIP Client Response Submitted"),
        ArWorkbenchCipAction.ApproveResponse => ("Client Responded", "Returned to Agent", "Response Approved - Returned to Agent", "CIP Response Approved"),
        ArWorkbenchCipAction.Insufficient => ("Client Responded", "Sent to Client", "Response Insufficient - Re-sent to Client", "CIP Response Rejected - Re-escalated to Client"),
        _ => throw new ArgumentOutOfRangeException(nameof(action))
    };

    public static ArWorkbenchCipAction? Parse(string? action) => (action ?? string.Empty).Trim().ToLowerInvariant() switch
    {
        "approve" => ArWorkbenchCipAction.Approve,
        "reject" => ArWorkbenchCipAction.Reject,
        "respond" => ArWorkbenchCipAction.Respond,
        "approve-response" or "approveresponse" => ArWorkbenchCipAction.ApproveResponse,
        "insufficient" => ArWorkbenchCipAction.Insufficient,
        _ => null
    };

    /// <summary>Reject and insufficient need a reason; the client's response needs text; approvals take an optional note.</summary>
    public static string? ValidateNote(ArWorkbenchCipAction action, string? note)
    {
        var text = note?.Trim() ?? string.Empty;
        if (text.Length > NoteMaxLength) return $"The note must be {NoteMaxLength:N0} characters or fewer.";
        if (text.Length > 0) return null;
        return action switch
        {
            ArWorkbenchCipAction.Reject or ArWorkbenchCipAction.Insufficient => "Add a reason.",
            ArWorkbenchCipAction.Respond => "Enter the requested information.",
            _ => null
        };
    }

    /// <summary>Bulk: Pending Approval -> approve / reject; Client Responded -> approve-response / insufficient; anything else is skipped.</summary>
    public static ArWorkbenchCipAction? ForStage(string stage, bool positive) => stage switch
    {
        "Pending Approval" => positive ? ArWorkbenchCipAction.Approve : ArWorkbenchCipAction.Reject,
        "Client Responded" => positive ? ArWorkbenchCipAction.ApproveResponse : ArWorkbenchCipAction.Insufficient,
        _ => null
    };

    /// <summary>The client acts on Respond only; the internal approvers on everything else.</summary>
    public static bool IsClientAction(ArWorkbenchCipAction action) => action == ArWorkbenchCipAction.Respond;
}
