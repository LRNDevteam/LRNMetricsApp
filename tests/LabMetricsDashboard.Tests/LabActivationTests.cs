using System;
using System.Collections.Generic;
using System.Linq;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// Admin &gt; Manage Labs switches a lab off with dbo.Labs.IsActive = 0. LabSettings.Labs (what every
/// picker, the navbar and the Report Control Board read) must then drop it, and switching it back
/// on must restore it.
/// </summary>
public class LabActivationTests
{
    private static readonly LabConfigOptions Config = new()
    {
        LabsID =
        {
            new LabIdInfo { Id = 18, Name = "Certus" },
            new LabIdInfo { Id = 13, Name = "PCRLabsofAmerica" },
            new LabIdInfo { Id = 4,  Name = "Cove" },
            new LabIdInfo { Id = 12, Name = "Phi_Life" },
        }
    };

    private static readonly string[] Keys = ["Certus", "PCRLabsofAmerica", "Cove", "Phi_Life", "NoIdLab"];

    [Fact]
    public void Inactive_rows_map_to_config_keys_by_LabId()
    {
        var inactive = LabActivationService.MapToConfigKeys(Keys, [(18, "Certus Labs"), (12, "Phi Life")], Config);
        Assert.Equal(new[] { "Certus", "Phi_Life" }, inactive.OrderBy(x => x));
    }

    [Fact]
    public void LabId_wins_over_a_lookalike_name()
    {
        // Row 99 is inactive and is named like Cove, but Cove's own LabId (4) is active.
        var inactive = LabActivationService.MapToConfigKeys(Keys, [(99, "Cove")], Config);
        Assert.Empty(inactive);
    }

    [Fact]
    public void A_key_without_LabsID_falls_back_to_the_name()
    {
        var inactive = LabActivationService.MapToConfigKeys(Keys, [(77, "No Id Lab")], Config);
        Assert.Equal(new[] { "NoIdLab" }, inactive);
    }

    [Fact]
    public void Labs_hides_inactive_labs_and_restores_them_when_enabled()
    {
        var settings = new LabSettings
        {
            AllLabs = Keys.ToDictionary(k => k, _ => new LabCsvConfig(), StringComparer.OrdinalIgnoreCase)
        };
        Assert.Equal(Keys.Length, settings.Labs.Count);

        settings.InactiveLabs = new HashSet<string>(["Certus", "Phi_Life"], StringComparer.OrdinalIgnoreCase);
        Assert.False(settings.Labs.ContainsKey("Certus"));
        Assert.False(settings.Labs.ContainsKey("phi_life"));
        Assert.True(settings.Labs.ContainsKey("Cove"));
        Assert.True(settings.AllLabs.ContainsKey("Certus"));
        Assert.True(settings.IsInactive("certus"));

        settings.InactiveLabs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Assert.True(settings.Labs.ContainsKey("Certus"));
        Assert.False(settings.IsInactive("Certus"));
    }

    [Fact]
    public void A_config_reload_does_not_bring_an_inactive_lab_back()
    {
        var settings = new LabSettings
        {
            InactiveLabs = new HashSet<string>(["Certus"], StringComparer.OrdinalIgnoreCase)
        };
        settings.AllLabs = Keys.ToDictionary(k => k, _ => new LabCsvConfig(), StringComparer.OrdinalIgnoreCase);
        Assert.False(settings.Labs.ContainsKey("Certus"));
    }
}
