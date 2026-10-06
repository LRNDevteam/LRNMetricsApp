using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchFollowUpRulesTests
{
    private static readonly DateTime Today = new(2026, 10, 6);

    private static readonly Dictionary<string, List<string>> Lists = new(StringComparer.OrdinalIgnoreCase)
    {
        ["CLAIM_TYPE"] = ["Primary", "Secondary"],
        ["FOLLOW_UP_TYPE"] = ["Review", "Online", "Call"],
        ["CLAIM_STATUS"] = ["Paid", "Denied", "In Process"],
        ["DENIAL_ROOT_CAUSE"] = ["Bundling", "Missing Prior Authorization"],
        ["FIX_RESOLUTION"] = ["Appealed", "Awaiting EOB", "CIP - Client Escalations", "Write Off"],
        ["CIP_CATEGORY"] = ["Documents", "Insurance"],
        ["CIP_REQUIRED_INFO"] = ["Patient call required"]
    };

    private static ArWorkbenchFollowUpRequest Note(Action<ArWorkbenchFollowUpRequest>? change = null)
    {
        var q = new ArWorkbenchFollowUpRequest
        {
            ClaimType = "Primary", FollowUpType = "Call", ClaimStatus = "In Process", FixResolution = "Awaiting EOB",
            Comment = "Called payer; claim in process.", NextFollowUpDate = Today.AddDays(7)
        };
        change?.Invoke(q);
        return q;
    }

    private static ArWorkbenchFollowUpValidation Validate(ArWorkbenchFollowUpRequest q, params string[] fixesForStatus) =>
        ArWorkbenchFollowUpRules.Validate(q, Lists, fixesForStatus, Today);

    [Fact]
    public void A_complete_note_is_accepted_in_the_lists_own_spelling()
    {
        var v = Validate(Note(q => { q.ClaimType = " primary "; q.FixResolution = "awaiting eob"; }));
        Assert.Null(v.Error);
        Assert.Equal("Primary", v.Note!.ClaimType);
        Assert.Equal("Awaiting EOB", v.Note.FixResolution);
        Assert.Null(v.Note.DenialRootCause);
    }

    [Fact]
    public void Denied_requires_a_root_cause_and_only_Denied_keeps_one()
    {
        Assert.NotNull(Validate(Note(q => q.ClaimStatus = "Denied")).Error);
        var ok = Validate(Note(q => { q.ClaimStatus = "Denied"; q.DenialRootCause = "Bundling"; q.FixResolution = "Appealed"; }));
        Assert.Equal("Bundling", ok.Note!.DenialRootCause);
        Assert.Null(Validate(Note(q => q.DenialRootCause = "Bundling")).Note!.DenialRootCause);
    }

    [Fact]
    public void Fix_must_be_allowed_for_the_status_when_the_status_has_rules()
    {
        Assert.NotNull(Validate(Note(), "Appealed").Error);
        Assert.Null(Validate(Note(), "Awaiting EOB", "Appealed").Error);
        Assert.Null(Validate(Note()).Error); // no rules for the status: any active fix
    }

    [Fact]
    public void Cip_resolution_requires_category_required_info_and_comment()
    {
        Assert.NotNull(Validate(Note(q => q.FixResolution = "CIP - Client Escalations")).Error);
        var ok = Validate(Note(q =>
        {
            q.FixResolution = "CIP - Client Escalations";
            q.CipCategory = "Documents"; q.CipRequiredInfo = "Patient call required"; q.CipComment = "Please send the requisition.";
        }));
        Assert.Null(ok.Error);
        Assert.Equal("Documents", ok.Note!.CipCategory);
    }

    [Fact]
    public void Comment_values_and_dates_are_checked()
    {
        Assert.NotNull(Validate(Note(q => q.Comment = "  ")).Error);
        Assert.NotNull(Validate(Note(q => q.FollowUpType = "Fax")).Error);
        Assert.NotNull(Validate(Note(q => q.NextFollowUpDate = Today.AddDays(-5))).Error);
        Assert.NotNull(Validate(Note(q => q.NextFollowUpDate = Today.AddYears(3))).Error);
        Assert.Null(Validate(Note(q => q.NextFollowUpDate = null)).Note!.NextFollowUpDate);
    }
}
