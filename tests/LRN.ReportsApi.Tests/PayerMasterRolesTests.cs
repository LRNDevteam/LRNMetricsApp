using System.Security.Claims;
using LRN.ReportsApi.Security;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class PayerMasterRolesTests
{
    private static ClaimsPrincipal UserWith(params string[] roles)
        => new(new ClaimsIdentity(roles.Select(r => new Claim(ClaimTypes.Role, r)), "test"));

    [Theory]
    [InlineData("Admin")]
    [InlineData("Super Admin")]
    [InlineData("superadmin")]
    [InlineData("LRN Admin")]
    [InlineData("LRNAdmin")]
    public void Full_admin_roles_manage_menus(string role) => Assert.True(PayerMasterRoles.IsLrnAdmin(UserWith(role)));

    [Theory]
    [InlineData("Lab Admin")]
    [InlineData("Lab User")]
    [InlineData("AR Workbench - System Administrator")]
    public void Other_roles_do_not(string role) => Assert.False(PayerMasterRoles.IsLrnAdmin(UserWith(role)));
}
