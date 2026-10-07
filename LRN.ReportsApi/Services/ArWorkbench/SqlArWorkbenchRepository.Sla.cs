using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T075: the two reports the Denial Workflow's catalog had blocked, built on the AR Workbench's
/// event tables - RPT-04 Action Completion (ARWB_ClaimFollowUp + ARWB_ClaimQaReview + adjustment
/// activity) and RPT-09 Operational SLA (milestone instances from activity, follow-up, QA and CIP
/// history, measured against targets in ARWB_AppSetting) - and the SLA target settings.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const int MaxActionCompletionRows = 5000;

    /// <summary>Activity entries that complete an adjustment / write-off action.</summary>
    private static readonly string[] AdjustmentCompletionActions =
        ["Automatic Adjustment", "Write-Off Approved", "Adjustment Marked as Posted", "Adjustment Posted in PMS"];

    private static void AddRange(SqlCommand cmd, ArWorkbenchReportRange range)
    {
        cmd.Parameters.Add("@From", SqlDbType.DateTime2).Value = range.From.Date;
        cmd.Parameters.Add("@To", SqlDbType.DateTime2).Value = range.To.Date.AddDays(1); // exclusive
    }

    /// <summary>
    /// RPT-04: one row per completed action in the range, newest first (up to 5,000). A follow-up
    /// note's Fix / Resolution is the action and its QA review the verification; automatic
    /// adjustments, approved write-offs and PMS postings are completions too.
    /// </summary>
    private static async Task<ArWorkbenchReport> ActionCompletionReportAsync(SqlCommand cmd, string scope, ArWorkbenchReportRange range, CancellationToken ct)
    {
        AddRange(cmd, range);
        cmd.Parameters.Add("@Max", SqlDbType.Int).Value = MaxActionCompletionRows + 1;
        var adjustmentParams = new List<string>();
        for (var i = 0; i < AdjustmentCompletionActions.Length; i++)
        {
            adjustmentParams.Add($"@Adj{i}");
            cmd.Parameters.Add($"@Adj{i}", SqlDbType.NVarChar, 100).Value = AdjustmentCompletionActions[i];
        }

        cmd.CommandText = $@"
SELECT TOP (@Max) x.CompletedOn, x.ClaimID, x.PayerName, x.ActionName, x.ClaimStatus, x.CompletedBy, x.Verification, x.VerifiedOn, x.RemainingAR, x.Source
FROM
(
    SELECT f.CreatedOn AS CompletedOn, w.ClaimID, w.PayerName, f.FixResolution AS ActionName, f.FollowUpClaimStatus AS ClaimStatus, f.CreatedBy AS CompletedBy,
           CASE q.ReviewStatus WHEN 'Approved' THEN N'QA Approved' WHEN 'Rejected' THEN N'QA Rejected' WHEN 'Awaiting QA' THEN N'Awaiting QA' ELSE N'Not reviewed' END AS Verification,
           q.ReviewedOn AS VerifiedOn, w.RemainingAR, N'Follow-up note' AS Source
    FROM dbo.ARWB_ClaimFollowUp f
    INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = f.ClaimKey
    OUTER APPLY (SELECT TOP (1) r.ReviewStatus, r.ReviewedOn FROM dbo.ARWB_ClaimQaReview r WHERE r.FollowUpId = f.FollowUpId ORDER BY r.QaReviewId DESC) q
    WHERE f.IsSystem = 0 AND f.CreatedOn >= @From AND f.CreatedOn < @To {scope}

    UNION ALL

    SELECT a.ActivityOn, w.ClaimID, w.PayerName, a.ActionType, NULL, a.UserName,
           CASE WHEN a.IsSystem = 1 THEN N'System' ELSE N'Recorded' END, NULL, w.RemainingAR, N'Adjustment'
    FROM dbo.ARWB_ClaimActivity a
    INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey
    WHERE a.ActionType IN ({string.Join(", ", adjustmentParams)}) AND a.ActivityOn >= @From AND a.ActivityOn < @To {scope}
) x
ORDER BY x.CompletedOn DESC, x.ClaimID;";

        var report = new ArWorkbenchReport
        {
            Columns = [Col("completedOn", "Completed On", "date"), Col("claimId", "Claim ID"), Col("payer", "Payer"), Col("action", "Action (Fix / Resolution)"),
                       Col("claimStatus", "Claim Status"), Col("completedBy", "Completed By"), Col("verification", "Verification"), Col("verifiedOn", "Verified On", "date"),
                       Col("outstanding", "Outstanding Now", "money"), Col("source", "Source")]
        };
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                report.Rows.Add(ReportRow(r.GetDateTime(0), r.GetString(1), Str(r, 2), Str(r, 3), Str(r, 4), Str(r, 5), Str(r, 6),
                    r.IsDBNull(7) ? null : r.GetDateTime(7), DecOrZero(r, 8), r.GetString(9)));
            }
        }
        var capped = report.Rows.Count > MaxActionCompletionRows;
        if (capped) report.Rows.RemoveRange(MaxActionCompletionRows, report.Rows.Count - MaxActionCompletionRows);

        var notes = report.Rows.Count(x => (string?)x.Values[9] == "Follow-up note");
        var approved = report.Rows.Count(x => (string?)x.Values[6] == "QA Approved");
        report.Insights.Add($"{notes:N0} follow-up action(s) completed in the period, {approved:N0} of them verified by QA; {report.Rows.Count - notes:N0} adjustment / write-off event(s).");
        foreach (var top in report.Rows.Where(x => (string?)x.Values[9] == "Follow-up note")
                     .GroupBy(x => (string?)x.Values[3] ?? "-").OrderByDescending(g => g.Count()).Take(3))
            report.Insights.Add($"{top.Key}: {top.Count():N0} completed.");
        report.Note = (capped ? $"Showing the newest {MaxActionCompletionRows:N0} completions — narrow the date range to see the rest. " : string.Empty)
                      + "Dates are UTC. Outstanding Now is the claim's remaining insurance AR today, not at completion.";
        return report;
    }

    /// <summary>
    /// RPT-09: every milestone instance that started in the range, measured in calendar days against
    /// the target in ARWB_AppSetting, summarised per milestone. Completed on or before the due time
    /// = met; after = breached; not yet completed = open (on track, or overdue once past due).
    /// </summary>
    private async Task<ArWorkbenchReport> OperationalSlaReportAsync(SqlCommand cmd, string scope, ArWorkbenchReportRange range, CancellationToken ct)
    {
        var settings = await ReadSlaSettingsAsync(cmd.Connection, ct);
        AddRange(cmd, range);
        cmd.Parameters.Add("@Now", SqlDbType.DateTime2).Value = DateTime.UtcNow;
        foreach (var t in settings.Targets) cmd.Parameters.Add("@T_" + t.Key, SqlDbType.Int).Value = t.Days;

        cmd.CommandText = $@"
SET NOCOUNT ON;
CREATE TABLE #sla (Milestone varchar(40) NOT NULL, StartOn datetime2(0) NOT NULL, DueOn datetime2(0) NOT NULL, EndOn datetime2(0) NULL);

-- Assignment -> first follow-up after it
INSERT INTO #sla
SELECT 'ASSIGN_FIRST_FOLLOWUP', a.ActivityOn, DATEADD(day, @T_ASSIGN_FIRST_FOLLOWUP, a.ActivityOn),
       (SELECT MIN(f.CreatedOn) FROM dbo.ARWB_ClaimFollowUp f WHERE f.ClaimKey = a.ClaimKey AND f.IsSystem = 0 AND f.CreatedOn >= a.ActivityOn)
FROM dbo.ARWB_ClaimActivity a
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey
WHERE a.ActionType IN (N'Claim Assigned', N'Reassigned') AND a.ActivityOn >= @From AND a.ActivityOn < @To {scope};

-- Next follow-up logged by the scheduled date (+ grace); an unfollowed note on a claim closed since is not counted
INSERT INTO #sla
SELECT 'FOLLOWUP_ON_SCHEDULE', f.CreatedOn, DATEADD(day, @T_FOLLOWUP_ON_SCHEDULE + 1, CONVERT(datetime2(0), f.NextFollowUpDate)), n.NextOn
FROM dbo.ARWB_ClaimFollowUp f
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = f.ClaimKey
OUTER APPLY (SELECT MIN(x.CreatedOn) AS NextOn FROM dbo.ARWB_ClaimFollowUp x WHERE x.ClaimKey = f.ClaimKey AND x.IsSystem = 0 AND x.FollowUpId > f.FollowUpId) n
WHERE f.IsSystem = 0 AND f.NextFollowUpDate IS NOT NULL AND f.CreatedOn >= @From AND f.CreatedOn < @To
  AND (n.NextOn IS NOT NULL OR w.IsFinanciallyClosed = 0) {scope};

-- Submitted for QA -> decision
INSERT INTO #sla
SELECT 'QA_DECISION', q.SubmittedOn, DATEADD(day, @T_QA_DECISION, q.SubmittedOn), q.ReviewedOn
FROM dbo.ARWB_ClaimQaReview q
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = q.ClaimKey
WHERE q.SubmittedOn >= @From AND q.SubmittedOn < @To AND (q.ReviewedOn IS NOT NULL OR q.IsCurrent = 1) {scope};

-- CIP milestones from the case history: each start action -> the next ending action on the same case
INSERT INTO #sla
SELECT m.Milestone, h.ActionOn,
       DATEADD(day, CASE m.Milestone WHEN 'CIP_APPROVAL' THEN @T_CIP_APPROVAL WHEN 'CIP_CLIENT_RESPONSE' THEN @T_CIP_CLIENT_RESPONSE ELSE @T_CIP_RESPONSE_REVIEW END, h.ActionOn),
       (SELECT MIN(e.ActionOn) FROM dbo.ARWB_CipCaseHistory e
        WHERE e.CipCaseId = h.CipCaseId AND e.CipCaseHistoryId > h.CipCaseHistoryId
          AND e.ActionName IN (m.End1, m.End2))
FROM dbo.ARWB_CipCaseHistory h
INNER JOIN (VALUES
    ('CIP_APPROVAL',        N'QA Approved',                               N'Approved for Client',                   N'Rejected - Returned to Agent'),
    ('CIP_CLIENT_RESPONSE', N'Approved for Client',                       N'Client Responded',                      N'Client Responded'),
    ('CIP_CLIENT_RESPONSE', N'Response Insufficient - Re-sent to Client', N'Client Responded',                      N'Client Responded'),
    ('CIP_RESPONSE_REVIEW', N'Client Responded',                          N'Response Approved - Returned to Agent', N'Response Insufficient - Re-sent to Client')
) m (Milestone, StartAction, End1, End2) ON m.StartAction = h.ActionName
INNER JOIN dbo.ARWB_CipCase c ON c.CipCaseId = h.CipCaseId
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey
WHERE h.ActionOn >= @From AND h.ActionOn < @To {scope};

SELECT Milestone, COUNT(*),
       SUM(CASE WHEN EndOn IS NOT NULL AND EndOn <= DueOn THEN 1 ELSE 0 END),
       SUM(CASE WHEN EndOn > DueOn THEN 1 ELSE 0 END),
       SUM(CASE WHEN EndOn IS NULL AND @Now <= DueOn THEN 1 ELSE 0 END),
       SUM(CASE WHEN EndOn IS NULL AND @Now > DueOn THEN 1 ELSE 0 END),
       CONVERT(decimal(18,2), AVG(CASE WHEN EndOn IS NOT NULL THEN DATEDIFF(minute, StartOn, EndOn) / 1440.0 END))
FROM #sla
GROUP BY Milestone;

DROP TABLE #sla;";

        var found = new Dictionary<string, (int Total, int Met, int Breached, int OnTrack, int Overdue, decimal? AvgDays)>(StringComparer.OrdinalIgnoreCase);
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
                found[r.GetString(0)] = (IntOrZero(r, 1), IntOrZero(r, 2), IntOrZero(r, 3), IntOrZero(r, 4), IntOrZero(r, 5), r.IsDBNull(6) ? null : r.GetDecimal(6));
        }

        var report = new ArWorkbenchReport
        {
            Columns = [Col("milestone", "Milestone"), Col("target", "Target (days)", "count"), Col("instances", "Instances", "count"), Col("met", "Met", "count"),
                       Col("breached", "Breached", "count"), Col("onTrack", "Open – On Track", "count"), Col("overdue", "Open – Overdue", "count"),
                       Col("pctMet", "% Met", "pct"), Col("avgDays", "Avg Days to Complete", "decimal")]
        };
        foreach (var t in settings.Targets)
        {
            var f = found.GetValueOrDefault(t.Key);
            var measured = f.Met + f.Breached + f.Overdue;
            report.Rows.Add(ReportRow(t.Label, t.Days, f.Total, f.Met, f.Breached, f.OnTrack, f.Overdue, measured > 0 ? (object)Math.Round((decimal)f.Met / measured, 4) : null, f.AvgDays));
            if (f.Overdue > 0) report.Insights.Add($"{t.Label}: {f.Overdue:N0} open and past the {t.Days}-day target.");
        }
        if (report.Insights.Count == 0) report.Insights.Add("No open milestone is past its target.");
        report.Note = (settings.Confirmed ? string.Empty : "DRAFT TARGETS — not yet confirmed by the team; edit them under Master Values > Operational SLA Targets. ")
                      + "Instances are counted by the day they started (UTC). Days are calendar days. % Met = Met ÷ (Met + Breached + Open – Overdue). "
                      + "Targets apply as they are set today, to the whole period.";
        return report;
    }

    // ---- SLA target settings -----------------------------------------------------------------------

    public async Task<ArWorkbenchSlaSettings> GetSlaSettingsAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        return await ReadSlaSettingsAsync(connection, ct);
    }

    private static async Task<ArWorkbenchSlaSettings> ReadSlaSettingsAsync(SqlConnection? connection, CancellationToken ct)
    {
        var keys = ArWorkbenchReportRules.SlaMilestones.Select(m => m.SettingKey).Append(ArWorkbenchReportRules.SlaConfirmedSetting).ToList();
        await using var cmd = connection!.CreateCommand();
        cmd.CommandText = $"SELECT SettingKey, SettingValue, UpdatedOn, UpdatedBy FROM dbo.ARWB_AppSetting WHERE SettingKey IN ({string.Join(", ", keys.Select((_, i) => "@K" + i))});";
        for (var i = 0; i < keys.Count; i++) cmd.Parameters.Add("@K" + i, SqlDbType.VarChar, 100).Value = keys[i];

        var values = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        var settings = new ArWorkbenchSlaSettings();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                values[r.GetString(0)] = Str(r, 1);
                var on = r.IsDBNull(2) ? (DateTime?)null : r.GetDateTime(2);
                if (on is not null && (settings.UpdatedOn is null || on > settings.UpdatedOn))
                {
                    settings.UpdatedOn = on;
                    settings.UpdatedBy = Str(r, 3);
                }
            }
        }
        settings.Targets = ArWorkbenchReportRules.ParseSlaTargets(values);
        settings.Confirmed = values.GetValueOrDefault(ArWorkbenchReportRules.SlaConfirmedSetting) == "1";
        return settings;
    }

    /// <param name="values">ARWB_AppSetting key -> days, already validated (ArWorkbenchReportRules.ValidateSlaTargets).</param>
    public async Task<ArWorkbenchSaveResult> SaveSlaSettingsAsync(int labId, IReadOnlyDictionary<string, int> values, bool confirmed, string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var rows = values.Select(v => (Key: v.Key, Value: v.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)))
            .Append((Key: ArWorkbenchReportRules.SlaConfirmedSetting, Value: confirmed ? "1" : "0")).ToList();
        var source = new List<string>();
        for (var i = 0; i < rows.Count; i++)
        {
            source.Add($"(@K{i}, @V{i})");
            cmd.Parameters.Add("@K" + i, SqlDbType.VarChar, 100).Value = rows[i].Key;
            cmd.Parameters.Add("@V" + i, SqlDbType.NVarChar, 400).Value = rows[i].Value;
        }
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
        cmd.CommandText = $@"
MERGE dbo.ARWB_AppSetting AS t
USING (VALUES {string.Join(", ", source)}) AS s (SettingKey, SettingValue)
   ON t.SettingKey = s.SettingKey
WHEN MATCHED THEN UPDATE SET SettingValue = s.SettingValue, UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
WHEN NOT MATCHED THEN INSERT (SettingKey, SettingValue, UpdatedOn, UpdatedBy) VALUES (s.SettingKey, s.SettingValue, SYSUTCDATETIME(), @User);";
        await cmd.ExecuteNonQueryAsync(ct);
        return ArWorkbenchSaveResult.Ok(confirmed ? "SLA targets saved and marked as confirmed." : "SLA targets saved as drafts.");
    }
}
