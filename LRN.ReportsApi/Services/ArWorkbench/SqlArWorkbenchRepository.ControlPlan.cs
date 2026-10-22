using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Dashboard Control Plan (handoff FR-DASH-02, retest DEF-23): for each denial classification and each
/// action / task bucket, the claims and outstanding balance split into Open (unassigned), In Progress
/// (with an agent) and Closed (financially closed or work completed). Action / Task is the last
/// follow-up's fix / resolution (decision 10/21/2026). Plus the Appeal Success Rate (FR-DASH-03).
/// Every result set carries the caller's scope.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const string ControlPlanBucketSql = @"
CROSS APPLY (SELECT Bucket = CASE WHEN w.IsFinanciallyClosed = 1 OR w.WorkflowStatus = 'Completed' THEN 2
                                  WHEN w.AssignedAgentUser IS NOT NULL THEN 1 ELSE 0 END) b";

    private const string ControlPlanSums = @"
       SUM(CASE WHEN b.Bucket = 0 THEN 1 ELSE 0 END), ISNULL(SUM(CASE WHEN b.Bucket = 0 THEN w.RemainingAR END), 0),
       SUM(CASE WHEN b.Bucket = 1 THEN 1 ELSE 0 END), ISNULL(SUM(CASE WHEN b.Bucket = 1 THEN w.RemainingAR END), 0),
       SUM(CASE WHEN b.Bucket = 2 THEN 1 ELSE 0 END), ISNULL(SUM(CASE WHEN b.Bucket = 2 THEN w.RemainingAR END), 0)";

    public async Task<ArWorkbenchControlPlan> GetControlPlanAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var internalView = !ArWorkbenchClientVisibility.IsClientUser(user);
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 180;
        var scope = AppendScope(cmd, user) + RestrictedQueueScope(user);

        cmd.CommandText = $@"
-- 0. by primary denial code (mapped to its classification below); NULL = no denial
SELECT w.PrimaryDenialCode, {ControlPlanSums}
FROM dbo.ARWB_Claim w {ControlPlanBucketSql}
WHERE 1 = 1 {scope}
GROUP BY w.PrimaryDenialCode;

-- 1. by action / task (last follow-up's fix / resolution); internal only
SELECT NULLIF(LTRIM(RTRIM(w.FixResolution)), N''), {ControlPlanSums}
FROM dbo.ARWB_Claim w {ControlPlanBucketSql}
WHERE {(internalView ? "1 = 1" : "1 = 0")} {scope}
GROUP BY NULLIF(LTRIM(RTRIM(w.FixResolution)), N'');

-- 2. appeals: first appeal note per claim; won = an insurance payment dated on / after it
SELECT COUNT(*),
       ISNULL(SUM(CASE WHEN p.Paid = 1 OR w.IsFinanciallyClosed = 1 THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN p.Paid = 1 THEN 1 ELSE 0 END), 0)
FROM (SELECT f.ClaimKey, FirstAppeal = CONVERT(date, MIN(f.CreatedOn))
      FROM dbo.ARWB_ClaimFollowUp f
      WHERE f.IsSystem = 0 AND f.FixResolution LIKE N'%Appeal%'
      GROUP BY f.ClaimKey) a
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey
CROSS APPLY (SELECT Paid = CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_ClaimLine l
                                             WHERE l.ClaimKey = a.ClaimKey AND l.InsurancePayment > 0
                                               AND COALESCE(l.CheckDate, l.PostingDate) >= a.FirstAppeal) THEN 1 ELSE 0 END) p
WHERE {(internalView ? "1 = 1" : "1 = 0")} {scope};";

        var byCode = new List<(string? Code, ArWorkbenchControlPlanRow Row)>();
        var plan = new ArWorkbenchControlPlan();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            ArWorkbenchControlPlanRow Read(string label, string? key) => new()
            {
                Label = label, Key = key,
                OpenCount = IntOrZero(r, 1), OpenAmount = DecOrZero(r, 2),
                InProgressCount = IntOrZero(r, 3), InProgressAmount = DecOrZero(r, 4),
                ClosedCount = IntOrZero(r, 5), ClosedAmount = DecOrZero(r, 6)
            };

            while (await r.ReadAsync(ct)) byCode.Add((Str(r, 0), Read("", null)));

            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var fix = Str(r, 0);
                plan.ByAction.Add(Read(fix ?? "(No action yet)", fix ?? ArWorkbenchFilterValues.None));
            }

            await r.NextResultAsync(ct);
            if (internalView && await r.ReadAsync(ct))
            {
                var a = new ArWorkbenchAppealSummary { Appealed = IntOrZero(r, 0), Decided = IntOrZero(r, 1), Won = IntOrZero(r, 2) };
                a.SuccessRate = a.Decided > 0 ? Math.Round((decimal)a.Won / a.Decided, 4) : null;
                plan.Appeals = a;
            }
        }

        var classOf = await GetPrimaryClassificationsAsync(ct);
        plan.ByClassification = ArWorkbenchControlPlanRules.ByClassification(byCode, classOf);
        plan.ByAction = plan.ByAction.OrderByDescending(x => x.OpenCount + x.InProgressCount + x.ClosedCount).ThenBy(x => x.Label, StringComparer.OrdinalIgnoreCase).ToList();
        return plan;
    }

    /// <summary>
    /// One classification per normalized code: the central Denial Code Master's, else the Denial Mapper Super
    /// Master's (alphabetically first when it has several CPT-specific rows). Empty when LRNMaster is unreachable.
    /// </summary>
    private async Task<Dictionary<string, string>> GetPrimaryClassificationsAsync(CancellationToken ct)
    {
        var central = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var mapper = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            await using var master = new SqlConnection(_masterConnectionString);
            await master.OpenAsync(ct);
            await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.ARWB_DenialCodeMaster', N'U') IS NOT NULL
    SELECT DenialCode, DenialClassification FROM dbo.ARWB_DenialCodeMaster
    WHERE IsActive = 1 AND NULLIF(LTRIM(RTRIM(DenialClassification)), N'') IS NOT NULL;
ELSE SELECT CAST(NULL AS nvarchar(50)), CAST(NULL AS nvarchar(100)) WHERE 1 = 0;
IF OBJECT_ID(N'dbo.DenialMapperSuperMaster', N'U') IS NOT NULL
    SELECT DenialCode, DenialClassification FROM dbo.DenialMapperSuperMaster
    WHERE IsActive = 1 AND NULLIF(LTRIM(RTRIM(DenialClassification)), N'') IS NOT NULL;", master) { CommandTimeout = 60 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            foreach (var target in new[] { central, mapper })
            {
                while (await r.ReadAsync(ct))
                {
                    var code = ArWorkbenchMasterRules.NormalizeDenialCode(r.IsDBNull(0) ? null : r.GetString(0));
                    var cls = r.IsDBNull(1) ? null : r.GetString(1).Trim();
                    if (code is null || string.IsNullOrEmpty(cls)) continue;
                    if (!target.TryGetValue(code, out var have) || string.Compare(cls, have, StringComparison.OrdinalIgnoreCase) < 0) target[code] = cls;
                }
                if (!await r.NextResultAsync(ct)) break;
            }
        }
        catch (SqlException)
        {
            // LRNMaster unreachable: every denied claim shows as unclassified.
        }
        foreach (var (code, cls) in mapper) central.TryAdd(code, cls);
        return central;
    }
}

/// <summary>Grouping rules of the Control Plan, free of SQL so they can be unit-tested.</summary>
public static class ArWorkbenchControlPlanRules
{
    public const string NoDenial = "(No denial)";
    public const string Unclassified = "(Unclassified)";

    public static List<ArWorkbenchControlPlanRow> ByClassification(IEnumerable<(string? Code, ArWorkbenchControlPlanRow Row)> byCode, IReadOnlyDictionary<string, string> classOf)
    {
        var rows = new Dictionary<string, ArWorkbenchControlPlanRow>(StringComparer.OrdinalIgnoreCase);
        foreach (var (code, row) in byCode)
        {
            var label = code is null ? NoDenial : classOf.TryGetValue(code, out var cls) ? cls : Unclassified;
            if (!rows.TryGetValue(label, out var total)) rows[label] = total = new ArWorkbenchControlPlanRow { Label = label };
            total.OpenCount += row.OpenCount; total.OpenAmount += row.OpenAmount;
            total.InProgressCount += row.InProgressCount; total.InProgressAmount += row.InProgressAmount;
            total.ClosedCount += row.ClosedCount; total.ClosedAmount += row.ClosedAmount;
        }
        // Classified rows by size; "(Unclassified)" and "(No denial)" last.
        return rows.Values
            .OrderBy(x => x.Label == NoDenial ? 2 : x.Label == Unclassified ? 1 : 0)
            .ThenByDescending(x => x.OpenCount + x.InProgressCount + x.ClosedCount)
            .ThenBy(x => x.Label, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>
    /// The SLA attainment tile from the Operational SLA report (RPT-09) rows - milestone, target, instances,
    /// met, breached, open on track, open overdue, ...: Met ÷ (Met + Breached + Open – Overdue), as the report.
    /// </summary>
    public static ArWorkbenchSlaSummary SlaSummary(ArWorkbenchReport report, int days, bool confirmed)
    {
        static int I(object? v) => v is null ? 0 : Convert.ToInt32(v);
        var summary = new ArWorkbenchSlaSummary { Days = days, TargetsConfirmed = confirmed };
        int met = 0, measured = 0;
        foreach (var row in report.Rows)
        {
            var m = I(row.Values[3]);
            var n = m + I(row.Values[4]) + I(row.Values[6]);
            met += m;
            measured += n;
            summary.Milestones.Add(new ArWorkbenchSlaMilestoneSummary
            {
                Label = row.Values[0]?.ToString() ?? string.Empty,
                Measured = n,
                AttainmentPct = n > 0 ? Math.Round((decimal)m / n, 4) : null
            });
        }
        summary.Measured = measured;
        summary.AttainmentPct = measured > 0 ? Math.Round((decimal)met / measured, 4) : null;
        return summary;
    }
}
