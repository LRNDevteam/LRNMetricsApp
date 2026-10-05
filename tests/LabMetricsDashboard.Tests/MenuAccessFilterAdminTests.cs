using System.Linq;
using System.Security.Claims;
using LabMetricsDashboard.Filters;
using Xunit;

namespace LabMetricsDashboard.Tests;

public class MenuAccessFilterAdminTests
{
    private static ClaimsPrincipal WithRoles(params string[] roles) =>
        new(new ClaimsIdentity(roles.Select(r => new Claim(ClaimTypes.Role, r)), "test"));

    [Theory]
    [InlineData("Admin")]
    [InlineData("Super Admin")]   // was refused every page when it had no Role Menu Mapping rows
    [InlineData("SuperAdmin")]
    [InlineData("super admin")]
    [InlineData("LRN Admin")]
    [InlineData("LRNAdmin")]
    public void Full_admin_roles_skip_the_menu_check(string role) =>
        Assert.True(MenuAccessFilter.IsFullAdmin(WithRoles(role)));

    [Theory]
    [InlineData("Lab Admin")]          // pages come from Role Menu Mapping
    [InlineData("AR Manager")]
    [InlineData("Payer Policy Admin")] // contains "Admin" but is not an admin
    public void Other_roles_go_through_the_menu_check(string role) =>
        Assert.False(MenuAccessFilter.IsFullAdmin(WithRoles(role)));

    [Fact]
    public void Any_one_admin_role_is_enough() =>
        Assert.True(MenuAccessFilter.IsFullAdmin(WithRoles("AR Manager", "Super Admin")));
}
