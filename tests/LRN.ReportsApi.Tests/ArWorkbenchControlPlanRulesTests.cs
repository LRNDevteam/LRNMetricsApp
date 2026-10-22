using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>FR-DASH-02 / FR-DASH-03 (retest DEF-23): Control Plan grouping and the SLA attainment tile.</summary>
public class ArWorkbenchControlPlanRulesTests
{
    private static ArWorkbenchControlPlanRow Row(int open, int progress, int closed) => new()
    {
        OpenCount = open, OpenAmount = open * 10m, InProgressCount = progress, InProgressAmount = progress * 10m, ClosedCount = closed, ClosedAmount = 0
    };

    [Fact]
    public void Codes_roll_up_to_their_classification_with_unclassified_and_no_denial_last()
    {
        var classOf = new Dictionary<string, string> { ["11"] = "Coding", ["16"] = "Coding", ["204"] = "Coverage" };
        var rows = ArWorkbenchControlPlanRules.ByClassification(
            [("11", Row(2, 1, 0)), ("16", Row(1, 0, 3)), ("204", Row(1, 0, 0)), ("999", Row(5, 0, 0)), (null, Row(9, 9, 9))], classOf);

        Assert.Equal(["Coding", "Coverage", ArWorkbenchControlPlanRules.Unclassified, ArWorkbenchControlPlanRules.NoDenial], rows.Select(r => r.Label));
        var coding = rows[0];
        Assert.Equal((3, 1, 3), (coding.OpenCount, coding.InProgressCount, coding.ClosedCount));
        Assert.Equal(30m, coding.OpenAmount);
    }

    [Fact]
    public void Sla_summary_measures_met_over_met_breached_and_overdue()
    {
        static ArWorkbenchReportRow R(string label, int met, int breached, int onTrack, int overdue) =>
            new() { Values = [label, 2, met + breached + onTrack + overdue, met, breached, onTrack, overdue, null, null] };
        var report = new ArWorkbenchReport { Rows = [R("QA decision", 8, 1, 5, 1), R("CIP approval", 0, 0, 2, 0)] };

        var s = ArWorkbenchControlPlanRules.SlaSummary(report, 30, confirmed: false);
        Assert.Equal(10, s.Measured);
        Assert.Equal(0.8m, s.AttainmentPct);
        Assert.False(s.TargetsConfirmed);
        Assert.Null(s.Milestones[1].AttainmentPct);   // only open, on-track instances: nothing measured yet
    }
}
