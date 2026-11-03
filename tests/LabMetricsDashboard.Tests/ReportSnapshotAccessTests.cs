using System.Linq;
using System.Security.Claims;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>Report Snapshots is the clients' page: a lab's users see that lab's report views, and only that lab's.</summary>
public sealed class ReportSnapshotAccessTests
{
    private static readonly LabConfigOptions Labs = new()
    {
        LabsID = [new LabIdInfo { Id = 29, Name = "TexasDiagnostic" }, new LabIdInfo { Id = 7, Name = "NorthWest" }]
    };

    private static ClaimsPrincipal User(string[] roles, params string[] labs) => new(new ClaimsIdentity(
        roles.Select(r => new Claim(ClaimTypes.Role, r)).Concat(labs.Select(l => new Claim("LabName", l))), "test"));

    [Fact]
    public void A_client_sees_only_the_labs_on_their_claims()
    {
        var client = User([], "TexasDiagnostic");
        Assert.True(ReportSnapshotViewerController.CanViewLab(client, Labs, 29, "Texas Diagnostic"));
        Assert.False(ReportSnapshotViewerController.CanViewLab(client, Labs, 7, "NorthWest"));
    }

    [Fact]
    public void The_run_lab_name_counts_when_the_lab_id_is_not_configured()
    {
        Assert.True(ReportSnapshotViewerController.CanViewLab(User([], "WellHealth"), Labs, 99, "WellHealth"));
        Assert.False(ReportSnapshotViewerController.CanViewLab(User([]), Labs, 29, "TexasDiagnostic"));
    }

    [Fact]
    public void Snapshot_admins_see_every_lab()
    {
        Assert.True(ReportSnapshotViewerController.CanViewLab(User(["Reports Analyst"]), Labs, 7, "NorthWest"));
    }
}
