using LRN.ReportsApi.Services.ArWorkbench;
using LRN.ReportsApi.Services.UserMail;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>Add User: Microsoft (Lab Revenue Navigator) vs external email accounts, username = email.</summary>
public class ArWorkbenchAccountTypeTests
{
    private static readonly string[] Org = ["labrevenuenavigator.com"];

    [Theory]
    [InlineData("microsoft", "Jane.Doe@LabRevenueNavigator.com", "jane.doe@labrevenuenavigator.com")]
    [InlineData("external", " someone@clinic-partner.com ", "someone@clinic-partner.com")]
    [InlineData("EXTERNAL", "a.b@gmail.com", "a.b@gmail.com")]
    public void Valid_email_becomes_the_lower_case_username(string type, string email, string expected)
    {
        var (value, error) = ArWorkbenchUserRules.ValidateAccountEmail(type, email, Org);
        Assert.Null(error);
        Assert.Equal(expected, value);
    }

    [Theory]
    [InlineData("microsoft", "someone@gmail.com")]          // Microsoft must be the organization domain
    [InlineData("external", "staff@labrevenuenavigator.com")] // staff must use Microsoft + MFA
    [InlineData("external", "not-an-email")]
    [InlineData("external", "")]
    [InlineData(null, "someone@gmail.com")]                  // account type is required
    [InlineData("external", "first last@gmail.com")]
    public void Invalid_combinations_are_refused(string? type, string email)
    {
        var (value, error) = ArWorkbenchUserRules.ValidateAccountEmail(type, email, Org);
        Assert.Null(value);
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Fact]
    public void Organization_domain_defaults_when_not_configured()
    {
        var config = new ConfigurationBuilder().Build();
        Assert.Equal(["labrevenuenavigator.com"], ArWorkbenchUserRules.OrganizationDomains(config));
    }

    [Fact]
    public void Organization_domains_come_from_HybridAuth_config()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["HybridAuth:OrganizationDomains:0"] = "@lrn.example",
            ["HybridAuth:OrganizationDomains:1"] = "labrevenuenavigator.com"
        }).Build();
        Assert.Equal(["lrn.example", "labrevenuenavigator.com"], ArWorkbenchUserRules.OrganizationDomains(config));
    }

    [Theory]
    [InlineData("johnsmith@example.com", "jo***@ex***.com")]
    [InlineData("a@b.co", "a***@b***.co")]
    public void Sign_in_page_shows_a_masked_address(string email, string masked)
        => Assert.Equal(masked, LoginCodeService.MaskEmail(email));

    [Fact]
    public void Sign_in_code_email_contains_the_code_and_lifetime()
    {
        var html = LoginCodeService.BuildHtml("user@example.com", "123456", 10, "10.0.0.1", ["help@labrevenuenavigator.com"]);
        Assert.Contains("123456", html);
        Assert.Contains("10 minutes", html);
        Assert.Contains("help@labrevenuenavigator.com", html);
    }
}
