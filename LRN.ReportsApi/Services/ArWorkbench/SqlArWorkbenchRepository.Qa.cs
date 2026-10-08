using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T059 QA record and decision (mockup App.actions.qaDecision / bulkQaApprove). Every logged
/// follow-up note creates the claim's current QA review ("Awaiting QA"); a QA decision closes it:
///   Approve -> claim Completed. A CIP note's case moves Awaiting QA -> Pending Approval (it goes to
///              the CIP approvers); a Write Off note becomes an Approved Write-Off (balance nullified,
///              Auto Adjustments / Approved Write-Offs queue until posted).
///   Reject  -> claim QA Rejected, back to the same agent; error type and note required. A CIP case
///              held for this note is closed (the agent's corrected note opens a fresh one).
/// Self-approval is blocked twice: the reviewer may not be the note's author (also a table CHECK)
/// nor the agent holding the claim.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private static readonly Dictionary<string, string> QaSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["claimId"] = "w.ClaimID", ["payerName"] = "w.PayerName", ["denialCategory"] = "w.DenialCategory",
        ["insuranceBalance"] = "w.InsuranceBalance", ["submittedOn"] = "r.SubmittedOn", ["reviewStatus"] = "r.ReviewStatus",
        ["reviewedOn"] = "r.ReviewedOn", ["agent"] = "w.AssignedAgentUser", ["reviewer"] = "r.ReviewedBy",
        ["labName"] = "w.LabName", ["panelName"] = "w.PanelName", ["escalation"] = "r.IsEscalation", ["errorType"] = "r.ErrorType",
        ["note"] = "f.FixResolution"
    };

    public async Task<ArWorkbenchQaQueue> GetQaQueueAsync(ArWorkbenchQaFilter filter, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(filter.LabId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 120;
        var scope = AppendScope(cmd, user);
        var where = new List<string> { "1 = 1" };

        void AddIn(string column, string prefix, IEnumerable<string>? values, int size, bool noneIsNull = false)
        {
            var list = (values ?? []).Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToList();
            if (list.Count == 0) return;
            var includeNull = noneIsNull && list.Remove(ArWorkbenchFilterValues.None);
            var parts = new List<string>();
            if (list.Count > 0)
            {
                for (var i = 0; i < list.Count; i++) cmd.Parameters.Add($"@{prefix}{i}", SqlDbType.NVarChar, size).Value = list[i];
                parts.Add($"{column} IN ({string.Join(", ", list.Select((_, i) => $"@{prefix}{i}"))})");
            }
            if (includeNull) parts.Add($"{column} IS NULL");
            where.Add("(" + string.Join(" OR ", parts) + ")");
        }
        AddIn("r.ReviewStatus", "Rs", filter.ReviewStatus, 20);
        AddIn("w.PayerName", "Py", filter.Payer, 500, true);
        AddIn("w.PanelName", "Pn", filter.Panel, 500, true);
        AddIn("w.DenialCategory", "Ca", filter.Category, 200, true);
        AddIn("w.AssignedAgentUser", "Ag", filter.Agent, 256);
        AddIn("r.ReviewedBy", "Rv", filter.Reviewer, 256);
        switch ((filter.Escalation ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "yes": where.Add("r.IsEscalation = 1"); break;
            case "no": where.Add("r.IsEscalation = 0"); break;
        }
        if (!string.IsNullOrWhiteSpace(filter.Search))
        {
            where.Add("(w.ClaimID LIKE @Search OR w.PatientID LIKE @Search OR w.AssignedAgentUser LIKE @Search OR r.SubmittedBy LIKE @Search OR w.PayerName LIKE @Search)");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 210).Value = "%" + filter.Search.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]") + "%";
        }

        var page = Math.Max(1, filter.Page);
        var pageSize = Math.Clamp(filter.PageSize, 5, 1000);
        var order = QaSortColumns.TryGetValue(filter.SortBy ?? string.Empty, out var col) ? col : "r.SubmittedOn";
        var dir = filter.SortDesc ? "DESC" : "ASC";
        cmd.Parameters.Add("@Offset", SqlDbType.Int).Value = (page - 1) * pageSize;
        cmd.Parameters.Add("@PageSize", SqlDbType.Int).Value = pageSize;
        cmd.Parameters.Add("@Me", SqlDbType.NVarChar, 256).Value = user.UserName;
        var whereSql = string.Join(" AND ", where);

        cmd.CommandText = $@"
-- Summary over the caller's scope (not the filters), like the mockup tiles
SELECT SUM(CASE WHEN r.ReviewStatus = 'Awaiting QA' THEN 1 ELSE 0 END),
       SUM(CASE WHEN r.ReviewStatus = 'Awaiting QA' AND r.IsEscalation = 1 THEN 1 ELSE 0 END),
       SUM(CASE WHEN r.ReviewStatus = 'Awaiting QA' AND r.IsWriteOff = 1 THEN 1 ELSE 0 END),
       SUM(CASE WHEN r.ReviewStatus = 'Rejected' THEN 1 ELSE 0 END),
       SUM(CASE WHEN r.ReviewStatus = 'Approved' THEN 1 ELSE 0 END)
FROM dbo.ARWB_ClaimQaReview r
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = r.ClaimKey
WHERE r.IsCurrent = 1 {scope};

SELECT COUNT(*)
FROM dbo.ARWB_ClaimQaReview r
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = r.ClaimKey
WHERE r.IsCurrent = 1 AND {whereSql} {scope};

SELECT w.ClaimKey, w.ClaimID, w.LabName, w.PayerName, w.PanelName, w.DenialCategory, w.InsuranceBalance, w.WorkflowStatus, w.AssignedAgentUser,
       r.QaReviewId, r.ReviewStatus, r.IsEscalation, r.IsWriteOff, r.SubmittedBy, r.SubmittedOn, r.ReviewedBy, r.ReviewedOn, r.ErrorType, r.ReviewNote,
       f.FollowUpClaimStatus, f.FixResolution, f.FollowUpComment,
       CAST(CASE WHEN r.SubmittedBy = @Me OR w.AssignedAgentUser = @Me THEN 1 ELSE 0 END AS bit)
FROM dbo.ARWB_ClaimQaReview r
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = r.ClaimKey
LEFT JOIN dbo.ARWB_ClaimFollowUp f ON f.FollowUpId = r.FollowUpId
WHERE r.IsCurrent = 1 AND {whereSql} {scope}
ORDER BY {order} {dir}, r.QaReviewId {dir}
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

SELECT r.ReviewedBy, COUNT(*)
FROM dbo.ARWB_ClaimQaReview r
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = r.ClaimKey
WHERE r.IsCurrent = 1 AND r.ReviewedBy IS NOT NULL {scope}
GROUP BY r.ReviewedBy ORDER BY r.ReviewedBy;";

        var queue = new ArWorkbenchQaQueue { Rows = new ArWorkbenchPagedResult<ArWorkbenchQaRow> { Page = page, PageSize = pageSize } };
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            static int I(SqlDataReader x, int i) => x.IsDBNull(i) ? 0 : x.GetInt32(i);
            if (await r.ReadAsync(ct))
            {
                var s = queue.Summary;
                s.AwaitingQa = I(r, 0); s.EscalationsPending = I(r, 1); s.WriteOffsPending = I(r, 2); s.Rejected = I(r, 3); s.Approved = I(r, 4);
                s.RejectRate = s.Approved + s.Rejected > 0 ? Math.Round((decimal)s.Rejected / (s.Approved + s.Rejected), 4) : null;
            }
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct)) queue.Rows.TotalCount = r.GetInt32(0);
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                queue.Rows.Items.Add(new ArWorkbenchQaRow
                {
                    ClaimKey = r.GetInt64(0), ClaimID = r.GetString(1), LabName = Str(r, 2), PayerName = Str(r, 3), PanelName = Str(r, 4),
                    DenialCategory = Str(r, 5), InsuranceBalance = r.GetDecimal(6), WorkflowStatus = r.GetString(7), AssignedAgentUser = Str(r, 8),
                    QaReviewId = r.GetInt64(9), ReviewStatus = r.GetString(10), IsEscalation = r.GetBoolean(11), IsWriteOff = r.GetBoolean(12),
                    SubmittedBy = r.GetString(13), SubmittedOn = r.GetDateTime(14), ReviewedBy = Str(r, 15), ReviewedOn = Date(r, 16),
                    ErrorType = Str(r, 17), ReviewNote = Str(r, 18), FollowUpClaimStatus = Str(r, 19), FixResolution = Str(r, 20),
                    FollowUpComment = Str(r, 21), IsOwnWork = r.GetBoolean(22)
                });
            }
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
                queue.Reviewers.Add(new ArWorkbenchFilterOption { Value = r.GetString(0), Label = r.GetString(0), Count = r.GetInt32(1) });
        }

        var names = await GetDisplayNamesAsync(queue.Rows.Items.Select(i => i.AssignedAgentUser).Concat(queue.Reviewers.Select(v => v.Value)), ct);
        foreach (var item in queue.Rows.Items)
            item.AssignedAgentName = item.AssignedAgentUser is not null && names.TryGetValue(item.AssignedAgentUser, out var n) ? n : item.AssignedAgentUser;
        foreach (var v in queue.Reviewers)
            if (names.TryGetValue(v.Value, out var n)) v.Label = n;
        return queue;
    }

    public async Task<ArWorkbenchQaReview?> GetCurrentQaReviewAsync(int labId, long claimKey, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT QaReviewId, ReviewStatus, IsEscalation, IsWriteOff, SubmittedBy, SubmittedOn, ReviewedBy, ReviewedOn, ErrorType, ReviewNote,
       ScoreClaimAnalysis, ScoreDenialCategory, ScoreActionTaken, ScoreDocumentation, ScoreFinancialUpdate, ScoreFollowUpTiming
FROM dbo.ARWB_ClaimQaReview WHERE ClaimKey = @K AND IsCurrent = 1;", connection);
        cmd.Parameters.Add("@K", SqlDbType.BigInt).Value = claimKey;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        bool? B(int i) => r.IsDBNull(i) ? null : r.GetBoolean(i);
        return new ArWorkbenchQaReview
        {
            QaReviewId = r.GetInt64(0), ReviewStatus = r.GetString(1), IsEscalation = r.GetBoolean(2), IsWriteOff = r.GetBoolean(3),
            SubmittedBy = r.GetString(4), SubmittedOn = r.GetDateTime(5), ReviewedBy = Str(r, 6), ReviewedOn = Date(r, 7),
            ErrorType = Str(r, 8), ReviewNote = Str(r, 9),
            Scores = new ArWorkbenchQaScores
            {
                ClaimAnalysis = B(10), DenialCategory = B(11), ActionTaken = B(12), Documentation = B(13), FinancialUpdate = B(14), FollowUpTiming = B(15)
            }
        };
    }

    /// <summary>One QA decision in its own transaction. Outcome: ok | notfound | notawaiting | ownwork.</summary>
    public async Task<(string Outcome, string ClaimId, bool Escalation, bool WriteOff)> DecideQaAsync(int labId, long claimKey, ArWorkbenchQaDecision decision,
        ArWorkbenchUserContext user, Guid? bulkBatchId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandTimeout = 120;
        var scope = AppendScope(cmd, user);
        var p = cmd.Parameters;
        p.Add("@ClaimKey", SqlDbType.BigInt).Value = claimKey;
        p.Add("@Approve", SqlDbType.Bit).Value = decision.Approve;
        p.Add("@ErrorType", SqlDbType.NVarChar, 100).Value = (object?)decision.ErrorType ?? DBNull.Value;
        p.Add("@Note", SqlDbType.NVarChar, 2000).Value = (object?)decision.Note ?? DBNull.Value;
        p.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        p.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        p.Add("@Bulk", SqlDbType.UniqueIdentifier).Value = (object?)bulkBatchId ?? DBNull.Value;
        void Score(string name, bool? v) => p.Add(name, SqlDbType.Bit).Value = (object?)v ?? DBNull.Value;
        Score("@S1", decision.Scores?.ClaimAnalysis); Score("@S2", decision.Scores?.DenialCategory); Score("@S3", decision.Scores?.ActionTaken);
        Score("@S4", decision.Scores?.Documentation); Score("@S5", decision.Scores?.FinancialUpdate); Score("@S6", decision.Scores?.FollowUpTiming);

        cmd.CommandText = $@"
SET NOCOUNT ON;
DECLARE @ClaimID nvarchar(200), @Agent nvarchar(256), @Prev varchar(30);
SELECT @ClaimID = w.ClaimID, @Agent = w.AssignedAgentUser, @Prev = w.WorkflowStatus
FROM dbo.ARWB_Claim w WITH (UPDLOCK, ROWLOCK)
WHERE w.ClaimKey = @ClaimKey {scope};
IF @ClaimID IS NULL BEGIN SELECT 'notfound', N'', 0, 0; RETURN; END;

DECLARE @ReviewId bigint, @Status varchar(20), @SubmittedBy nvarchar(256), @IsEsc bit, @IsWO bit;
SELECT @ReviewId = r.QaReviewId, @Status = r.ReviewStatus, @SubmittedBy = r.SubmittedBy, @IsEsc = r.IsEscalation, @IsWO = r.IsWriteOff
FROM dbo.ARWB_ClaimQaReview r WITH (UPDLOCK, ROWLOCK)
WHERE r.ClaimKey = @ClaimKey AND r.IsCurrent = 1;
IF @ReviewId IS NULL OR @Status <> 'Awaiting QA' BEGIN SELECT 'notawaiting', @ClaimID, 0, 0; RETURN; END;
IF @SubmittedBy = @User OR @Agent = @User BEGIN SELECT 'ownwork', @ClaimID, 0, 0; RETURN; END;

DECLARE @Now datetime2(0) = SYSUTCDATETIME();
UPDATE dbo.ARWB_ClaimQaReview
SET ReviewStatus = CASE WHEN @Approve = 1 THEN 'Approved' ELSE 'Rejected' END,
    ReviewedBy = @User, ReviewedByRole = @Role, ReviewedOn = @Now,
    ErrorType = CASE WHEN @Approve = 1 THEN NULL ELSE @ErrorType END, ReviewNote = @Note,
    ScoreClaimAnalysis = @S1, ScoreDenialCategory = @S2, ScoreActionTaken = @S3,
    ScoreDocumentation = @S4, ScoreFinancialUpdate = @S5, ScoreFollowUpTiming = @S6,
    BulkBatchId = @Bulk
WHERE QaReviewId = @ReviewId;

IF @Approve = 1
BEGIN
    UPDATE dbo.ARWB_Claim
    SET WorkflowStatus     = 'Completed',
        EscalationApproved = @IsEsc,
        IsWriteOffApproved = CASE WHEN @IsWO = 1 THEN 1 ELSE IsWriteOffApproved END,
        WriteOffApprovedOn = CASE WHEN @IsWO = 1 THEN @Now ELSE WriteOffApprovedOn END,
        WriteOffApprovedBy = CASE WHEN @IsWO = 1 THEN @User ELSE WriteOffApprovedBy END,
        IsPmsPostedConfirmed = CASE WHEN @IsWO = 1 THEN 0 ELSE IsPmsPostedConfirmed END,
        UpdatedOn = @Now, UpdatedBy = @User
    WHERE ClaimKey = @ClaimKey;

    INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
    VALUES (@ClaimKey, @Now, N'QA Approved', ISNULL(@Note, N'Meets quality standard.'), @Prev, N'Completed', @User, @Role, 'QaReview', @ReviewId);

    IF @IsEsc = 1
    BEGIN
        DECLARE @Cases TABLE (CipCaseId bigint, RoundNumber int);
        UPDATE dbo.ARWB_CipCase SET CaseStatus = 'Pending Approval'
        OUTPUT inserted.CipCaseId, inserted.RoundNumber INTO @Cases
        WHERE ClaimKey = @ClaimKey AND CaseStatus = 'Awaiting QA';
        INSERT INTO dbo.ARWB_CipCaseHistory (CipCaseId, RoundNumber, ActionOn, Actor, ActorRole, ActionName, Note, IsBulkAction, BulkBatchId)
        SELECT c.CipCaseId, c.RoundNumber, @Now, @User, @Role, N'QA Approved', N'Note approved by QA; the escalation is pending approval to send to the client.',
               CASE WHEN @Bulk IS NULL THEN 0 ELSE 1 END, @Bulk
        FROM @Cases c;
        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode)
        VALUES (@ClaimKey, @Now, N'CIP Escalation Released', N'QA approved the CIP note: the escalation moves to Pending Approval.', N'Awaiting QA', N'Pending Approval', @User, @Role);
    END;

    IF @IsWO = 1
    BEGIN
        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, NewValue, UserName, RoleCode)
        VALUES (@ClaimKey, @Now, N'Write-Off Approved', N'Write Off approved by QA. Post the write-off in the PMS, then Mark as Posted.', N'Approved Write-Off', @User, @Role);
        IF @Agent IS NOT NULL
            INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientUser, NotificationType, Message, CreatedOn)
            VALUES (@ClaimKey, @Agent, 'WriteOffApproved', N'Write-off approved for claim ' + @ClaimID + N'. Post it in the PMS, then Mark as Posted.', @Now);
    END;
END
ELSE
BEGIN
    UPDATE dbo.ARWB_Claim SET WorkflowStatus = 'QA Rejected', EscalationApproved = 0, UpdatedOn = @Now, UpdatedBy = @User
    WHERE ClaimKey = @ClaimKey;

    INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
    VALUES (@ClaimKey, @Now, N'QA Rejected', LEFT(@ErrorType + N' - ' + @Note, 2000), @Prev, N'QA Rejected', @User, @Role, 'QaReview', @ReviewId);

    -- The CIP case held for this note is closed; the corrected note opens a new one.
    DECLARE @Closed TABLE (CipCaseId bigint, RoundNumber int);
    UPDATE dbo.ARWB_CipCase
    SET CaseStatus = 'Returned to Agent', ClosedOn = @Now, LastReviewDecision = 'rejected', LastReviewNote = @Note,
        LastReviewedBy = @User, LastReviewedByRole = @Role, LastReviewedOn = @Now
    OUTPUT inserted.CipCaseId, inserted.RoundNumber INTO @Closed
    WHERE ClaimKey = @ClaimKey AND CaseStatus = 'Awaiting QA';
    INSERT INTO dbo.ARWB_CipCaseHistory (CipCaseId, RoundNumber, ActionOn, Actor, ActorRole, ActionName, Note, IsBulkAction, BulkBatchId)
    SELECT c.CipCaseId, c.RoundNumber, @Now, @User, @Role, N'QA Rejected', @Note, 0, NULL FROM @Closed c;
END;

DECLARE @recalc TABLE (UpdatedClaims int);
INSERT INTO @recalc EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKey = @ClaimKey;

SELECT 'ok', @ClaimID, @IsEsc, @IsWO;";

        string outcome, claimId;
        bool esc, wo;
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            await r.ReadAsync(ct);
            outcome = r.GetString(0);
            claimId = r.GetString(1);
            esc = Convert.ToBoolean(r.GetValue(2));
            wo = Convert.ToBoolean(r.GetValue(3));
        }
        if (outcome == "ok") await tx.CommitAsync(ct); else await tx.RollbackAsync(ct);
        return (outcome, claimId, esc, wo);
    }
}

/// <summary>A validated QA decision.</summary>
public sealed record ArWorkbenchQaDecision(bool Approve, string? ErrorType, string? Note, ArWorkbenchQaScores? Scores);

public static class ArWorkbenchQaRules
{
    public const int NoteMaxLength = 2000;

    /// <summary>Approve needs nothing more; reject needs an error type from the QA_ERROR_TYPE list and a note.</summary>
    public static (ArWorkbenchQaDecision? Decision, string? Error) Validate(ArWorkbenchQaDecisionRequest? request, IReadOnlyCollection<string> errorTypes)
    {
        if (request is null) return (null, "Send the decision.");
        var kind = (request.Decision ?? string.Empty).Trim().ToLowerInvariant();
        if (kind is not ("approve" or "reject")) return (null, "Decision must be approve or reject.");
        var note = string.IsNullOrWhiteSpace(request.Note) ? null : request.Note.Trim();
        if (note is { Length: > NoteMaxLength }) return (null, $"The note must be {NoteMaxLength:N0} characters or fewer.");
        if (kind == "approve") return (new ArWorkbenchQaDecision(true, null, note, request.Scores), null);

        var errorType = errorTypes.FirstOrDefault(e => string.Equals(e, request.ErrorType?.Trim(), StringComparison.OrdinalIgnoreCase));
        if (errorType is null) return (null, "Choose the Error Type for the rejection.");
        if (note is null) return (null, "Add a note explaining what needs correcting.");
        return (new ArWorkbenchQaDecision(false, errorType, note, request.Scores), null);
    }
}
