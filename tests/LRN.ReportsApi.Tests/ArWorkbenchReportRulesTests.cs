using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchReportRulesTests
{
    private static ArWorkbenchQueueLeafTotals Leaf(string queue, string label, int sort, string? sub, string? subLabel, int count, decimal initial, decimal open, decimal recovered)
        => new() { QueueId = queue, QueueLabel = label, QueueSort = sort, SubQueueId = sub, SubQueueLabel = subLabel, Count = count, InitialAR = initial, InitialAROpen = open, Recovered = recovered };

    private static readonly ArWorkbenchReportRules.CollectionsContext Context = new(3, new DateTime(2026, 10, 5), new DateTime(2026, 1, 1), new DateTime(2026, 9, 30));

    private static List<ArWorkbenchQueueLeafTotals> SampleLeaves() =>
    [
        Leaf("closed", "Closed", 120, "closed_paid", "Fully Paid", 2, 200, 0, 150),
        Leaf("denied", "Denied", 60, "denied_collectible", "Possible Collectible", 3, 300, 300, 0),
        Leaf("denied", "Denied", 60, "denied_noncollectible", "Non-Collectible", 1, 100, 100, 0),
        Leaf("nonresponded", "Non-Responder", 90, null, null, 4, 400, 400, 0)
    ];

    [Theory]
    [InlineData(new[] { "100", "50", "30" }, new[] { 1.0, 0.5, 0.3 })]
    [InlineData(new[] { " 75% ", "abc", "", "0", "150", "75" }, new[] { 0.75 })]
    [InlineData(new string[0], new[] { 1.0, 0.5, 0.3 })]
    public void Tiers_are_parsed_from_the_master_list(string[] values, double[] expected)
    {
        Assert.Equal(expected.Select(e => (decimal)e), ArWorkbenchReportRules.ParseTiers(values));
    }

    [Fact]
    public void Collections_rows_follow_queue_order_with_subqueues_indented()
    {
        var report = ArWorkbenchReportRules.BuildArCollections(SampleLeaves(), ArWorkbenchReportRules.DefaultTiers, Context);

        var labels = report.Rows.Select(r => (string)r.Values[0]!).ToList();
        // Denied (60) -> its sub-queues, largest first; Non-Responder (90) has no sub-queue so no detail row; Closed (120); total.
        Assert.Equal(["Denied", "Possible Collectible", "Non-Collectible", "Non-Responder", "Closed", "Fully Paid", "Grand Total"], labels);
        Assert.Equal([0, 1, 1, 0, 0, 1, 0], report.Rows.Select(r => r.Level));
        Assert.True(report.Rows[^1].IsTotal);
        Assert.Equal(9, report.Columns.Count); // category, count, 3 exp, 3 yet, posted
    }

    [Fact]
    public void Collections_applies_tiers_and_only_counts_open_claims_as_yet_to_collect()
    {
        var report = ArWorkbenchReportRules.BuildArCollections(SampleLeaves(), ArWorkbenchReportRules.DefaultTiers, Context);
        var closed = report.Rows.Single(r => (string)r.Values[0]! == "Closed").Values;
        Assert.Equal(2, closed[1]);
        Assert.Equal(200m, closed[2]);   // exp 100%
        Assert.Equal(100m, closed[3]);   // exp 50%
        Assert.Equal(60m, closed[4]);    // exp 30%
        Assert.Equal(0m, closed[5]);     // nothing still owed
        Assert.Equal(150m, closed[8]);   // payments posted

        var grand = report.Rows[^1].Values;
        Assert.Equal(10, grand[1]);
        Assert.Equal(1000m, grand[2]);
        Assert.Equal(800m, grand[5]);
        Assert.Equal(150m, grand[8]);
    }

    [Fact]
    public void Collections_insights_quote_the_figures()
    {
        var report = ArWorkbenchReportRules.BuildArCollections(SampleLeaves(), ArWorkbenchReportRules.DefaultTiers, Context);
        Assert.Contains(report.Insights, i => i.StartsWith("As of Oct 05, 2026, 10 claims") && i.Contains("Jan 01, 2026 through Sep 30, 2026"));
        Assert.Contains(report.Insights, i => i.Contains("3 claims have been worked, and 7 are still pending"));
        Assert.Contains(report.Insights, i => i.Contains("Closed queue") && i.Contains("$150.00 collected against $200.00") && i.Contains("75%"));
        Assert.Contains(report.Insights, i => i.Contains("4 claims are in the Denied queue") && i.Contains("1 of those are Non-Collectible"));
        Assert.Contains(report.Insights, i => i.Contains("realization rate") && i.Contains("15%"));
    }

    [Fact]
    public void Collections_with_no_claims_still_has_a_grand_total()
    {
        var report = ArWorkbenchReportRules.BuildArCollections([], ArWorkbenchReportRules.DefaultTiers, new(0, null, null, null));
        Assert.Single(report.Rows);
        Assert.Equal(0, report.Rows[0].Values[1]);
        Assert.Contains(report.Insights, i => i.Contains("0% realization rate"));
    }

    [Fact]
    public void Excel_export_writes_header_rows_totals_and_insights()
    {
        var report = ArWorkbenchReportRules.BuildArCollections(SampleLeaves(), ArWorkbenchReportRules.DefaultTiers, Context);
        using var wb = new XLWorkbook(new MemoryStream(ArWorkbenchReportExcel.Build(report)));
        var ws = wb.Worksheets.First();

        Assert.Equal("AR Collections Progress Summary", ws.Cell(1, 1).GetString());
        Assert.Equal("Follow Up Category | Status", ws.Cell(4, 1).GetString());
        Assert.Equal("Denied", ws.Cell(5, 1).GetString());
        Assert.Equal(1000m, ws.Cell(4 + report.Rows.Count, 3).GetValue<decimal>());
        Assert.True(ws.Cell(4 + report.Rows.Count, 1).Style.Font.Bold);
        Assert.Contains(ws.CellsUsed(), c => c.GetString() == "Insights");
    }

    [Fact]
    public void Range_defaults_to_the_last_30_days()
    {
        var (range, error) = ArWorkbenchReportRules.ResolveRange(null, null, new DateTime(2026, 10, 7));
        Assert.Null(error);
        Assert.Equal(new DateTime(2026, 9, 8), range!.From);
        Assert.Equal(new DateTime(2026, 10, 7), range.To);
    }

    [Fact]
    public void Range_rejects_reversed_and_over_long_periods()
    {
        var today = new DateTime(2026, 10, 7);
        Assert.NotNull(ArWorkbenchReportRules.ResolveRange(new DateTime(2026, 10, 8), new DateTime(2026, 10, 1), today).Error);
        // 366 days inclusive is the most allowed.
        Assert.NotNull(ArWorkbenchReportRules.ResolveRange(new DateTime(2024, 12, 31), new DateTime(2026, 1, 1), today).Error);
        Assert.Null(ArWorkbenchReportRules.ResolveRange(new DateTime(2025, 1, 1), new DateTime(2026, 1, 1), today).Error);
    }

    [Fact]
    public void Sla_targets_fall_back_to_the_draft_defaults()
    {
        var targets = ArWorkbenchReportRules.ParseSlaTargets(new Dictionary<string, string?>
        {
            ["SlaFirstFollowUpDays"] = "5",
            ["SlaQaDecisionDays"] = "abc",
            ["SlaClientResponseDays"] = "999"
        });
        Assert.Equal(ArWorkbenchReportRules.SlaMilestones.Count, targets.Count);
        Assert.Equal(5, targets.Single(t => t.Key == "ASSIGN_FIRST_FOLLOWUP").Days);
        Assert.Equal(2, targets.Single(t => t.Key == "QA_DECISION").Days);
        Assert.Equal(7, targets.Single(t => t.Key == "CIP_CLIENT_RESPONSE").Days);
    }

    [Fact]
    public void Sla_save_needs_every_milestone_in_range()
    {
        var all = ArWorkbenchReportRules.SlaMilestones.ToDictionary(m => m.Key.ToLowerInvariant(), m => m.DefaultDays);
        var (values, error) = ArWorkbenchReportRules.ValidateSlaTargets(all);
        Assert.Null(error);
        Assert.Equal(3, values!["SlaFirstFollowUpDays"]);

        var missing = new Dictionary<string, int>(all);
        missing.Remove("qa_decision");
        Assert.NotNull(ArWorkbenchReportRules.ValidateSlaTargets(missing).Error);
        Assert.NotNull(ArWorkbenchReportRules.ValidateSlaTargets(new Dictionary<string, int>(all) { ["qa_decision"] = 366 }).Error);
        Assert.NotNull(ArWorkbenchReportRules.ValidateSlaTargets(new Dictionary<string, int>(all) { ["bogus"] = 1 }).Error);
        Assert.NotNull(ArWorkbenchReportRules.ValidateSlaTargets(null).Error);
    }

    [Fact]
    public void Every_rpt_points_at_a_report_or_a_screen()
    {
        Assert.Equal(Enumerable.Range(1, 9).Select(i => $"RPT-0{i}"), ArWorkbenchReportRules.RptCatalog.Select(r => r.Code));
        foreach (var rpt in ArWorkbenchReportRules.RptCatalog)
        {
            Assert.True(rpt.ReportId is not null || rpt.Route is not null, rpt.Code);
            if (rpt.ReportId is not null) Assert.Contains(ArWorkbenchReportRules.Catalog, r => r.Id == rpt.ReportId);
        }
    }

    [Fact]
    public void Agent_productivity_is_internal_only()
    {
        Assert.Contains(ArWorkbenchReportRules.AgentProductivity, ArWorkbenchReportRules.InternalOnly);
        Assert.Single(ArWorkbenchReportRules.Catalog, r => r.Featured);
        Assert.Equal(ArWorkbenchReportRules.Catalog.Count, ArWorkbenchReportRules.Catalog.Select(r => r.Id).Distinct().Count());
    }
}
