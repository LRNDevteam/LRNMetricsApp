using LabMetricsDashboard.Filters;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// The Lab User role is view-only by definition. These cover the two matching rules the filter
/// turns on, because a wrong answer either locks a lab out of its own exports or quietly lets a
/// view-only account write.
/// </summary>
public sealed class ViewOnlyRoleFilterTests
{
    private static readonly string[] ViewOnly = ["Lab User"];

    private static readonly string[] Allowed =
    [
        "account/login", "account/logout", "userreports",
        "dashboard/firstpaintclient", "usage/heartbeat",
        "helpbot/ask", "reimbursementchat/ask", "denialworkflow/authtoken",
    ];

    // dbo.Roles spells it "Labuser"; the code and the docs say "Lab User". Both are one role.
    [Theory]
    [InlineData("Lab User", true)]
    [InlineData("LabUser", true)]
    [InlineData("labuser", true)]
    [InlineData("LAB-USER", true)]
    [InlineData("Lab Admin", false)]
    [InlineData("Admin", false)]
    [InlineData("AR Manager", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Role_matching_ignores_case_spacing_and_punctuation(string? role, bool expected)
        => Assert.Equal(expected, ViewOnlyRoleFilter.HoldsViewOnlyRole([role], ViewOnly));

    [Fact]
    public void A_user_holding_several_roles_is_view_only_if_any_of_them_is()
        => Assert.True(ViewOnlyRoleFilter.HoldsViewOnlyRole(["AR Reviewer", "Labuser"], ViewOnly));

    // Exporting is reading: the whole UserReports controller is allowed, because its queue and
    // download are POSTs. Blocking them would stop a lab taking its own data to a spreadsheet.
    [Theory]
    [InlineData("UserReports", "Queue", true)]
    [InlineData("UserReports", "Download", true)]
    [InlineData("UserReports", "Cancel", true)]
    [InlineData("Account", "Logout", true)]
    [InlineData("Dashboard", "FirstPaintClient", true)]
    [InlineData("HelpBot", "Ask", true)]
    public void Reading_and_exporting_stay_allowed(string controller, string action, bool expected)
        => Assert.Equal(expected, ViewOnlyRoleFilter.IsAllowedEndpoint(controller, action, Allowed));

    // Everything that changes lab data is refused, including the paths a granted menu would expose.
    [Theory]
    [InlineData("Notes", "Save")]
    [InlineData("Notes", "Delete")]
    [InlineData("DenialClaimReport", "ImportInsights")]
    [InlineData("DenialClaimReport", "CopyToPreviousWeek")]
    [InlineData("DenialWorkflow", "UpdateTask")]
    [InlineData("MasterValues", "Save")]
    [InlineData("Admin", "CreateUser")]
    [InlineData("CodingSetup", "Create")]
    public void Writes_are_refused(string controller, string action)
        => Assert.False(ViewOnlyRoleFilter.IsAllowedEndpoint(controller, action, Allowed));

    // "account" alone must not open every Account action; only the two listed ones.
    [Fact]
    public void An_action_level_entry_does_not_allow_its_whole_controller()
        => Assert.False(ViewOnlyRoleFilter.IsAllowedEndpoint("Account", "ChangePassword", Allowed));
}
