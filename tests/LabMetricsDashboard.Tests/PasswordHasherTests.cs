using LabMetricsDashboard.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

public class PasswordHasherTests
{
    [Fact]
    public void Hash_Then_Verify_ReturnsTrue()
    {
        var hasher = new PasswordHasher();
        var pwd = "My$ecureP@ssw0rd";
        var h = hasher.Hash(pwd);
        Assert.True(hasher.Verify(h, pwd));
    }

    [Fact]
    public void Verify_WithWrongPassword_ReturnsFalse()
    {
        var hasher = new PasswordHasher();
        var pwd = "abc12345";
        var h = hasher.Hash(pwd);
        Assert.False(hasher.Verify(h, "wrongpass"));
    }
}
