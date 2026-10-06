using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Follow-up notes, Data Processing insights and timely-filing limits.
///
/// Logging a note follows the mockup (App.actions.logFollowUp) in one transaction: the note, a new
/// current QA review ("Awaiting QA"), a CIP case when the resolution is "CIP - Client Escalations"
/// (held at "Awaiting QA" - it reaches Pending Approval only once QA approves the note), the claim
/// (Worked, Submitted for QA, last / next follow-up), the activity log, then the claim's queue.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    public const string CipResolution = "CIP - Client Escalations";
    public const string WriteOffResolution = "Write Off";
    public const string DeniedStatus = "Denied";

    public async Task<(ArWorkbenchSaveStatus Status, string Message, ArWorkbenchFollowUpResult? Result)> LogFollowUpAsync(
        int labId, long claimKey, ArWorkbenchFollowUpRequest request, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        // 1. The claim, locked, within the caller's scope (an agent only reaches their own claims).
        string claimId, workflowStatus;
        string? assignedAgent, clinic;
        bool financiallyClosed, adHoc;
        await using (var cmd = connection.CreateCommand())
        {
            cmd.Transaction = tx;
            var scope = AppendScope(cmd, user);
            cmd.Parameters.Add("@ClaimKey", SqlDbType.BigInt).Value = claimKey;
            cmd.CommandText = $@"
SELECT w.ClaimID, w.WorkflowStatus, w.AssignedAgentUser, w.ClinicName, w.IsFinanciallyClosed, w.AdHocFollowUpAssigned
FROM dbo.ARWB_Claim w WITH (UPDLOCK, ROWLOCK)
WHERE w.ClaimKey = @ClaimKey {scope};";
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (!await r.ReadAsync(ct)) return (ArWorkbenchSaveStatus.NotFound, "Claim not found.", null);
            claimId = r.GetString(0);
            workflowStatus = r.GetString(1);
            assignedAgent = Str(r, 2);
            clinic = Str(r, 3);
            financiallyClosed = r.GetBoolean(4);
            adHoc = r.GetBoolean(5);
        }

        // As the mockup: no note while one is already waiting for QA, or on a closed claim (unless it
        // was handed to an agent ad hoc, which is exactly so it can be followed up).
        if (workflowStatus == "Submitted for QA")
            return (ArWorkbenchSaveStatus.Conflict, $"Claim {claimId} is already waiting for QA review of its last follow-up note.", null);
        if (financiallyClosed && !adHoc)
            return (ArWorkbenchSaveStatus.Conflict, $"Claim {claimId} is financially closed, so there is nothing left to follow up.", null);

        // 2. The note's values against the master lists (case-insensitive; the list's own text is stored).
        var lists = await ReadActiveListsAsync(connection, tx, ct);
        var allowedFixes = await ReadFixesForStatusAsync(connection, tx, request.ClaimStatus, ct);
        var v = ArWorkbenchFollowUpRules.Validate(request, lists, allowedFixes, DateTime.UtcNow.Date);
        if (v.Error is not null) return (ArWorkbenchSaveStatus.Invalid, v.Error, null);
        var note = v.Note!;

        var isCip = note.FixResolution == CipResolution;
        var isWriteOff = note.FixResolution == WriteOffResolution;

        await using var cmd2 = connection.CreateCommand();
        cmd2.Transaction = tx;
        cmd2.CommandTimeout = 120;
        var p = cmd2.Parameters;
        p.Add("@ClaimKey", SqlDbType.BigInt).Value = claimKey;
        p.Add("@ClaimType", SqlDbType.NVarChar, 50).Value = note.ClaimType;
        p.Add("@FollowUpType", SqlDbType.NVarChar, 50).Value = note.FollowUpType;
        p.Add("@Status", SqlDbType.NVarChar, 100).Value = note.ClaimStatus;
        p.Add("@RootCause", SqlDbType.NVarChar, 400).Value = (object?)note.DenialRootCause ?? DBNull.Value;
        p.Add("@Fix", SqlDbType.NVarChar, 200).Value = note.FixResolution;
        p.Add("@Comment", SqlDbType.NVarChar, 4000).Value = note.Comment;
        p.Add("@Next", SqlDbType.Date).Value = (object?)note.NextFollowUpDate ?? DBNull.Value;
        p.Add("@CipCategory", SqlDbType.NVarChar, 200).Value = (object?)note.CipCategory ?? DBNull.Value;
        p.Add("@CipInfo", SqlDbType.NVarChar, 400).Value = (object?)note.CipRequiredInfo ?? DBNull.Value;
        p.Add("@CipComment", SqlDbType.NVarChar, 4000).Value = (object?)note.CipComment ?? DBNull.Value;
        p.Add("@IsCip", SqlDbType.Bit).Value = isCip;
        p.Add("@IsWriteOff", SqlDbType.Bit).Value = isWriteOff;
        p.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        p.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        p.Add("@Agent", SqlDbType.NVarChar, 256).Value = (object?)assignedAgent ?? user.UserName;
        p.Add("@Clinic", SqlDbType.NVarChar, 500).Value = (object?)clinic ?? DBNull.Value;
        p.Add("@Summary", SqlDbType.NVarChar, 2000).Value = Truncate($"{note.FollowUpType} · {note.ClaimStatus} · {note.FixResolution} — {note.Comment}", 2000);

        cmd2.CommandText = @"
SET NOCOUNT ON;
DECLARE @Today date = CONVERT(date, SYSUTCDATETIME());
DECLARE @FollowUpId bigint, @CipCaseId bigint = NULL;

INSERT INTO dbo.ARWB_ClaimFollowUp
    (ClaimKey, ClaimType, FollowUpType, FollowUpClaimStatus, DenialRootCause, FixResolution, FollowUpComment,
     NextFollowUpDate, CipCategory, CipRequiredInfo, CipComment, CreatedBy, CreatedByRole)
VALUES (@ClaimKey, @ClaimType, @FollowUpType, @Status, @RootCause, @Fix, @Comment,
        @Next, @CipCategory, @CipInfo, @CipComment, @User, @Role);
SET @FollowUpId = SCOPE_IDENTITY();

-- One current QA review per claim: the new note supersedes any earlier outcome.
UPDATE dbo.ARWB_ClaimQaReview SET IsCurrent = 0 WHERE ClaimKey = @ClaimKey AND IsCurrent = 1;
INSERT INTO dbo.ARWB_ClaimQaReview (ClaimKey, FollowUpId, ReviewStatus, IsEscalation, IsWriteOff, IsCurrent, SubmittedBy)
VALUES (@ClaimKey, @FollowUpId, 'Awaiting QA', @IsCip, @IsWriteOff, 1, @User);

IF @IsCip = 1
BEGIN
    INSERT INTO dbo.ARWB_CipCase
        (ClaimKey, FollowUpId, CipCategory, RequiredInfo, CipComment, CaseStatus, RoundNumber, OriginalAgentUser, ClinicName,
         RequestedBy, RequestedByRole, FollowUpDate)
    VALUES (@ClaimKey, @FollowUpId, @CipCategory, @CipInfo, @CipComment, 'Awaiting QA', 1, @Agent, @Clinic,
            @User, @Role, @Today);
    SET @CipCaseId = SCOPE_IDENTITY();

    INSERT INTO dbo.ARWB_CipCaseHistory (CipCaseId, RoundNumber, Actor, ActorRole, ActionName, Note)
    VALUES (@CipCaseId, 1, @User, @Role, N'Escalation Logged', @CipComment);
END;

DECLARE @PrevStatus varchar(30) = (SELECT WorkflowStatus FROM dbo.ARWB_Claim WHERE ClaimKey = @ClaimKey);

UPDATE dbo.ARWB_Claim
SET LastFollowUpDate      = @Today,
    NextFollowUpDate      = @Next,
    FixResolution         = @Fix,
    DenialRootCause       = CASE WHEN @Status = N'Denied' THEN @RootCause END,
    WorkedStatus          = 'Worked',
    WorkflowStatus        = 'Submitted for QA',
    EscalationApproved    = 0,           -- a new submission supersedes any earlier approval outcome
    NewDenialSinceWork    = 0,           -- the new denial has now been worked
    AdHocFollowUpAssigned = 0,           -- an ad-hoc hand-off is satisfied by the note
    UpdatedOn             = SYSUTCDATETIME(),
    UpdatedBy             = @User
WHERE ClaimKey = @ClaimKey;

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
VALUES (@ClaimKey, N'Follow-Up Logged', @Summary, @Fix, @User, @Role, 'FollowUp', @FollowUpId);

INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
VALUES (@ClaimKey, N'Submitted for QA',
        CASE WHEN @IsCip = 1 THEN N'Routed to the QA Verification Queue. The CIP escalation goes to approval once QA approves the note.'
             ELSE N'Automatically routed to the QA Verification Queue.' END,
        @PrevStatus, N'Submitted for QA', @User, @Role, 'QaReview', @FollowUpId);

IF @IsCip = 1
    INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActionType, Detail, UserName, RoleCode, RelatedEntityType, RelatedEntityId)
    VALUES (@ClaimKey, N'CIP Escalation Logged', LEFT(@CipCategory + N' · ' + @CipInfo + N' — ' + @CipComment, 2000), @User, @Role, 'CipCase', @CipCaseId);

EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKey = @ClaimKey;

SELECT FollowUpId = @FollowUpId, CipCaseId = @CipCaseId,
       WorkflowStatus = (SELECT WorkflowStatus FROM dbo.ARWB_Claim WHERE ClaimKey = @ClaimKey);";

        var result = new ArWorkbenchFollowUpResult();
        await using (var r = await cmd2.ExecuteReaderAsync(ct))
        {
            // The recalculation may return result sets of its own; the last SELECT is ours.
            do
            {
                if (r.FieldCount == 3 && r.GetName(0) == "FollowUpId" && await r.ReadAsync(ct))
                {
                    result.FollowUpId = r.GetInt64(0);
                    result.CipCaseId = r.IsDBNull(1) ? null : r.GetInt64(1);
                    result.WorkflowStatus = r.GetString(2);
                }
            } while (await r.NextResultAsync(ct));
        }

        await tx.CommitAsync(ct);
        result.Message = isCip
            ? $"Follow-up logged on {claimId} and sent to QA. The CIP escalation goes to approval once QA approves the note."
            : $"Follow-up logged on {claimId} and sent to the QA Verification Queue.";
        return (ArWorkbenchSaveStatus.Ok, result.Message, result);
    }

    private static async Task<Dictionary<string, List<string>>> ReadActiveListsAsync(SqlConnection connection, SqlTransaction tx, CancellationToken ct)
    {
        var lists = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        await using var cmd = new SqlCommand(@"
SELECT ListType, ItemValue FROM dbo.ARWB_MasterListItem
WHERE IsActive = 1 AND ListType IN ('CLAIM_TYPE', 'FOLLOW_UP_TYPE', 'CLAIM_STATUS', 'DENIAL_ROOT_CAUSE', 'FIX_RESOLUTION', 'CIP_CATEGORY', 'CIP_REQUIRED_INFO')
ORDER BY ListType, SortOrder;", connection, tx);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            if (!lists.TryGetValue(r.GetString(0), out var list)) lists[r.GetString(0)] = list = new List<string>();
            list.Add(r.GetString(1));
        }
        return lists;
    }

    private static async Task<List<string>> ReadFixesForStatusAsync(SqlConnection connection, SqlTransaction tx, string? status, CancellationToken ct)
    {
        var fixes = new List<string>();
        if (string.IsNullOrWhiteSpace(status)) return fixes;
        await using var cmd = new SqlCommand("SELECT FixResolution FROM dbo.ARWB_FixResolutionByStatus WHERE ClaimStatus = @Status ORDER BY SortOrder;", connection, tx);
        cmd.Parameters.Add("@Status", SqlDbType.NVarChar, 100).Value = status.Trim();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) fixes.Add(r.GetString(0));
        return fixes;
    }

    // ==========================================================================================
    // Denial Analysis Report (Data Processing): current + previous sync week, live remainder
    // ==========================================================================================

    public async Task<IReadOnlyList<ArWorkbenchInsightRow>> GetInsightsAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT DenialInsightId, WeekStart, IsCurrentWeek, DenialCode, DenialDescription, DenialCategory, CategoryTag, RecommendedAction,
       ClaimCountAtBuild, TotalBalanceAtBuild, OutstandingClaims, OutstandingBalance, TopPayer, TopPayerBalance, ImpactPct,
       TopServiceLine, Observation
FROM dbo.ARWB_vw_DenialInsight
ORDER BY IsCurrentWeek DESC, OutstandingBalance DESC, DenialCode;", connection) { CommandTimeout = 120 };

        var rows = new List<ArWorkbenchInsightRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new ArWorkbenchInsightRow
            {
                DenialInsightId = r.GetInt32(0),
                WeekStart = r.GetDateTime(1),
                IsCurrentWeek = r.GetBoolean(2),
                DenialCode = r.GetString(3),
                DenialDescription = Str(r, 4),
                DenialCategory = Str(r, 5),
                CategoryTag = Str(r, 6),
                RecommendedAction = Str(r, 7),
                ClaimCountAtBuild = r.GetInt32(8),
                TotalBalanceAtBuild = r.GetDecimal(9),
                OutstandingClaims = r.GetInt32(10),
                OutstandingBalance = r.GetDecimal(11),
                TopPayer = Str(r, 12),
                TopPayerBalance = r.IsDBNull(13) ? null : r.GetDecimal(13),
                ImpactPct = r.IsDBNull(14) ? null : r.GetDecimal(14),
                TopServiceLine = Str(r, 15),
                Observation = Str(r, 16)
            });
        }
        return rows;
    }

    // ==========================================================================================
    // Timely-filing limits (dbo.ARWB_TflThreshold + AppSetting TflDefaultDays / TflRiskWindowDays)
    // A change re-derives every claim's TFL deadline and risk flag through the one implementation
    // of those rules (dbo.ARWB_usp_RecalculateClaimState).
    // ==========================================================================================

    public async Task<ArWorkbenchTflSettings> GetTflSettingsAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT t.FinancialClass, t.ThresholdDays, ISNULL(c.Claims, 0)
FROM dbo.ARWB_TflThreshold t
OUTER APPLY (SELECT Claims = COUNT(*) FROM dbo.ARWB_Claim w WHERE w.PayerType = t.FinancialClass) c
ORDER BY t.FinancialClass;

SELECT w.PayerType, COUNT(*)
FROM dbo.ARWB_Claim w
WHERE w.PayerType IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.ARWB_TflThreshold t WHERE t.FinancialClass = w.PayerType)
GROUP BY w.PayerType
ORDER BY COUNT(*) DESC;

SELECT
    COALESCE(TRY_CONVERT(int, (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('TflDefaultDays', N'180'))), 180),
    COALESCE(TRY_CONVERT(int, (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('TflRiskWindowDays', N'30'))), 30);", connection) { CommandTimeout = 120 };

        var settings = new ArWorkbenchTflSettings();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            settings.Thresholds.Add(new ArWorkbenchTflThreshold { FinancialClass = r.GetString(0), ThresholdDays = r.GetInt32(1), ClaimCount = r.GetInt32(2) });
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct))
            settings.UnmappedClasses.Add(new ArWorkbenchTflThreshold { FinancialClass = r.GetString(0), ClaimCount = r.GetInt32(1) });
        await r.NextResultAsync(ct);
        if (await r.ReadAsync(ct))
        {
            settings.DefaultDays = r.GetInt32(0);
            settings.RiskWindowDays = r.GetInt32(1);
        }
        return settings;
    }

    public async Task<ArWorkbenchSaveResult> SaveTflThresholdAsync(int labId, string? originalClass, string financialClass, int days, string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = new SqlCommand(@"
SET NOCOUNT ON;
DECLARE @Exists bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_TflThreshold WITH (UPDLOCK, HOLDLOCK) WHERE FinancialClass = @Class
                                         AND (@Original IS NULL OR FinancialClass <> @Original)) THEN 1 ELSE 0 END;
IF @Exists = 1 BEGIN SELECT 'Conflict'; RETURN; END;

IF @Original IS NULL
    INSERT INTO dbo.ARWB_TflThreshold (FinancialClass, ThresholdDays) VALUES (@Class, @Days);
ELSE
BEGIN
    UPDATE dbo.ARWB_TflThreshold SET FinancialClass = @Class, ThresholdDays = @Days WHERE FinancialClass = @Original;
    IF @@ROWCOUNT = 0 BEGIN SELECT 'NotFound'; RETURN; END;
END;
SELECT 'Ok';", connection, tx);
        cmd.Parameters.Add("@Original", SqlDbType.NVarChar, 200).Value = string.IsNullOrWhiteSpace(originalClass) ? DBNull.Value : originalClass.Trim();
        cmd.Parameters.Add("@Class", SqlDbType.NVarChar, 200).Value = financialClass;
        cmd.Parameters.Add("@Days", SqlDbType.Int).Value = days;
        var outcome = Convert.ToString(await cmd.ExecuteScalarAsync(ct));
        if (outcome == "Conflict") return ArWorkbenchSaveResult.Conflict($"\"{financialClass}\" already has a timely-filing limit.");
        if (outcome == "NotFound") return ArWorkbenchSaveResult.NotFound($"\"{originalClass}\" no longer exists. Reload the page.");

        await RecalculateAllAsync(connection, tx, ct);
        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok($"{financialClass}: {days} days saved. TFL deadlines and risk flags were recalculated.");
    }

    public async Task<ArWorkbenchSaveResult> DeleteTflThresholdAsync(int labId, string financialClass, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = new SqlCommand("DELETE dbo.ARWB_TflThreshold WHERE FinancialClass = @Class;", connection, tx);
        cmd.Parameters.Add("@Class", SqlDbType.NVarChar, 200).Value = financialClass.Trim();
        if (await cmd.ExecuteNonQueryAsync(ct) == 0) return ArWorkbenchSaveResult.NotFound($"\"{financialClass}\" no longer exists. Reload the page.");
        await RecalculateAllAsync(connection, tx, ct);
        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok($"{financialClass} removed; its claims now use the default limit. TFL deadlines were recalculated.");
    }

    public async Task<ArWorkbenchSaveResult> SaveTflDefaultsAsync(int labId, int defaultDays, int riskWindowDays, string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = new SqlCommand(@"
MERGE dbo.ARWB_AppSetting AS t
USING (VALUES ('TflDefaultDays', CONVERT(nvarchar(400), @Default)), ('TflRiskWindowDays', CONVERT(nvarchar(400), @Window))) AS s (SettingKey, SettingValue)
   ON t.SettingKey = s.SettingKey
WHEN MATCHED THEN UPDATE SET SettingValue = s.SettingValue, UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
WHEN NOT MATCHED THEN INSERT (SettingKey, SettingValue, UpdatedOn, UpdatedBy) VALUES (s.SettingKey, s.SettingValue, SYSUTCDATETIME(), @User);", connection, tx);
        cmd.Parameters.Add("@Default", SqlDbType.Int).Value = defaultDays;
        cmd.Parameters.Add("@Window", SqlDbType.Int).Value = riskWindowDays;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
        await cmd.ExecuteNonQueryAsync(ct);
        await RecalculateAllAsync(connection, tx, ct);
        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok($"Default limit {defaultDays} days, risk window {riskWindowDays} days saved. TFL deadlines and risk flags were recalculated.");
    }

    private static async Task RecalculateAllAsync(SqlConnection connection, SqlTransaction tx, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("dbo.ARWB_usp_RecalculateClaimState", connection, tx) { CommandType = CommandType.StoredProcedure, CommandTimeout = 900 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.NextResultAsync(ct)) { }
    }
}

/// <summary>Validated, canonical follow-up values (each list value in the list's own spelling).</summary>
public sealed record ArWorkbenchFollowUpNote(
    string ClaimType, string FollowUpType, string ClaimStatus, string? DenialRootCause, string FixResolution,
    string Comment, DateTime? NextFollowUpDate, string? CipCategory, string? CipRequiredInfo, string? CipComment);

public sealed record ArWorkbenchFollowUpValidation(string? Error, ArWorkbenchFollowUpNote? Note);

/// <summary>The Log Follow-Up Note rules, free of SQL so they can be unit-tested.</summary>
public static class ArWorkbenchFollowUpRules
{
    public const int CommentMaxLength = 4000;
    public const int MaxDaysAhead = 730;

    public static ArWorkbenchFollowUpValidation Validate(ArWorkbenchFollowUpRequest? q, IReadOnlyDictionary<string, List<string>> lists,
        IReadOnlyCollection<string> fixesForStatus, DateTime todayUtc)
    {
        static ArWorkbenchFollowUpValidation Fail(string e) => new(e, null);
        if (q is null) return Fail("The follow-up note was not supplied.");

        string? Pick(string listType, string? value) =>
            lists.TryGetValue(listType, out var list)
                ? list.FirstOrDefault(x => string.Equals(x, value?.Trim(), StringComparison.OrdinalIgnoreCase))
                : null;

        var claimType = Pick("CLAIM_TYPE", q.ClaimType);
        if (claimType is null) return Fail("Choose a Claim Type from the list.");
        var followUpType = Pick("FOLLOW_UP_TYPE", q.FollowUpType);
        if (followUpType is null) return Fail("Choose a Follow Up Type from the list.");
        var status = Pick("CLAIM_STATUS", q.ClaimStatus);
        if (status is null) return Fail("Choose a Claim Status from the list.");

        string? rootCause = null;
        if (status == SqlArWorkbenchRepository.DeniedStatus)
        {
            rootCause = Pick("DENIAL_ROOT_CAUSE", q.DenialRootCause);
            if (rootCause is null) return Fail("A Denial Root Cause is required when the Claim Status is Denied.");
        }

        var fix = Pick("FIX_RESOLUTION", q.FixResolution);
        if (fix is null) return Fail("Choose a Fix / Resolution from the list.");
        // The Fix / Resolution by Claim Status rules narrow the list when the status has any.
        if (fixesForStatus.Count > 0 && !fixesForStatus.Contains(fix, StringComparer.OrdinalIgnoreCase))
            return Fail($"\"{fix}\" is not a Fix / Resolution for Claim Status \"{status}\".");

        var comment = (q.Comment ?? string.Empty).Trim();
        if (comment.Length == 0) return Fail("Add a follow-up comment: what did you find or do?");
        if (comment.Length > CommentMaxLength) return Fail($"The follow-up comment must be {CommentMaxLength:N0} characters or fewer.");

        DateTime? next = q.NextFollowUpDate?.Date;
        if (next is { } d)
        {
            if (d < todayUtc.Date.AddDays(-1)) return Fail("The next follow-up date cannot be in the past.");
            if (d > todayUtc.Date.AddDays(MaxDaysAhead)) return Fail($"The next follow-up date must be within {MaxDaysAhead / 365} years.");
        }

        string? cipCategory = null, cipInfo = null, cipComment = null;
        if (fix == SqlArWorkbenchRepository.CipResolution)
        {
            cipCategory = Pick("CIP_CATEGORY", q.CipCategory);
            if (cipCategory is null) return Fail("Choose a CIP Category for this client escalation.");
            cipInfo = Pick("CIP_REQUIRED_INFO", q.CipRequiredInfo);
            if (cipInfo is null) return Fail("Choose the Required Information for this client escalation.");
            cipComment = (q.CipComment ?? string.Empty).Trim();
            if (cipComment.Length == 0) return Fail("Add the CIP comment the client will see.");
            if (cipComment.Length > CommentMaxLength) return Fail($"The CIP comment must be {CommentMaxLength:N0} characters or fewer.");
        }

        return new(null, new ArWorkbenchFollowUpNote(claimType, followUpType, status, rootCause, fix, comment, next, cipCategory, cipInfo, cipComment));
    }
}
