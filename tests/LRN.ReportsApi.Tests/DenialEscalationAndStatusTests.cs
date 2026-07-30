using LRN.ReportsApi.Controllers;
using LRN.ReportsApi.Models;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Manager escalation-response validity (Bug 3) and status-update validation.
/// </summary>
public class DenialEscalationAndStatusTests
{
    [Theory]
    [InlineData("Proceed with Appeal", true)]
    [InlineData("Proceed with Rebill", true)]
    [InlineData("Proceed with Write-Off Request", true)]
    [InlineData("Close Claim / Line", true)]
    [InlineData("Other", true)]
    [InlineData("proceed with appeal", true)]           // case-insensitive
    [InlineData("Do whatever", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void IsValidManagerEscalationResponse_matches_the_allowed_set(string? value, bool expected)
        => Assert.Equal(expected, DenialWorkflowController.IsValidManagerEscalationResponse(value));

    [Theory]
    [InlineData("", "Assigned")]
    [InlineData("open", "Assigned")]
    [InlineData("Pending Review", "Assigned")]
    [InlineData("in progress", "Assigned")]
    [InlineData("Pending Payer", "Pending Payer Response")]
    [InlineData("escalated", "Escalated to AR Manager")]
    [InlineData("internal escalation", "Escalated to AR Manager")]
    [InlineData("external escalation", "External Escalation")]
    [InlineData("completed", "Closed")]
    [InlineData("required review", "Rework")]
    [InlineData("Payer Follow-up Required", "Payer Follow-up Required")]
    public void NormalizeWorkflowStatus_maps_raw_states_to_canonical(string raw, string expected)
        => Assert.Equal(expected, DenialWorkflowController.NormalizeWorkflowStatus(raw));

    [Fact]
    public void Reviewer_cannot_select_manager_only_Rework_status()
    {
        var request = new UpdateTaskRequest { Status = "Rework" };
        var error = DenialWorkflowController.ValidateTaskStatusUpdate(request, "AR Reviewer");
        Assert.False(string.IsNullOrEmpty(error));
    }

    [Fact]
    public void Unknown_status_is_rejected()
    {
        var request = new UpdateTaskRequest { Status = "Banana" };
        var error = DenialWorkflowController.ValidateTaskStatusUpdate(request, "AR Manager");
        Assert.Contains("not a valid denial workflow status", error);
    }

    [Fact]
    public void Closed_requires_actual_outcome_and_comments()
    {
        var missing = new UpdateTaskRequest { Status = "Closed" };
        Assert.False(string.IsNullOrEmpty(DenialWorkflowController.ValidateTaskStatusUpdate(missing, "AR Reviewer")));

        var complete = new UpdateTaskRequest { Status = "Closed", ActualOutcome = "Closed No Recovery", Comments = "done" };
        Assert.Equal(string.Empty, DenialWorkflowController.ValidateTaskStatusUpdate(complete, "AR Reviewer"));
    }

    [Fact]
    public void Assigned_status_has_no_required_fields()
    {
        var request = new UpdateTaskRequest { Status = "Assigned" };
        Assert.Equal(string.Empty, DenialWorkflowController.ValidateTaskStatusUpdate(request, "AR Reviewer"));
    }
}
