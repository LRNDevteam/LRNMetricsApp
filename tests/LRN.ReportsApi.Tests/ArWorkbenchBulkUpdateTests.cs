using System.Linq;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchBulkUpdateTests
{
    private static readonly List<ArWorkbenchAgent> Agents =
    [
        new() { UserName = "jdoe", DisplayName = "Jane Doe", IsAssignable = true },
        new() { UserName = "old.agent", DisplayName = "Old Agent", IsAssignable = false }
    ];

    private static readonly Dictionary<string, List<string>> Lists = new()
    {
        ["CLAIM_STATUS"] = ["Denied", "In Process"],
        ["FIX_RESOLUTION"] = ["Appealed", "CIP - Client Escalations"],
        ["CLAIM_TYPE"] = ["Primary"],
        ["FOLLOW_UP_TYPE"] = ["Call"]
    };

    private static ArWorkbenchBulkClaimState Claim(long version = 10) =>
        new() { ClaimKey = 1, ClaimId = "C1", WorkflowStatus = "Assigned", AssignedAgentUser = "someone", Version = version, LastActivityBy = "qa1" };

    [Fact]
    public void Template_round_trips_with_dropdowns_and_version()
    {
        var claims = new List<ArWorkbenchClaimRow> { new() { ClaimKey = 1, ClaimID = "00123", PayerName = "Aetna", WorkflowStatus = "Assigned" } };
        var bytes = ArWorkbenchBulkUpdate.BuildTemplate(claims, new Dictionary<long, long> { [1] = 42 }, Lists, Agents, "t");

        using var wb = new XLWorkbook(new MemoryStream(bytes));
        var sheet = wb.Worksheet(ArWorkbenchBulkUpdate.SheetName);
        Assert.True(sheet.DataValidations.Count() >= 4);                      // agents, status, fix, ... + date
        Assert.Equal("Jane Doe (jdoe)", wb.Worksheet("Lists").Cell(2, 1).GetString());   // only assignable agents
        Assert.Equal("", wb.Worksheet("Lists").Cell(3, 1).GetString());

        // Fill the editable columns as a user would, then parse.
        int Col(string h) => sheet.Row(2).CellsUsed().First(c => c.GetString() == h).Address.ColumnNumber;
        sheet.Cell(3, Col("Assign To")).Value = "Jane Doe (jdoe)";
        sheet.Cell(3, Col("Claim Status")).Value = "Denied";
        sheet.Cell(3, Col("Next Follow-Up Date")).Value = new DateTime(2030, 1, 15);
        var ms = new MemoryStream();
        wb.SaveAs(ms);
        ms.Position = 0;

        var (rows, error) = ArWorkbenchBulkUpdate.Parse(ms);
        Assert.Null(error);
        var row = Assert.Single(rows!);
        Assert.Equal("00123", row.ClaimId);                                   // text, leading zeros kept
        Assert.Equal(42, row.Version);
        Assert.Equal("Jane Doe (jdoe)", row.AssignTo);
        Assert.Equal(new DateTime(2030, 1, 15), row.NextFollowUpDate);
        Assert.True(row.HasFollowUp);
    }

    [Fact]
    public void Blank_template_parses_to_no_rows()
    {
        var bytes = ArWorkbenchBulkUpdate.BuildTemplate([], new Dictionary<long, long>(), Lists, Agents, "t");
        var (rows, error) = ArWorkbenchBulkUpdate.Parse(new MemoryStream(bytes));
        Assert.Null(error);
        Assert.Empty(rows!);
    }

    [Fact]
    public void A_file_without_update_columns_is_rejected()
    {
        using var wb = new XLWorkbook();
        var s = wb.Worksheets.Add("x");
        s.Cell(1, 1).Value = "Claim ID";
        s.Cell(2, 1).Value = "C1";
        var ms = new MemoryStream();
        wb.SaveAs(ms);
        ms.Position = 0;
        Assert.NotNull(ArWorkbenchBulkUpdate.Parse(ms).Error);
    }

    [Theory]
    [InlineData("Jane Doe (jdoe)", "jdoe")]
    [InlineData("jdoe", "jdoe")]
    [InlineData("JANE DOE", "jdoe")]
    [InlineData("nobody", null)]
    public void Agent_is_matched_by_label_username_or_name(string text, string? expected)
        => Assert.Equal(expected, ArWorkbenchBulkUpdate.ResolveAgent(text, Agents)?.UserName);

    [Fact]
    public void Worked_since_download_is_a_conflict()
    {
        var row = new ArWorkbenchBulkRow { ClaimId = "C1", Version = 9, AssignTo = "jdoe" };
        var (error, _, _) = ArWorkbenchBulkUpdate.Check(row, Claim(version: 10), canAssign: true, canEditClaim: true, Agents);
        Assert.Contains("Changed after this file was downloaded", error);
        Assert.Contains("qa1", error);
    }

    [Fact]
    public void Same_version_passes()
    {
        var row = new ArWorkbenchBulkRow { ClaimId = "C1", Version = 10, AssignTo = "jdoe" };
        var (error, skip, agent) = ArWorkbenchBulkUpdate.Check(row, Claim(10), true, true, Agents);
        Assert.Null(error);
        Assert.Null(skip);
        Assert.Equal("jdoe", agent!.UserName);
    }

    [Fact]
    public void Row_without_changes_is_skipped_not_failed()
    {
        var (error, skip, _) = ArWorkbenchBulkUpdate.Check(new ArWorkbenchBulkRow { ClaimId = "C1" }, Claim(), true, true, Agents);
        Assert.Null(error);
        Assert.NotNull(skip);
    }

    [Fact]
    public void Unknown_claim_fails()
        => Assert.Contains("not found", ArWorkbenchBulkUpdate.Check(new ArWorkbenchBulkRow { ClaimId = "X", AssignTo = "jdoe" }, null, true, true, Agents).Error);

    [Fact]
    public void Agent_role_cannot_bulk_assign()
        => Assert.Contains("cannot assign", ArWorkbenchBulkUpdate.Check(new ArWorkbenchBulkRow { ClaimId = "C1", AssignTo = "jdoe" }, Claim(), canAssign: false, canEditClaim: true, Agents).Error);

    [Fact]
    public void Viewer_cannot_log_notes()
        => Assert.Contains("cannot log", ArWorkbenchBulkUpdate.Check(new ArWorkbenchBulkRow { ClaimId = "C1", ClaimStatus = "Denied" }, Claim(), true, canEditClaim: false, Agents).Error);

    [Fact]
    public void Unassignable_agent_fails()
        => Assert.NotNull(ArWorkbenchBulkUpdate.Check(new ArWorkbenchBulkRow { ClaimId = "C1", AssignTo = "old.agent" }, Claim(), true, true, Agents).Error);

    [Fact]
    public void Bad_date_text_fails_the_row()
        => Assert.Contains("not a date", ArWorkbenchBulkUpdate.Check(new ArWorkbenchBulkRow { ClaimId = "C1", NextFollowUpDateError = "soon" }, Claim(), true, true, Agents).Error);
}
