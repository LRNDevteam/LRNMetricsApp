using System.Linq;
using System.Security.Cryptography;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchUserRulesTests
{
    private static readonly HashSet<int> MyLabs = [1, 2];
    private const string Agent = "AR Workbench - AR Agent";

    // The exact check LabMetricsDashboard.Services.PasswordHasher.Verify makes at sign-in.
    private static bool VerifyLikeLrnMetrics(string hashed, string password)
    {
        var parts = hashed.Split(':');
        if (parts.Length != 3 || !int.TryParse(parts[0], out var iter)) return false;
        var salt = Convert.FromBase64String(parts[1]);
        var expected = Convert.FromBase64String(parts[2]);
        using var pbkdf2 = new Rfc2898DeriveBytes(password, salt, iter, HashAlgorithmName.SHA256);
        return CryptographicOperations.FixedTimeEquals(pbkdf2.GetBytes(expected.Length), expected);
    }

    [Fact]
    public void Password_hash_verifies_the_way_LRN_Metrics_sign_in_does()
    {
        var hash = ArWorkbenchUserRules.HashPassword("Welcome123");
        Assert.StartsWith("100000:", hash);
        Assert.True(VerifyLikeLrnMetrics(hash, "Welcome123"));
        Assert.False(VerifyLikeLrnMetrics(hash, "welcome123"));
        Assert.NotEqual(hash, ArWorkbenchUserRules.HashPassword("Welcome123"));   // salted
    }

    [Theory]
    [InlineData("jdoe", true)]
    [InlineData("j.doe@lab.com", true)]
    [InlineData("ab", false)]
    [InlineData("john doe", false)]
    [InlineData("x;drop", false)]
    [InlineData(null, false)]
    public void Username_rules(string? name, bool ok) => Assert.Equal(ok, ArWorkbenchUserRules.ValidateUserName(name).Value is not null);

    [Theory]
    [InlineData("a@b.com", true)]
    [InlineData("first.last@lab.org", true)]
    [InlineData("", false)]
    [InlineData("nope", false)]
    [InlineData("a@b", false)]
    [InlineData("Name <a@b.com>", false)]
    public void Email_rules(string email, bool ok) => Assert.Equal(ok, ArWorkbenchUserRules.ValidateEmail(email).Value is not null);

    [Theory]
    [InlineData("Welcome123", true)]
    [InlineData("short1", false)]
    [InlineData("lettersonly", false)]
    [InlineData("12345678", false)]
    [InlineData("", false)]
    public void Password_rules(string password, bool ok) => Assert.Equal(ok, ArWorkbenchUserRules.ValidatePassword(password) is null);

    [Theory]
    [InlineData("Super Admin")]
    [InlineData("SuperAdmin")]
    [InlineData("Lab Admin")]
    [InlineData("LRN Admin")]
    [InlineData("admin")]
    public void Site_admin_roles_are_recognized(string role) => Assert.True(ArWorkbenchUserRules.IsSiteAdminRole(role));

    [Fact]
    public void Workbench_system_administrator_is_not_a_site_admin()
        => Assert.False(ArWorkbenchUserRules.IsSiteAdminRole("AR Workbench - System Administrator"));

    [Fact]
    public void Nobody_edits_their_own_account()
        => Assert.False(ArWorkbenchUserRules.CanManage(7, [Agent], [1], callerLabUserId: 7, callerAllLabs: true, MyLabs).Allowed);

    [Fact]
    public void Site_admin_accounts_are_read_only_even_for_super_admin()
        => Assert.False(ArWorkbenchUserRules.CanManage(8, [Agent, "Super Admin"], [1], 7, true, MyLabs).Allowed);

    [Fact]
    public void Super_admin_edits_users_in_any_lab()
        => Assert.True(ArWorkbenchUserRules.CanManage(8, [Agent, "AR Manager"], [1, 99], 7, true, MyLabs).Allowed);

    [Fact]
    public void Lab_admin_edits_users_inside_their_labs()
        => Assert.True(ArWorkbenchUserRules.CanManage(8, [Agent], [1, 2], 7, false, MyLabs).Allowed);

    [Fact]
    public void Lab_admin_cannot_edit_a_user_with_another_lab()
        => Assert.False(ArWorkbenchUserRules.CanManage(8, [Agent], [1, 99], 7, false, MyLabs).Allowed);

    [Fact]
    public void Lab_admin_cannot_edit_a_user_with_other_application_roles()
        => Assert.False(ArWorkbenchUserRules.CanManage(8, [Agent, "AR Manager"], [1], 7, false, MyLabs).Allowed);

    [Fact]
    public void Merge_keeps_labs_outside_the_callers_reach()
    {
        var merged = ArWorkbenchUserRules.MergeLabs(currentLabIds: [1, 99], requestedLabIds: [2], MyLabs);
        Assert.Equal([2, 99], merged.OrderBy(x => x));
    }

    [Fact]
    public void Labs_must_be_chosen_and_manageable()
    {
        Assert.Null(ArWorkbenchUserRules.ValidateLabs([], MyLabs).LabIds);
        Assert.Null(ArWorkbenchUserRules.ValidateLabs([1, 99], MyLabs).LabIds);
        Assert.Equal([1, 2], ArWorkbenchUserRules.ValidateLabs([1, 2, 2], MyLabs).LabIds);
    }
}
