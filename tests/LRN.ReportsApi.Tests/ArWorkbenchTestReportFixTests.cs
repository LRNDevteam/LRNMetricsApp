using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Fixes from docs/archive/AR_Workbench_Test_Report_2026-10-15.xlsx (retest: docs/ar-workbench/AR_Workbench_Retest_Report_v1.4_2026-10-19.xlsx) that are decided in code rather than SQL.
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

    /// <summary>DEF-15: the claims export a client can reach by calling the API carries no notes or internal work.</summary>
    [Fact]
    public void Client_claims_export_leaves_out_every_internal_column()
    {
        var client = ArWorkbenchClaimExcel.Headers(clientView: true);
        var full = ArWorkbenchClaimExcel.Headers(clientView: false);

        foreach (var header in ArWorkbenchClientVisibility.InternalExportColumns)
        {
            // A renamed column would otherwise slip back into the client's file unnoticed.
            Assert.Contains(header, full);
            Assert.DoesNotContain(header, client);
        }
        Assert.Contains("Claim ID", client);
        Assert.Contains("DenialCode", client);
        Assert.Contains("Ins. Balance", client);
    }

    [Fact]
    public void Claims_export_with_lines_adds_a_line_items_sheet_with_one_row_per_cpt()
    {
        var claim = new ArWorkbenchClaimRow { ClaimKey = 7, ClaimID = "19448764" };
        var lines = new Dictionary<long, List<ArWorkbenchClaimLine>>
        {
            [7] = [new() { LineNumber = 1, CPTCode = "87481", DenialCode = "CO11" }, new() { LineNumber = 2, CPTCode = "87640" }]
        };
        var bytes = ArWorkbenchClaimExcel.Build([claim], new Dictionary<long, ArWorkbenchClaimExportDetail>(), "t", false, clientView: true, lines);

        using var workbook = new ClosedXML.Excel.XLWorkbook(new MemoryStream(bytes));
        var sheet = workbook.Worksheet("Line Items");
        Assert.Equal("CPT", sheet.Cell(2, ArWorkbenchClaimExcel.LineHeaders().ToList().IndexOf("CPT") + 1).GetString());
        Assert.Equal("19448764", sheet.Cell(3, 1).GetString());
        Assert.Equal("87640", sheet.Cell(4, ArWorkbenchClaimExcel.LineHeaders().ToList().IndexOf("CPT") + 1).GetString());
        Assert.True(sheet.Cell(5, 1).IsEmpty());
    }

    [Fact]
    public void Client_claim_list_rows_lose_agent_resolution_and_qa()
    {
        var row = new ArWorkbenchClaimRow
        {
            ClaimID = "19524452", AssignedAgentUser = "ARAgent1", AssignedAgentName = "AR Agent 1",
            FixResolution = "CIP - Client Escalations", QaStatus = "Approved", PendingAgentRequests = 2
        };
        ArWorkbenchClientVisibility.Apply([row], new ArWorkbenchUserContext { RoleCode = "viewer" });

        Assert.Null(row.AssignedAgentUser);
        Assert.Null(row.AssignedAgentName);
        Assert.Null(row.FixResolution);
        Assert.Null(row.QaStatus);
        Assert.Equal(0, row.PendingAgentRequests);
        Assert.Equal("19524452", row.ClaimID);
    }

    [Fact]
    public void Internal_users_keep_the_claim_list_rows()
    {
        var row = new ArWorkbenchClaimRow { AssignedAgentUser = "ARAgent1", FixResolution = "Appealed" };
        ArWorkbenchClientVisibility.Apply([row], new ArWorkbenchUserContext { RoleCode = "lead" });

        Assert.Equal("ARAgent1", row.AssignedAgentUser);
        Assert.Equal("Appealed", row.FixResolution);
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
