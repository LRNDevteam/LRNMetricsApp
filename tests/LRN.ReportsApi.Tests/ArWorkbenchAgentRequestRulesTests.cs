using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchAgentRequestRulesTests
{
    [Theory]
    [InlineData("escalation", "Escalation to Supervisor")]
    [InlineData(" Reassignment ", "Reassignment Request")]
    [InlineData("Escalation to Supervisor", "Escalation to Supervisor")]
    [InlineData("cip", null)]
    [InlineData(null, null)]
    public void Request_types_parse(string? raw, string? expected) => Assert.Equal(expected, ArWorkbenchAgentRequestRules.ParseType(raw));

    [Fact]
    public void A_valid_request_is_trimmed()
    {
        var (type, reason, note, error) = ArWorkbenchAgentRequestRules.ValidateCreate(new ArWorkbenchAgentRequestCreate
        { RequestType = "reassignment", ReasonCategory = "  Workload / capacity ", Note = "  Too many Humana claims this week. " });
        Assert.Null(error);
        Assert.Equal("Reassignment Request", type);
        Assert.Equal("Workload / capacity", reason);
        Assert.Equal("Too many Humana claims this week.", note);
        Assert.Equal("REASSIGNMENT_REASON", ArWorkbenchAgentRequestRules.ReasonList(type!));
    }

    [Theory]
    [InlineData(null, "Payer call required", "note")]
    [InlineData("escalation", "", "note")]
    [InlineData("escalation", "Payer call required", "  ")]
    public void Incomplete_requests_are_refused(string? type, string reason, string note)
        => Assert.NotNull(ArWorkbenchAgentRequestRules.ValidateCreate(new ArWorkbenchAgentRequestCreate { RequestType = type, ReasonCategory = reason, Note = note }).Error);

    [Fact]
    public void Too_long_a_note_is_refused()
        => Assert.NotNull(ArWorkbenchAgentRequestRules.ValidateCreate(new ArWorkbenchAgentRequestCreate
            { RequestType = "escalation", ReasonCategory = "Other", Note = new string('x', 2001) }).Error);

    [Fact]
    public void Resolve_dedupes_ids_and_needs_a_note()
    {
        var (ids, note, error) = ArWorkbenchAgentRequestRules.ValidateResolve(new ArWorkbenchAgentRequestResolve { RequestIds = [3, 3, 0, -1, 7], Note = " Done " });
        Assert.Null(error);
        Assert.Equal([3L, 7L], ids);
        Assert.Equal("Done", note);

        Assert.NotNull(ArWorkbenchAgentRequestRules.ValidateResolve(new ArWorkbenchAgentRequestResolve { RequestIds = [1], Note = "" }).Error);
        Assert.NotNull(ArWorkbenchAgentRequestRules.ValidateResolve(new ArWorkbenchAgentRequestResolve { RequestIds = [], Note = "x" }).Error);
        Assert.NotNull(ArWorkbenchAgentRequestRules.ValidateResolve(new ArWorkbenchAgentRequestResolve
            { RequestIds = Enumerable.Range(1, 501).Select(i => (long)i).ToList(), Note = "x" }).Error);
    }

    [Fact]
    public void Activity_names_follow_the_request_type()
    {
        Assert.Equal("Escalated to Supervisor", ArWorkbenchAgentRequestRules.RaisedActivity(ArWorkbenchAgentRequestRules.Escalation));
        Assert.Equal("Reassignment Request Resolved", ArWorkbenchAgentRequestRules.ResolvedActivity(ArWorkbenchAgentRequestRules.Reassignment));
    }
}
