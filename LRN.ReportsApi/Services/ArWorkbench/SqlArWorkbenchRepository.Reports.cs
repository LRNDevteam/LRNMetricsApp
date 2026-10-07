using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T073 / T074 Reports (mockup App.views.reports): the AR Collections Progress Summary and the
/// summary reports, each returned as one <see cref="ArWorkbenchReport"/> table. Every query carries
/// the caller's scope clause, like the Dashboard and Analytics.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    /// <param name="range">The date range for an event report (Action Completion, Operational SLA); ignored by the others.</param>
    /// <returns>Null for an unknown report id.</returns>
    public async Task<ArWorkbenchReport?> GetReportAsync(int labId, string reportId, ArWorkbenchReportRange range, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var info = ArWorkbenchReportRules.Catalog.FirstOrDefault(r => r.Id.Equals(reportId, StringComparison.OrdinalIgnoreCase));
        if (info is null) return null;

        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 180;
        var scope = AppendScope(cmd, user);

        var report = info.Id switch
        {
            ArWorkbenchReportRules.ArCollections => await ArCollectionsReportAsync(cmd, scope, ct),
            ArWorkbenchReportRules.DenialSummary => await DenialSummaryReportAsync(cmd, scope, ct),
            ArWorkbenchReportRules.PanelSummary => await PanelSummaryReportAsync(cmd, scope, ct),
            ArWorkbenchReportRules.AgingSummary => await AgingSummaryReportAsync(cmd, scope, ct),
            ArWorkbenchReportRules.RecoverySummary => await RecoverySummaryReportAsync(cmd, scope, ct),
            ArWorkbenchReportRules.RecoveryTrend => await RecoveryTrendReportAsync(cmd, scope, ct),
            ArWorkbenchReportRules.ActionCompletion => await ActionCompletionReportAsync(cmd, scope, range, ct),
            ArWorkbenchReportRules.OperationalSla => await OperationalSlaReportAsync(cmd, scope, range, ct),
            _ => await AgentProductivityReportAsync(cmd, scope, ct)
        };
        report.Id = info.Id;
        report.Title = info.Title;
        report.Description = info.Description;
        report.Code = info.Code;
        if (info.HasDateRange)
        {
            report.From = range.From;
            report.To = range.To;
        }

        // Every report says how fresh its data is (the trend is dated by its own snapshots).
        if (report.DataRefreshedOn is null)
        {
            cmd.Parameters.Clear();
            cmd.CommandText = "SELECT TOP (1) CompletedOn FROM dbo.ARWB_RefreshRun WHERE RunStatus = 'Succeeded' ORDER BY RefreshRunId DESC;";
            if (await cmd.ExecuteScalarAsync(ct) is DateTime refreshed) report.DataRefreshedOn = refreshed;
        }
        return report;
    }

    // ---- AR Collections Progress Summary (T074) -------------------------------------------------

    private static async Task<ArWorkbenchReport> ArCollectionsReportAsync(SqlCommand cmd, string scope, CancellationToken ct)
    {
        cmd.CommandText = $@"
SELECT ItemValue FROM dbo.ARWB_MasterListItem WHERE ListType = 'REVENUE_CONFIDENCE_TIER' AND IsActive = 1 ORDER BY SortOrder;

SELECT w.ArQueueId, t.QueueLabel, t.SortOrder, w.ArSubQueueId, s.QueueLabel, ISNULL(s.SortOrder, 0),
       COUNT(*), ISNULL(SUM(w.InitialInsuranceAR), 0),
       ISNULL(SUM(CASE WHEN w.RemainingAR > 0.005 THEN w.InitialInsuranceAR ELSE 0 END), 0),
       ISNULL(SUM(w.RecoveredAmount), 0)
FROM dbo.ARWB_Claim w
INNER JOIN dbo.ARWB_ArQueue t ON t.QueueId = w.ArQueueId
LEFT  JOIN dbo.ARWB_ArQueue s ON s.QueueId = w.ArSubQueueId
WHERE 1 = 1 {scope}
GROUP BY w.ArQueueId, t.QueueLabel, t.SortOrder, w.ArSubQueueId, s.QueueLabel, s.SortOrder;

SELECT SUM(CASE WHEN w.WorkedStatus = 'Worked' THEN 1 ELSE 0 END) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope};

SELECT TOP (1) CompletedOn, SourcePeriodStart, SourcePeriodEnd FROM dbo.ARWB_RefreshRun WHERE RunStatus = 'Succeeded' ORDER BY RefreshRunId DESC;";

        var tierValues = new List<string?>();
        var leaves = new List<ArWorkbenchQueueLeafTotals>();
        var worked = 0;
        DateTime? refreshed = null, periodStart = null, periodEnd = null;

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) tierValues.Add(Str(r, 0));
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct))
        {
            leaves.Add(new ArWorkbenchQueueLeafTotals
            {
                QueueId = r.GetString(0), QueueLabel = r.GetString(1), QueueSort = r.GetInt32(2),
                SubQueueId = Str(r, 3), SubQueueLabel = Str(r, 4), SubQueueSort = r.GetInt32(5),
                Count = IntOrZero(r, 6), InitialAR = DecOrZero(r, 7), InitialAROpen = DecOrZero(r, 8), Recovered = DecOrZero(r, 9)
            });
        }
        await r.NextResultAsync(ct);
        if (await r.ReadAsync(ct)) worked = IntOrZero(r, 0);
        await r.NextResultAsync(ct);
        if (await r.ReadAsync(ct))
        {
            refreshed = r.IsDBNull(0) ? null : r.GetDateTime(0);
            periodStart = r.IsDBNull(1) ? null : r.GetDateTime(1);
            periodEnd = r.IsDBNull(2) ? null : r.GetDateTime(2);
        }

        return ArWorkbenchReportRules.BuildArCollections(leaves, ArWorkbenchReportRules.ParseTiers(tierValues),
            new ArWorkbenchReportRules.CollectionsContext(worked, refreshed, periodStart, periodEnd));
    }

    // ---- Summary reports (T073) -----------------------------------------------------------------

    private static ArWorkbenchReportColumn Col(string key, string label, string format = "text") => new() { Key = key, Label = label, Format = format };
    private static ArWorkbenchReportRow ReportRow(params object?[] values) => new() { Values = values.ToList() };
    private static ArWorkbenchReportRow TotalRow(params object?[] values) => new() { IsTotal = true, Values = values.ToList() };
    private static decimal Share(decimal part, decimal whole) => whole > 0 ? Math.Round(part / whole, 4) : 0m;

    /// <summary>Denied claims (a primary denial code) by denial category: count, outstanding, recovered, share of outstanding.</summary>
    private static async Task<ArWorkbenchReport> DenialSummaryReportAsync(SqlCommand cmd, string scope, CancellationToken ct)
    {
        cmd.CommandText = $@"
SELECT ISNULL(NULLIF(LTRIM(RTRIM(w.DenialCategory)), N''), N'Other'), COUNT(*), ISNULL(SUM(w.RemainingAR), 0), ISNULL(SUM(w.RecoveredAmount), 0)
FROM dbo.ARWB_Claim w
WHERE w.HasDenial = 1 {scope}
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(w.DenialCategory)), N''), N'Other')
ORDER BY SUM(w.RemainingAR) DESC;";
        var rows = await ReadGroupsAsync(cmd, ct);
        var report = new ArWorkbenchReport
        {
            Columns = [Col("category", "Denial Category"), Col("claims", "Claims", "count"), Col("outstanding", "Outstanding", "money"), Col("recovered", "Recovered", "money"), Col("share", "% of Outstanding", "pct")],
            Note = "Claims with a primary denial code. A denied claim with no mapped category counts as Other."
        };
        var outstanding = rows.Sum(x => x.Outstanding);
        report.Rows.AddRange(rows.Select(x => ReportRow(x.Label, x.Count, x.Outstanding, x.Recovered, Share(x.Outstanding, outstanding))));
        report.Rows.Add(TotalRow("Total", rows.Sum(x => x.Count), outstanding, rows.Sum(x => x.Recovered), outstanding > 0 ? 1m : 0m));
        return report;
    }

    private static async Task<ArWorkbenchReport> PanelSummaryReportAsync(SqlCommand cmd, string scope, CancellationToken ct)
    {
        cmd.CommandText = $@"
SELECT ISNULL(NULLIF(LTRIM(RTRIM(w.PanelName)), N''), N'(No panel)'), COUNT(*), ISNULL(SUM(w.RemainingAR), 0), ISNULL(SUM(w.RecoveredAmount), 0)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope}
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(w.PanelName)), N''), N'(No panel)')
ORDER BY SUM(w.RemainingAR) DESC;";
        var rows = await ReadGroupsAsync(cmd, ct);
        var report = new ArWorkbenchReport
        {
            Columns = [Col("panel", "Panel Type"), Col("claims", "Claims", "count"), Col("outstanding", "Outstanding", "money"), Col("recovered", "Recovered", "money")]
        };
        report.Rows.AddRange(rows.Select(x => ReportRow(x.Label, x.Count, x.Outstanding, x.Recovered)));
        report.Rows.Add(TotalRow("Total", rows.Sum(x => x.Count), rows.Sum(x => x.Outstanding), rows.Sum(x => x.Recovered)));
        return report;
    }

    /// <summary>Every configured bucket (zero included) in master-data order, like the Dashboard.</summary>
    private static async Task<ArWorkbenchReport> AgingSummaryReportAsync(SqlCommand cmd, string scope, CancellationToken ct)
    {
        cmd.CommandText = $@"
SELECT ItemValue FROM dbo.ARWB_MasterListItem WHERE ListType = 'AGING_BUCKET' AND IsActive = 1 ORDER BY SortOrder;
SELECT ISNULL(w.AgingBucket, N'(Not aged)'), COUNT(*), ISNULL(SUM(w.RemainingAR), 0), ISNULL(SUM(w.RecoveredAmount), 0)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope}
GROUP BY ISNULL(w.AgingBucket, N'(Not aged)');";
        var order = new List<string>();
        var found = new Dictionary<string, (string Label, int Count, decimal Outstanding, decimal Recovered)>(StringComparer.OrdinalIgnoreCase);
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct)) order.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) found[r.GetString(0)] = (r.GetString(0), IntOrZero(r, 1), DecOrZero(r, 2), DecOrZero(r, 3));
        }
        List<(string Label, int Count, decimal Outstanding, decimal Recovered)> rows = order
            .Select(b => found.TryGetValue(b, out var hit) ? hit : (b, 0, 0m, 0m))
            .Concat(found.Values.Where(v => !order.Contains(v.Label, StringComparer.OrdinalIgnoreCase)))
            .ToList();
        var claims = rows.Sum(x => x.Count);
        var report = new ArWorkbenchReport
        {
            Columns = [Col("bucket", "Aging Bucket"), Col("claims", "Claims", "count"), Col("share", "% of Claims", "pct"), Col("outstanding", "Outstanding", "money")],
            Note = "Age of service, from the aging buckets in Master Values."
        };
        report.Rows.AddRange(rows.Select(x => ReportRow(x.Label, x.Count, Share(x.Count, claims), x.Outstanding)));
        report.Rows.Add(TotalRow("Total", claims, claims > 0 ? 1m : 0m, rows.Sum(x => x.Outstanding)));
        return report;
    }

    private static async Task<ArWorkbenchReport> RecoverySummaryReportAsync(SqlCommand cmd, string scope, CancellationToken ct)
    {
        cmd.CommandText = $@"
SELECT ISNULL(NULLIF(LTRIM(RTRIM(w.LabName)), N''), N'(No client)'), COUNT(*),
       ISNULL(SUM(w.InitialInsuranceAR), 0), ISNULL(SUM(w.RecoveredAmount), 0), ISNULL(SUM(w.RemainingAR), 0),
       ISNULL(SUM(CASE WHEN w.InitialInsuranceAR > 0 THEN w.RecoveredAmount ELSE 0 END), 0)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope}
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(w.LabName)), N''), N'(No client)')
ORDER BY SUM(w.RecoveredAmount) + SUM(w.RemainingAR) DESC;";
        var rows = new List<(string Label, int Count, decimal Initial, decimal Recovered, decimal Outstanding, decimal RateRecovered)>();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct)) rows.Add((r.GetString(0), IntOrZero(r, 1), DecOrZero(r, 2), DecOrZero(r, 3), DecOrZero(r, 4), DecOrZero(r, 5)));

        var report = new ArWorkbenchReport
        {
            Columns = [Col("client", "Client"), Col("claims", "Claims", "count"), Col("initial", "Initial Insurance AR", "money"), Col("recovered", "Recovered", "money"), Col("outstanding", "Outstanding", "money"), Col("rate", "Recovery Rate", "pct")],
            Note = "Recovery Rate = Recovered ÷ Initial Insurance AR, over claims with a non-zero initial balance."
        };
        report.Rows.AddRange(rows.Select(x => ReportRow(x.Label, x.Count, x.Initial, x.Recovered, x.Outstanding, ArWorkbenchAnalyticsRules.RecoveryRate(x.RateRecovered, x.Initial))));
        report.Rows.Add(TotalRow("Total", rows.Sum(x => x.Count), rows.Sum(x => x.Initial), rows.Sum(x => x.Recovered), rows.Sum(x => x.Outstanding),
            ArWorkbenchAnalyticsRules.RecoveryRate(rows.Sum(x => x.RateRecovered), rows.Sum(x => x.Initial))));
        return report;
    }

    /// <summary>
    /// The last 30 nightly snapshots (T038), newest first. Scope reads the claim's current clinic /
    /// provider / agent, so a scoped user's history follows the claims they hold today.
    /// </summary>
    private static async Task<ArWorkbenchReport> RecoveryTrendReportAsync(SqlCommand cmd, string scope, CancellationToken ct)
    {
        cmd.CommandText = $@"
SELECT s.SnapshotDate, COUNT(*), ISNULL(SUM(s.RemainingAR), 0), ISNULL(SUM(s.RecoveredAmount), 0),
       SUM(CASE WHEN s.WorkflowStatus = 'Unassigned' AND s.InsuranceBalance > 0 THEN 1 ELSE 0 END)
FROM dbo.ARWB_QueueSnapshot s
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = s.ClaimKey
WHERE s.SnapshotDate IN (SELECT TOP (30) d.SnapshotDate FROM dbo.ARWB_QueueSnapshot d GROUP BY d.SnapshotDate ORDER BY d.SnapshotDate DESC) {scope}
GROUP BY s.SnapshotDate
ORDER BY s.SnapshotDate DESC;";
        var points = new List<(DateTime Date, int Count, decimal Remaining, decimal Recovered, int Unassigned)>();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct)) points.Add((r.GetDateTime(0), IntOrZero(r, 1), DecOrZero(r, 2), DecOrZero(r, 3), IntOrZero(r, 4)));

        var report = new ArWorkbenchReport
        {
            Columns = [Col("date", "Snapshot Date", "date"), Col("claims", "Claims", "count"), Col("remaining", "Outstanding AR", "money"),
                       Col("recovered", "Recovered to Date", "money"), Col("delta", "Recovered Since Previous", "money"), Col("unassigned", "Unassigned (Open)", "count")],
            Note = points.Count == 0
                ? "No nightly snapshots yet. They are taken every night, or with Take snapshot now on Data Processing."
                : "One row per nightly queue snapshot (last 30). Recovered Since Previous is the change from the snapshot before it.",
            DataRefreshedOn = points.Count > 0 ? points[0].Date : null
        };
        for (var i = 0; i < points.Count; i++)
        {
            var p = points[i];
            decimal? delta = i + 1 < points.Count ? p.Recovered - points[i + 1].Recovered : null;
            report.Rows.Add(ReportRow(p.Date, p.Count, p.Remaining, p.Recovered, delta, p.Unassigned));
        }
        return report;
    }

    private async Task<ArWorkbenchReport> AgentProductivityReportAsync(SqlCommand cmd, string scope, CancellationToken ct)
    {
        cmd.Parameters.Add("@Since", SqlDbType.DateTime2).Value = DateTime.UtcNow.Date.AddDays(-30);
        cmd.CommandText = $@"
SELECT w.AssignedAgentUser, COUNT(*),
       SUM(CASE WHEN w.IsWorkComplete = 1 THEN 1 ELSE 0 END),
       SUM(CASE WHEN w.WorkflowStatus = 'Submitted for QA' THEN 1 ELSE 0 END),
       SUM(CASE WHEN w.WorkflowStatus = 'QA Rejected' THEN 1 ELSE 0 END),
       ISNULL(SUM(w.RemainingAR), 0), ISNULL(SUM(w.RecoveredAmount), 0)
FROM dbo.ARWB_Claim w
WHERE NULLIF(w.AssignedAgentUser, N'') IS NOT NULL {scope}
GROUP BY w.AssignedAgentUser;

SELECT f.CreatedBy, COUNT(*)
FROM dbo.ARWB_ClaimFollowUp f
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = f.ClaimKey
WHERE f.IsSystem = 0 AND f.CreatedOn >= @Since {scope}
GROUP BY f.CreatedBy;";

        var agents = new Dictionary<string, (int Assigned, int Completed, int AwaitingQa, int Rejected, decimal Outstanding, decimal Recovered, int Notes)>(StringComparer.OrdinalIgnoreCase);
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
                agents[r.GetString(0)] = (IntOrZero(r, 1), IntOrZero(r, 2), IntOrZero(r, 3), IntOrZero(r, 4), DecOrZero(r, 5), DecOrZero(r, 6), 0);
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var name = r.GetString(0);
                var a = agents.GetValueOrDefault(name);
                agents[name] = a with { Notes = IntOrZero(r, 1) };
            }
        }
        var names = await GetDisplayNamesAsync(agents.Keys, ct);

        var report = new ArWorkbenchReport
        {
            Columns = [Col("agent", "Agent"), Col("assigned", "Assigned", "count"), Col("completed", "Completed", "count"), Col("awaitingQa", "Awaiting QA", "count"),
                       Col("qaRejected", "QA Rejected", "count"), Col("notes", "Notes Logged (30 days)", "count"), Col("outstanding", "Outstanding", "money"), Col("recovery", "Recovery $", "money")],
            Note = "Current portfolio by assigned agent. Notes Logged counts follow-up notes the person wrote in the last 30 days, so a lead or QA reviewer who logs notes appears too."
        };
        var ordered = agents.OrderByDescending(a => a.Value.Recovered).ThenBy(a => a.Key, StringComparer.OrdinalIgnoreCase).ToList();
        report.Rows.AddRange(ordered.Select(a => ReportRow(
            names.TryGetValue(a.Key, out var dn) ? $"{dn} ({a.Key})" : a.Key,
            a.Value.Assigned, a.Value.Completed, a.Value.AwaitingQa, a.Value.Rejected, a.Value.Notes, a.Value.Outstanding, a.Value.Recovered)));
        var v = ordered.Select(a => a.Value).ToList();
        report.Rows.Add(TotalRow("Total", v.Sum(x => x.Assigned), v.Sum(x => x.Completed), v.Sum(x => x.AwaitingQa), v.Sum(x => x.Rejected), v.Sum(x => x.Notes), v.Sum(x => x.Outstanding), v.Sum(x => x.Recovered)));
        return report;
    }

    private static async Task<List<(string Label, int Count, decimal Outstanding, decimal Recovered)>> ReadGroupsAsync(SqlCommand cmd, CancellationToken ct)
    {
        var rows = new List<(string Label, int Count, decimal Outstanding, decimal Recovered)>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) rows.Add((r.GetString(0), IntOrZero(r, 1), DecOrZero(r, 2), DecOrZero(r, 3)));
        return rows;
    }
}
