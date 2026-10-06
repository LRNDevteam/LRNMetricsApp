using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchCipRulesTests
{
    [Theory]
    [InlineData(ArWorkbenchCipAction.Approve, "Pending Approval", "Sent to Client")]
    [InlineData(ArWorkbenchCipAction.Reject, "Pending Approval", "Returned to Agent")]
    [InlineData(ArWorkbenchCipAction.Respond, "Sent to Client", "Client Responded")]
    [InlineData(ArWorkbenchCipAction.ApproveResponse, "Client Responded", "Returned to Agent")]
    [InlineData(ArWorkbenchCipAction.Insufficient, "Client Responded", "Sent to Client")]
    public void Lifecycle_transitions(ArWorkbenchCipAction action, string from, string to)
    {
        var t = ArWorkbenchCipRules.Transition(action);
        Assert.Equal(from, t.From);
        Assert.Equal(to, t.To);
    }

    [Theory]
    [InlineData("approve", ArWorkbenchCipAction.Approve)]
    [InlineData("Approve-Response", ArWorkbenchCipAction.ApproveResponse)]
    [InlineData("insufficient", ArWorkbenchCipAction.Insufficient)]
    public void Actions_parse(string text, ArWorkbenchCipAction expected) => Assert.Equal(expected, ArWorkbenchCipRules.Parse(text));

    [Fact]
    public void Unknown_action_is_null() => Assert.Null(ArWorkbenchCipRules.Parse("delete"));

    [Theory]
    [InlineData(ArWorkbenchCipAction.Reject)]
    [InlineData(ArWorkbenchCipAction.Insufficient)]
    [InlineData(ArWorkbenchCipAction.Respond)]
    public void Negative_and_client_actions_need_text(ArWorkbenchCipAction action)
        => Assert.NotNull(ArWorkbenchCipRules.ValidateNote(action, "  "));

    [Theory]
    [InlineData(ArWorkbenchCipAction.Approve)]
    [InlineData(ArWorkbenchCipAction.ApproveResponse)]
    public void Approvals_take_an_optional_note(ArWorkbenchCipAction action) => Assert.Null(ArWorkbenchCipRules.ValidateNote(action, null));

    [Theory]
    [InlineData("Pending Approval", true, ArWorkbenchCipAction.Approve)]
    [InlineData("Pending Approval", false, ArWorkbenchCipAction.Reject)]
    [InlineData("Client Responded", true, ArWorkbenchCipAction.ApproveResponse)]
    [InlineData("Client Responded", false, ArWorkbenchCipAction.Insufficient)]
    public void Bulk_picks_the_action_for_each_stage(string stage, bool positive, ArWorkbenchCipAction expected)
        => Assert.Equal(expected, ArWorkbenchCipRules.ForStage(stage, positive));

    [Theory]
    [InlineData("Sent to Client")]
    [InlineData("Returned to Agent")]
    [InlineData("Awaiting QA")]
    public void Bulk_skips_stages_with_nothing_to_decide(string stage)
    {
        Assert.Null(ArWorkbenchCipRules.ForStage(stage, true));
        Assert.Null(ArWorkbenchCipRules.ForStage(stage, false));
    }

    [Fact]
    public void Only_respond_is_a_client_action()
    {
        Assert.True(ArWorkbenchCipRules.IsClientAction(ArWorkbenchCipAction.Respond));
        Assert.False(ArWorkbenchCipRules.IsClientAction(ArWorkbenchCipAction.Approve));
    }
}
