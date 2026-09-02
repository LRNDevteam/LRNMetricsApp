using LRN.ReportsApi.Controllers;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Role classification behind the workflow's permission model. These drive who may upload a
/// manager escalation response (Round 1 UAT Bug 1/3) and which upload-template columns each role
/// gets, so the exact reviewer-vs-manager boundary must stay pinned.
/// </summary>
public class DenialWorkflowRoleTests
{
    [Theory]
    [InlineData("AR Reviewer", true)]
    [InlineData("AR-Reviewer", true)]
    [InlineData("ar reviewer", true)]
    [InlineData("AR Analyst", true)]
    [InlineData("AR Analyser", true)]
    [InlineData("AR Analyzer", true)]
    [InlineData("Reviewer", true)]
    [InlineData("AR Manager", false)]
    [InlineData("Admin", false)]
    [InlineData("Client Manager", false)]
    [InlineData("Account Manager", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void IsReviewerOnly_classifies_reviewer_roles(string? role, bool expected)
        => Assert.Equal(expected, DenialWorkflowController.IsReviewerOnly(role));

    [Theory]
    [InlineData("AR Manager", true)]
    [InlineData("ARManager", true)]
    [InlineData("Admin", true)]
    [InlineData("System Admin", true)]
    [InlineData("AR Reviewer", false)]
    [InlineData("Client Manager", false)]
    [InlineData("Account Manager", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void IsManagerOrAdminRole_only_true_for_manager_or_admin(string? role, bool expected)
        => Assert.Equal(expected, DenialWorkflowController.IsManagerOrAdminRole(role));

    [Theory]
    [InlineData("Client Manager", true)]
    [InlineData("Account Manager", true)]
    [InlineData("Lab User", true)]
    [InlineData("AR Reviewer", false)]
    [InlineData("AR Manager", false)]
    public void IsReadOnlyWorkflowRole_covers_external_managers_and_lab_users(string role, bool expected)
        => Assert.Equal(expected, DenialWorkflowController.IsReadOnlyWorkflowRole(role));

    // The lab's own staff: workflow screens are visible, every write endpoint refuses them.
    // Spelling variants all resolve, because the role is created by hand in Admin > Roles.
    [Theory]
    [InlineData("Lab User", true)]
    [InlineData("LabUser", true)]
    [InlineData("lab-user", true)]
    [InlineData("lab user", true)]
    [InlineData("AR Reviewer", false)]
    [InlineData("AR Manager", false)]
    [InlineData("Client Manager", false)]
    [InlineData("Admin", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void IsLabUserRole_matches_only_the_lab_user_role(string? role, bool expected)
        => Assert.Equal(expected, DenialWorkflowController.IsLabUserRole(role));

    // A Lab User must never be mistaken for a role that can act: reviewer scope would widen
    // their claim visibility, manager/admin would let them assign and approve.
    [Theory]
    [InlineData("Lab User")]
    [InlineData("LabUser")]
    public void Lab_user_is_neither_reviewer_nor_manager(string role)
    {
        Assert.False(DenialWorkflowController.IsReviewerOnly(role));
        Assert.False(DenialWorkflowController.IsManagerOrAdminRole(role));
    }

    // A manager must not be misread as a reviewer and vice-versa — the two predicates are exclusive.
    [Theory]
    [InlineData("AR Reviewer")]
    [InlineData("AR Manager")]
    [InlineData("Admin")]
    public void Reviewer_and_manager_are_mutually_exclusive(string role)
        => Assert.False(DenialWorkflowController.IsReviewerOnly(role) && DenialWorkflowController.IsManagerOrAdminRole(role));
}
