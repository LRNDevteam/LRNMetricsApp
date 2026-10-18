using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Fixes from docs/AR_Workbench_Test_Report_2026-10-15.xlsx that are decided in code rather than SQL.
/// </summary>
public class ArWorkbenchTestReportFixTests
{
    private static ArWorkbenchClaimDetail Detail() => new()
    {
        Claim = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
        {
            ["ClaimID"] = "19524452",
            ["PrimaryDenialCode"] = "16",
            ["QaStatus"] = "Approved",
            ["QaSubmittedBy"] = "ARAgent1",
            ["AssignedAgentUser"] = "ARAgent1",
            ["FixResolution"] = "CIP - Client Escalations",
            ["PendingAgentRequests"] = 1
        },
        FollowUps = [new ArWorkbenchFollowUp()],
        Activity = [new ArWorkbenchActivity()],
        QaReview = new ArWorkbenchQaReview(),
        CipCases = [new ArWorkbenchCipCaseDetail()],
        AgentRequests = [new ArWorkbenchAgentRequestRow()]
    };

    /// <summary>DEF-15 (Critical): a Clinic / Client Viewer opening a claim by URL sees no internal notes.</summary>
    [Fact]
    public void Client_users_get_the_claim_without_internal_notes()
    {
        var detail = Detail();
        ArWorkbenchClientVisibility.Apply(detail, new ArWorkbenchUserContext { RoleCode = "viewer" });

        Assert.Empty(detail.FollowUps);
        Assert.Empty(detail.Activity);
        Assert.Null(detail.QaReview);
        Assert.Empty(detail.CipCases);
        Assert.Empty(detail.AgentRequests);
        Assert.False(detail.Claim.ContainsKey("QaStatus"));
        Assert.False(detail.Claim.ContainsKey("QaSubmittedBy"));
        Assert.False(detail.Claim.ContainsKey("AssignedAgentUser"));
        Assert.False(detail.Claim.ContainsKey("FixResolution"));
        // The claim's own data stays.
        Assert.Equal("19524452", detail.Claim["ClaimID"]);
        Assert.Equal("16", detail.Claim["PrimaryDenialCode"]);
    }

    [Theory]
    [InlineData("agent")]
    [InlineData("qa")]
    [InlineData("lead")]
    [InlineData("manager")]
    [InlineData("admin")]
    public void Internal_users_keep_the_full_claim(string roleCode)
    {
        var detail = Detail();
        ArWorkbenchClientVisibility.Apply(detail, new ArWorkbenchUserContext { RoleCode = roleCode });

        Assert.Single(detail.FollowUps);
        Assert.Single(detail.Activity);
        Assert.NotNull(detail.QaReview);
        Assert.True(detail.Claim.ContainsKey("QaStatus"));
    }

    [Fact]
    public void A_site_admin_is_never_treated_as_a_client()
    {
        // A site admin's derived role code can be "viewer" when they hold no workbench role.
        var admin = new ArWorkbenchUserContext { RoleCode = "viewer", SiteAdmin = true };
        Assert.False(ArWorkbenchClientVisibility.IsClientUser(admin));
    }

    /// <summary>DEF-08: the RCM Manager maintains exactly the Non-Collectible and Auto-Adjust lists.</summary>
    [Theory]
    [InlineData("NON_COLLECTIBLE_CODE", true)]
    [InlineData("non_collectible_code", true)]
    [InlineData("AUTO_ADJUST_CODE", true)]
    [InlineData("DENIAL_CATEGORY", false)]
    [InlineData("FIX_RESOLUTION", false)]
    [InlineData("DOCUMENT_CATEGORY", false)]
    public void Manager_maintained_lists(string type, bool managerMayEdit)
    {
        Assert.Equal(managerMayEdit, ArWorkbenchMasterRules.ManagerMaintainedTypes.Contains(type));
        // Every manager list is a real list.
        if (managerMayEdit) Assert.NotNull(ArWorkbenchMasterRules.Find(type));
    }
}
