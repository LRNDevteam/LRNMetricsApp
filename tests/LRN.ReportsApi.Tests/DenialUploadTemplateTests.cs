using System.Collections.Generic;
using LRN.ReportsApi.Controllers;
using LRN.ReportsApi.Services;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Upload-template column selection and upload row classification (Round 1 UAT Bugs 1 & 2).
/// </summary>
public class DenialUploadTemplateTests
{
    // Bug 1: EscalationResponse / EscalationResponseComment are AR-Manager-only columns.
    [Theory]
    [InlineData("AR Manager", true)]
    [InlineData("Admin", true)]
    [InlineData("AR Reviewer", false)]
    [InlineData("AR Analyst", false)]
    [InlineData("Client Manager", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void EditableHeaders_include_escalation_response_only_for_managers(string? role, bool shouldInclude)
    {
        var headers = SqlDenialWorkflowRepository.BuildUploadTemplateEditableHeaders(role);
        Assert.Equal(shouldInclude, headers.Contains("EscalationResponse"));
        Assert.Equal(shouldInclude, headers.Contains("EscalationResponseComment"));
    }

    [Theory]
    [InlineData("AR Reviewer")]
    [InlineData("AR Manager")]
    public void EditableHeaders_always_include_the_reviewer_action_columns(string role)
    {
        var headers = SqlDenialWorkflowRepository.BuildUploadTemplateEditableHeaders(role);
        Assert.Contains("UpdateStatus", headers);
        Assert.Contains("Comments", headers);
        Assert.Contains("Notes", headers);          // editable Notes input, present for everyone
        Assert.Contains("EscalationReason", headers);
    }

    [Fact]
    public void EditableHeaders_keep_Notes_last_so_column_order_is_stable()
    {
        var reviewer = SqlDenialWorkflowRepository.BuildUploadTemplateEditableHeaders("AR Reviewer");
        var manager = SqlDenialWorkflowRepository.BuildUploadTemplateEditableHeaders("AR Manager");
        Assert.Equal("Notes", reviewer[^1]);
        Assert.Equal("Notes", manager[^1]);
        // Manager gets exactly the two extra escalation-response columns.
        Assert.Equal(reviewer.Length + 2, manager.Length);
    }

    // Bug 2 safety: NotesHistory is a read-only reference column. It must NOT make a row "actionable"
    // on re-upload (which would re-import the concatenated history), while the editable Notes column must.
    private static Dictionary<string, string> Row(params (string key, string value)[] cells)
    {
        var row = new Dictionary<string, string>(System.StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in cells) row[key] = value;
        return row;
    }

    [Fact]
    public void NotesHistory_alone_is_not_an_actionable_row()
        => Assert.False(DenialWorkflowController.CsvHasClaimAction(Row(("NotesHistory", "[2026-07-08] prior note"))));

    [Fact]
    public void Editable_Notes_makes_a_row_actionable()
        => Assert.True(DenialWorkflowController.CsvHasClaimAction(Row(("Notes", "please follow up"))));

    [Theory]
    [InlineData("UpdateStatus", "Closed")]
    [InlineData("Comments", "done")]
    [InlineData("EscalationReason", "Denial reason unclear")]
    [InlineData("EscalationResponse", "Proceed with Appeal")]
    public void Known_action_columns_make_a_row_actionable(string key, string value)
        => Assert.True(DenialWorkflowController.CsvHasClaimAction(Row((key, value))));

    [Fact]
    public void Empty_or_read_only_only_row_is_not_actionable()
        => Assert.False(DenialWorkflowController.CsvHasClaimAction(Row(("ClaimID", "450561"), ("CurrentStatus", "Closed"), ("NotesHistory", "x"))));
}
