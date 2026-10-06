using System.Linq;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchUserProfileTests
{
    private static readonly Dictionary<int, IReadOnlyList<string>> Clinics = new()
    {
        [1] = ["North Clinic", "South Clinic"],
        [2] = ["East Clinic"]
    };
    private static readonly HashSet<int> Managers = [10, 11];

    [Fact]
    public void Unscoped_role_keeps_no_scope_and_trims_team()
    {
        var (p, error) = ArWorkbenchUserRules.ValidateProfile(null, [1], [new() { LabId = 1, ClinicName = "North Clinic" }], Clinics, 10, Managers, 5, "  Team   A ");
        Assert.Null(error);
        Assert.Empty(p!.Scopes);
        Assert.Equal("Team A", p.TeamName);
        Assert.Equal(10, p.ManagerUserId);
    }

    [Fact]
    public void Clinic_viewer_needs_a_clinic_for_every_lab()
    {
        var (_, error) = ArWorkbenchUserRules.ValidateProfile("clinic", [1, 2], [new() { LabId = 1, ClinicName = "North Clinic" }], Clinics, null, Managers, null, null);
        Assert.NotNull(error);
    }

    [Fact]
    public void Clinic_must_exist_on_that_labs_claims_and_takes_its_spelling()
    {
        Assert.NotNull(ArWorkbenchUserRules.ValidateProfile("clinic", [2], [new() { LabId = 2, ClinicName = "North Clinic" }], Clinics, null, Managers, null, null).Error);
        var (p, error) = ArWorkbenchUserRules.ValidateProfile("clinic", [1], [new() { LabId = 1, ClinicName = "north clinic" }], Clinics, null, Managers, null, null);
        Assert.Null(error);
        Assert.Equal("North Clinic", Assert.Single(p!.Scopes).ClinicName);
    }

    [Fact]
    public void Provider_viewer_stores_the_provider_not_the_clinic()
    {
        var providers = new Dictionary<int, IReadOnlyList<string>> { [1] = ["Dr. Lee"] };
        var (p, error) = ArWorkbenchUserRules.ValidateProfile("provider", [1], [new() { LabId = 1, ProviderName = "Dr. Lee", ClinicName = "ignored" }], providers, null, Managers, null, null);
        Assert.Null(error);
        var s = Assert.Single(p!.Scopes);
        Assert.Equal("Dr. Lee", s.ProviderName);
        Assert.Null(s.ClinicName);
    }

    [Fact]
    public void Manager_must_be_offered_and_not_the_user()
    {
        Assert.NotNull(ArWorkbenchUserRules.ValidateProfile(null, [1], null, Clinics, 99, Managers, 5, null).Error);
        Assert.NotNull(ArWorkbenchUserRules.ValidateProfile(null, [1], null, Clinics, 10, Managers, 10, null).Error);
        Assert.Null(ArWorkbenchUserRules.ValidateProfile(null, [1], null, Clinics, 0, Managers, 5, null).Profile!.ManagerUserId);
    }

    [Fact]
    public void Long_team_name_is_rejected()
        => Assert.NotNull(ArWorkbenchUserRules.ValidateProfile(null, [1], null, Clinics, null, Managers, null, new string('t', 101)).Error);
}
