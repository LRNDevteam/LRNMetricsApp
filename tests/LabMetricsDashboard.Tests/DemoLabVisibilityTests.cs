using System;
using System.Collections.Generic;
using LabMetricsDashboard.Models;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// LabConfig:DemoLabs takes a demo/training lab out of the "admins see every lab" shortcut,
/// so it surfaces only for users explicitly assigned it. Four call sites depend on this rule
/// (navbar picker, static menu fallback, Report Control Board, and the Denial Workflow JWT),
/// so the rule itself is pinned here rather than in any one of them.
/// </summary>
public class DemoLabVisibilityTests
{
    private static readonly string[] AllLabs = ["PCRLabsofAmerica", "Cove", "LRNLabDemo"];

    private static LabConfigOptions Options() => new() { DemoLabs = { "LRNLabDemo" } };

    private static HashSet<string> Assigned(params string[] labs) =>
        new(labs, StringComparer.OrdinalIgnoreCase);

    [Fact]
    public void Admin_sees_every_real_lab_but_not_an_unassigned_demo_lab()
    {
        var visible = Options().VisibleLabs(AllLabs, Assigned(), isAdmin: true);

        Assert.Contains("PCRLabsofAmerica", visible);
        Assert.Contains("Cove", visible);
        Assert.DoesNotContain("LRNLabDemo", visible);
    }

    // An admin running the demo must still get it — assignment is the way in, for everyone.
    [Fact]
    public void Admin_assigned_the_demo_lab_sees_it()
    {
        var visible = Options().VisibleLabs(AllLabs, Assigned("LRNLabDemo"), isAdmin: true);

        Assert.Contains("LRNLabDemo", visible);
        Assert.Contains("Cove", visible);
    }

    [Fact]
    public void Demo_user_sees_only_the_demo_lab()
    {
        var visible = Options().VisibleLabs(AllLabs, Assigned("LRNLabDemo"), isAdmin: false);

        Assert.Equal(["LRNLabDemo"], visible);
    }

    [Fact]
    public void Non_admin_still_gets_only_their_assigned_labs()
    {
        var visible = Options().VisibleLabs(AllLabs, Assigned("Cove"), isAdmin: false);

        Assert.Equal(["Cove"], visible);
    }

    // With nothing configured as a demo lab, the old behaviour must be untouched.
    [Fact]
    public void With_no_demo_labs_configured_an_admin_sees_everything()
    {
        var visible = new LabConfigOptions().VisibleLabs(AllLabs, Assigned(), isAdmin: true);

        Assert.Equal(3, visible.Count);
    }

    [Theory]
    [InlineData("LRNLabDemo", true)]
    [InlineData("lrnlabdemo", true)]
    [InlineData("PCRLabsofAmerica", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void IsDemoLab_matches_case_insensitively(string? labName, bool expected)
        => Assert.Equal(expected, Options().IsDemoLab(labName));
}
