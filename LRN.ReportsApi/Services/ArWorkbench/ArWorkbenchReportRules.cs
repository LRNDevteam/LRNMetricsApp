using System.Globalization;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// The pure parts of the Reports screen (T073 / T074): the report catalog, the revenue confidence
/// tiers and the AR Collections Progress Summary rollup with its narrative insights (the mockup's
/// App.buildArProgressSummary). The SQL only sums per AR Queue leaf.
/// </summary>
public static class ArWorkbenchReportRules
{
    public const string ArCollections = "ar-collections";
    public const string DenialSummary = "denial-summary";
    public const string PanelSummary = "panel-summary";
    public const string AgingSummary = "aging-summary";
    public const string RecoverySummary = "recovery-summary";
    public const string RecoveryTrend = "recovery-trend";
    public const string AgentProductivity = "agent-productivity";
    public const string ActionCompletion = "action-completion";
    public const string OperationalSla = "operational-sla";

    /// <summary>Reports a client (viewer) user cannot open: they name the AR team's people and internal work.</summary>
    public static readonly IReadOnlySet<string> InternalOnly = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { AgentProductivity, ActionCompletion, OperationalSla };

    /// <summary>Longest range an event report accepts.</summary>
    public const int MaxRangeDays = 366;
    public const int DefaultRangeDays = 30;

    /// <summary>
    /// The from / to an event report runs over: both given -> as given; one missing -> the last
    /// 30 days ending today (or ending at To). Returns an error for a reversed or over-long range.
    /// </summary>
    public static (ArWorkbenchReportRange? Range, string? Error) ResolveRange(DateTime? from, DateTime? to, DateTime today)
    {
        var end = (to ?? today).Date;
        var start = (from ?? end.AddDays(-(DefaultRangeDays - 1))).Date;
        if (start > end) return (null, "From must be on or before To.");
        if ((end - start).TotalDays >= MaxRangeDays) return (null, $"The date range can be at most {MaxRangeDays} days.");
        return (new ArWorkbenchReportRange { From = start, To = end }, null);
    }

    // ---- RPT-01..09 (Denial Workflow AR Reporting Requirements) re-pointed at the ARWB tables ----

    public static readonly IReadOnlyList<ArWorkbenchRptEntry> RptCatalog =
    [
        new() { Code = "RPT-01", Name = "AR Follow-up Activity Detail", Route = "/audit", NavId = "audit", Source = "Audit Logs over ARWB_ClaimActivity: every follow-up, assignment, QA, CIP and adjustment event, filterable and exportable." },
        new() { Code = "RPT-02", Name = "AR Analyst Productivity Summary", ReportId = AgentProductivity, Source = "Agent Productivity Summary: current portfolio plus follow-up notes logged." },
        new() { Code = "RPT-03", Name = "AR Analyst Workload and Capacity", Route = "/assignment", NavId = "assignment", Source = "Assignment Management: Agent Workload chart and Assigned Claims." },
        new() { Code = "RPT-04", Name = "Action Completion", ReportId = ActionCompletion, Source = "Action Completion: follow-up actions with their QA verification, and adjustment events." },
        new() { Code = "RPT-05", Name = "Follow-up Due and Compliance", Route = "/follow-up", NavId = "followup", Source = "Follow-Up Management (due / overdue now); on-time history in Operational SLA." },
        new() { Code = "RPT-06", Name = "Denial Work Progress by Classification/Action", ReportId = RecoveryTrend, Source = "Recovery Trend over the nightly queue snapshots, with AR Collections Progress for the queue breakdown." },
        new() { Code = "RPT-07", Name = "Escalation Response and Rework", ReportId = OperationalSla, Source = "Operational SLA CIP milestones (approval, client response, response review); cases on CIP Escalations." },
        new() { Code = "RPT-08", Name = "Closure and Outcome", ReportId = ArCollections, Source = "AR Collections Progress (Closed / Completed queues, payments posted) and Recovery Performance." },
        new() { Code = "RPT-09", Name = "Operational SLA", ReportId = OperationalSla, Source = "Operational SLA: each milestone against its target from Master Values > Operational SLA Targets." }
    ];

    // ---- Operational SLA milestones (RPT-09) -----------------------------------------------------

    /// <summary>Milestone key, ARWB_AppSetting key, label, description, draft target days.</summary>
    public static readonly IReadOnlyList<(string Key, string SettingKey, string Label, string Description, int DefaultDays)> SlaMilestones =
    [
        ("ASSIGN_FIRST_FOLLOWUP", "SlaFirstFollowUpDays", "Assignment → first follow-up", "From a claim being assigned (or reassigned) to the first follow-up note logged on it.", 3),
        ("FOLLOWUP_ON_SCHEDULE", "SlaFollowUpGraceDays", "Follow-up done by the scheduled date", "Days of grace after a note's Next Follow-Up Date for the next note to be logged. Claims closed since are left out.", 0),
        ("QA_DECISION", "SlaQaDecisionDays", "Submitted for QA → QA decision", "From a follow-up note reaching the QA Verification Queue to it being approved or rejected.", 2),
        ("CIP_APPROVAL", "SlaCipApprovalDays", "CIP pending approval → decision", "From QA approving a CIP note to the escalation being sent to the client or returned to the agent.", 2),
        ("CIP_CLIENT_RESPONSE", "SlaClientResponseDays", "CIP sent to client → client response", "From the escalation being sent (or re-sent) to the client to the client responding.", 7),
        ("CIP_RESPONSE_REVIEW", "SlaCipResponseReviewDays", "Client response → review", "From the client responding to the response being accepted or sent back as insufficient.", 2)
    ];

    public const string SlaConfirmedSetting = "SlaTargetsConfirmed";
    public const int MaxSlaDays = 365;

    /// <summary>Targets from ARWB_AppSetting values; a missing or invalid value falls back to the draft default.</summary>
    public static List<ArWorkbenchSlaTarget> ParseSlaTargets(IReadOnlyDictionary<string, string?> settings)
        => SlaMilestones.Select(m => new ArWorkbenchSlaTarget
        {
            Key = m.Key,
            Label = m.Label,
            Description = m.Description,
            Days = settings.TryGetValue(m.SettingKey, out var v) && int.TryParse(v, out var d) && d is >= 0 and <= MaxSlaDays ? d : m.DefaultDays
        }).ToList();

    /// <summary>Validates a save: every milestone present once, each 0..365 days. Returns setting key -> days.</summary>
    public static (Dictionary<string, int>? Values, string? Error) ValidateSlaTargets(IReadOnlyDictionary<string, int>? targets)
    {
        if (targets is null) return (null, "Targets are required.");
        var byKey = new Dictionary<string, int>(targets, StringComparer.OrdinalIgnoreCase);
        var values = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var m in SlaMilestones)
        {
            if (!byKey.TryGetValue(m.Key, out var days)) return (null, $"A target is required for \"{m.Label}\".");
            if (days is < 0 or > MaxSlaDays) return (null, $"\"{m.Label}\" must be a whole number from 0 to {MaxSlaDays} days.");
            values[m.SettingKey] = days;
        }
        var unknown = byKey.Keys.FirstOrDefault(k => SlaMilestones.All(m => !m.Key.Equals(k, StringComparison.OrdinalIgnoreCase)));
        return unknown is null ? (values, null) : (null, $"Unknown SLA milestone \"{unknown}\".");
    }

    public static readonly IReadOnlyList<ArWorkbenchReportInfo> Catalog =
    [
        new() { Id = ArCollections, Title = "AR Collections Progress Summary", Featured = true,
                Description = "The weekly progress summary previously built by hand for client updates, computed live: AR Queue / sub-queue rollup, confidence-tiered revenue expectation, revenue yet to be collected and payments posted." },
        new() { Id = DenialSummary, Title = "Denial Analysis Summary", Description = "Claim counts, outstanding balance and recovery by denial category." },
        new() { Id = PanelSummary, Title = "Panel Type Summary", Description = "Claim counts, outstanding balance and recovery by panel type." },
        new() { Id = AgingSummary, Title = "AR Aging Summary", Description = "Claim counts and outstanding balance by aging bucket." },
        new() { Id = RecoverySummary, Title = "Recovery Performance Summary", Description = "Initial insurance AR, recovered and outstanding by client, with the recovery rate." },
        new() { Id = RecoveryTrend, Title = "Recovery Trend", Code = "RPT-06", Description = "Outstanding and recovered AR over time, from the nightly queue snapshots." },
        new() { Id = AgentProductivity, Title = "Agent Productivity Summary", Code = "RPT-02", Description = "Assigned, completed, awaiting review, follow-up notes logged and recovery $ by agent." },
        new() { Id = ActionCompletion, Title = "Action Completion", Code = "RPT-04", HasDateRange = true,
                Description = "Every completed follow-up action (appeal, resubmission, write-off, payer follow-up ...) with who did it, when, and its QA verification, plus automatic adjustments and postings." },
        new() { Id = OperationalSla, Title = "Operational SLA", Code = "RPT-09", HasDateRange = true,
                Description = "Each workflow milestone against its target: met, breached, open on track and open overdue, with the average days taken." }
    ];

    public static readonly decimal[] DefaultTiers = [1m, 0.5m, 0.3m];

    /// <summary>
    /// REVENUE_CONFIDENCE_TIER master values ("100", "50", "30") as fractions, in master order.
    /// Blank, non-numeric, out-of-range and duplicate values are skipped; none left -> 100 / 50 / 30.
    /// </summary>
    public static decimal[] ParseTiers(IEnumerable<string?> values)
    {
        var tiers = new List<decimal>();
        foreach (var v in values)
        {
            if (!decimal.TryParse((v ?? string.Empty).Trim().TrimEnd('%'), NumberStyles.Number, CultureInfo.InvariantCulture, out var pct)) continue;
            if (pct <= 0 || pct > 100) continue;
            var tier = pct / 100m;
            if (!tiers.Contains(tier)) tiers.Add(tier);
            if (tiers.Count == 5) break;
        }
        return tiers.Count == 0 ? DefaultTiers : tiers.ToArray();
    }

    public static string TierLabel(decimal tier) => $"{(tier * 100m).ToString("0.##", CultureInfo.InvariantCulture)}%";

    private sealed class Totals(int tierCount)
    {
        public int Count;
        public readonly decimal[] Exp = new decimal[tierCount];
        public readonly decimal[] Yet = new decimal[tierCount];
        public decimal Posted;

        public void Add(ArWorkbenchQueueLeafTotals leaf, decimal[] tiers)
        {
            Count += leaf.Count;
            for (var i = 0; i < tiers.Length; i++)
            {
                Exp[i] += leaf.InitialAR * tiers[i];
                Yet[i] += leaf.InitialAROpen * tiers[i];
            }
            Posted += leaf.Recovered;
        }
    }

    /// <summary>Facts the insights quote that are not in the leaf totals.</summary>
    public sealed record CollectionsContext(int WorkedClaims, DateTime? RefreshedOn, DateTime? SourcePeriodStart, DateTime? SourcePeriodEnd);

    /// <summary>
    /// The AR Collections Progress Summary: one bold row per top-level AR queue (in queue order),
    /// its sub-queues indented under it (largest first), then the Grand Total. Revenue expectation is
    /// initial insurance AR x each tier; yet to be collected is the same, only for claims still owed
    /// by insurance; payments posted is the recovered amount to date.
    /// </summary>
    public static ArWorkbenchReport BuildArCollections(IReadOnlyList<ArWorkbenchQueueLeafTotals> leaves, decimal[] tiers, CollectionsContext context)
    {
        var report = new ArWorkbenchReport
        {
            Id = ArCollections,
            Title = "AR Collections Progress Summary",
            Description = Catalog[0].Description,
            DataRefreshedOn = context.RefreshedOn,
            Note = "Revenue Expectation is each claim's original insurance balance at intake, shown at each collectibility confidence tier. " +
                   "Revenue Yet to be Collected counts only claims insurance still owes (remaining AR above zero); closed and fully paid claims show $0 there by design. " +
                   "Payments Posted is the cumulative recovered amount to date."
        };
        report.Columns.Add(new() { Key = "category", Label = "Follow Up Category | Status" });
        report.Columns.Add(new() { Key = "count", Label = "Count", Format = "count" });
        foreach (var t in tiers) report.Columns.Add(new() { Key = $"exp{TierLabel(t).TrimEnd('%')}", Label = $"Rev. Exp. ({TierLabel(t)})", Format = "money" });
        foreach (var t in tiers) report.Columns.Add(new() { Key = $"yet{TierLabel(t).TrimEnd('%')}", Label = $"Yet to Collect ({TierLabel(t)})", Format = "money" });
        report.Columns.Add(new() { Key = "posted", Label = "Payments Posted", Format = "money" });

        ArWorkbenchReportRow Row(string label, Totals t, int level, bool total)
        {
            var values = new List<object?> { label, t.Count };
            values.AddRange(t.Exp.Cast<object?>());
            values.AddRange(t.Yet.Cast<object?>());
            values.Add(t.Posted);
            return new ArWorkbenchReportRow { Level = level, IsTotal = total, Values = values };
        }

        var grand = new Totals(tiers.Length);
        var categories = new List<(string Id, string Label, Totals Totals, List<(string? SubId, string Label, Totals Totals)> Subs)>();
        foreach (var top in leaves.GroupBy(l => l.QueueId, StringComparer.OrdinalIgnoreCase).OrderBy(g => g.Min(l => l.QueueSort)))
        {
            var totals = new Totals(tiers.Length);
            var subs = new List<(string? SubId, string Label, Totals Totals)>();
            foreach (var sub in top.GroupBy(l => l.SubQueueId ?? string.Empty, StringComparer.OrdinalIgnoreCase))
            {
                var subTotals = new Totals(tiers.Length);
                foreach (var leaf in sub)
                {
                    subTotals.Add(leaf, tiers);
                    totals.Add(leaf, tiers);
                    grand.Add(leaf, tiers);
                }
                var first = sub.First();
                subs.Add((first.SubQueueId, first.SubQueueLabel ?? first.QueueLabel, subTotals));
            }
            if (totals.Count == 0) continue;
            categories.Add((top.Key, top.First().QueueLabel, totals, subs.OrderByDescending(s => s.Totals.Count).ThenBy(s => s.Label).ToList()));
        }

        foreach (var c in categories)
        {
            report.Rows.Add(Row(c.Label, c.Totals, 0, true));
            // A queue with no sub-queues would only repeat its own total.
            if (c.Subs.Count == 1 && c.Subs[0].SubId is null) continue;
            foreach (var s in c.Subs) report.Rows.Add(Row(s.Label, s.Totals, 1, false));
        }
        report.Rows.Add(Row("Grand Total", grand, 0, true));

        // Narrative, in the voice of the hand-built sheet.
        var total = grand.Count;
        var asOf = context.RefreshedOn is { } r ? $"As of {Date(r)}, " : string.Empty;
        var span = context.SourcePeriodStart is { } s0 && context.SourcePeriodEnd is { } s1 ? $", spanning DOS {Date(s0)} through {Date(s1)}" : string.Empty;
        report.Insights.Add($"{asOf}{Count(total)} claims are in scope for follow-up{span}.");
        report.Insights.Add($"Of that, {Count(context.WorkedClaims)} claims have been worked, and {Count(Math.Max(0, total - context.WorkedClaims))} are still pending initial follow-up.");

        var closed = categories.FirstOrDefault(c => c.Id.Equals("closed", StringComparison.OrdinalIgnoreCase));
        if (closed.Totals is not null)
            report.Insights.Add($"{Count(closed.Totals.Count)} claims sit in the {closed.Label} queue (fully paid or fully adjusted, no insurance or patient balance remaining), with {Money(closed.Totals.Posted)} collected against {Money(closed.Totals.Exp[0])} originally identified — a {Pct(closed.Totals.Posted, closed.Totals.Exp[0])} paid rate.");

        var nonResponded = categories.FirstOrDefault(c => c.Id.Equals("nonresponded", StringComparison.OrdinalIgnoreCase));
        if (nonResponded.Totals is not null)
            report.Insights.Add($"{Count(nonResponded.Totals.Count)} claims are fully open with no payment, adjustment or denial response yet, worth {Money(nonResponded.Totals.Exp[0])} in the {nonResponded.Label} queue.");

        var denied = categories.FirstOrDefault(c => c.Id.Equals("denied", StringComparison.OrdinalIgnoreCase));
        if (denied.Totals is not null)
        {
            var nc = denied.Subs.FirstOrDefault(x => string.Equals(x.SubId, "denied_noncollectible", StringComparison.OrdinalIgnoreCase));
            var ncText = nc.Totals is { Count: > 0 } ? $" — {Count(nc.Totals.Count)} of those are Non-Collectible denials per the denial-code master list and need no agent touch" : string.Empty;
            report.Insights.Add($"{Count(denied.Totals.Count)} claims are in the {denied.Label} queue, worth {Money(denied.Totals.Exp[0])}{ncText}.");
        }

        report.Insights.Add($"Across all {Count(total)} claims, total revenue expectation stands at {Money(grand.Exp[0])}, with {Money(grand.Posted)} collected so far — an overall {Pct(grand.Posted, grand.Exp[0])} realization rate.");
        return report;
    }

    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");
    private static string Money(decimal v) => v.ToString("C2", Us);
    private static string Count(int v) => v.ToString("N0", Us);
    private static string Date(DateTime d) => d.ToString("MMM dd, yyyy", Us);
    private static string Pct(decimal part, decimal whole) => whole > 0 ? (part / whole).ToString("P0", Us) : "0%";
}
