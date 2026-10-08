using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchPasswordChangeTests
{
    [Fact]
    public void A_hash_verifies_only_its_own_password()
    {
        var hash = ArWorkbenchUserRules.HashPassword("Secret123");
        Assert.True(ArWorkbenchUserRules.VerifyPassword(hash, "Secret123"));
        Assert.False(ArWorkbenchUserRules.VerifyPassword(hash, "secret123"));
        Assert.False(ArWorkbenchUserRules.VerifyPassword(hash, ""));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("plain-text-password")]
    [InlineData("100000:not-base64!:also-not")]
    [InlineData("abc:AAAA:AAAA")]
    public void A_malformed_stored_hash_never_matches(string? stored)
        => Assert.False(ArWorkbenchUserRules.VerifyPassword(stored, "Secret123"));

    [Theory]
    [InlineData("", "NewPass123", "Enter your current password.")]
    [InlineData("OldPass123", "short1", "New password must be 8 to 128 characters.")]
    [InlineData("OldPass123", "onlyletters", "New password must contain at least one letter and one number.")]
    [InlineData("OldPass123", "OldPass123", "The new password must be different from the current one.")]
    public void Invalid_changes_are_refused(string current, string next, string expected)
        => Assert.Equal(expected, ArWorkbenchUserRules.ValidatePasswordChange(current, next));

    [Fact]
    public void A_valid_change_passes()
        => Assert.Null(ArWorkbenchUserRules.ValidatePasswordChange("OldPass123", "NewPass456"));
}
