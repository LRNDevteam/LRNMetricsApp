using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchMasterRulesTests
{
    private static ArWorkbenchMasterType Type(string key) => ArWorkbenchMasterRules.Find(key)!;

    private static ArWorkbenchMasterValidation Validate(string key, string? value, int? sortOrder = null) =>
        ArWorkbenchMasterRules.Validate(Type(key), new ArWorkbenchMasterValueSaveRequest { Value = value, SortOrder = sortOrder });

    [Fact]
    public void Catalogue_keys_are_the_seeded_list_types()
    {
        // Keys are rows in dbo.ARWB_MasterListItem (03_ARWB_MasterData_Seed.sql); renaming one orphans its values.
        Assert.Equal(
            ["NON_COLLECTIBLE_CODE", "AUTO_ADJUST_CODE", "DENIAL_CATEGORY", "PANEL_TYPE", "DENIAL_ROOT_CAUSE", "FIX_RESOLUTION", "CLAIM_STATUS",
             "FOLLOW_UP_TYPE", "CLAIM_TYPE", "CIP_CATEGORY", "CIP_REQUIRED_INFO", "ESCALATION_REASON", "REASSIGNMENT_REASON", "DOCUMENT_CATEGORY"],
            ArWorkbenchMasterRules.Types.Select(t => t.Key));
        Assert.Equal(2, ArWorkbenchMasterRules.Types.Count(t => t.IsCodeList));
    }

    [Theory]
    [InlineData("denial_category", "DENIAL_CATEGORY")]
    [InlineData(" FIX_RESOLUTION ", "FIX_RESOLUTION")]
    public void Find_ignores_case_and_padding(string input, string expected) =>
        Assert.Equal(expected, ArWorkbenchMasterRules.Find(input)?.Key);

    [Theory]
    [InlineData("WORKFLOW_STATUS")] // system list: the queue engine depends on its exact values
    [InlineData("AGING_BUCKET")]
    [InlineData(null)]
    public void Find_does_not_expose_system_lists(string? input) =>
        Assert.Null(ArWorkbenchMasterRules.Find(input));

    [Theory]
    [InlineData("PR 204", "204")]
    [InlineData("CO-204", "204")]
    [InlineData("co204", "204")]
    [InlineData("OA:23", "23")]
    [InlineData("N57", "N57")]
    [InlineData("MA130", "MA130")]
    [InlineData("CO", "CO")]      // a bare two-letter value is not a prefix
    [InlineData(" 16 ", "16")]
    public void NormalizeDenialCode_matches_the_sql_function(string raw, string expected) =>
        Assert.Equal(expected, ArWorkbenchMasterRules.NormalizeDenialCode(raw));

    [Theory]
    [InlineData(null)]
    [InlineData("  ")]
    [InlineData("null")]
    public void NormalizeDenialCode_is_null_for_blank(string? raw) =>
        Assert.Null(ArWorkbenchMasterRules.NormalizeDenialCode(raw));

    [Theory]
    [InlineData("CO-16, CO-45")]
    [InlineData("16;45")]
    [InlineData("16/45")]
    public void DenialCodeError_rejects_code_lists(string raw) =>
        Assert.Contains("more than one code", ArWorkbenchMasterRules.DenialCodeError(raw));

    [Fact]
    public void Code_list_values_are_stored_normalized_and_compared_as_codes()
    {
        var result = Validate("NON_COLLECTIBLE_CODE", "CO-197");
        Assert.Null(result.Error);
        Assert.Equal("197", result.Result!.Value);

        var type = Type("NON_COLLECTIBLE_CODE");
        Assert.Equal(ArWorkbenchMasterRules.Normalize(type, "PR 197"), ArWorkbenchMasterRules.Normalize(type, "197"));
    }

    [Theory]
    [InlineData("Write Off", "Write-Off")]
    [InlineData("Medical Records / Notes", "medical records notes")]
    public void Text_values_ignore_spacing_hyphens_and_slashes(string a, string b)
    {
        var type = Type("FIX_RESOLUTION");
        Assert.Equal(ArWorkbenchMasterRules.Normalize(type, a), ArWorkbenchMasterRules.Normalize(type, b));
    }

    [Fact]
    public void Validate_rejects_blank_too_long_control_characters_and_bad_sort()
    {
        Assert.NotNull(Validate("FOLLOW_UP_TYPE", "  ").Error);
        Assert.NotNull(Validate("FOLLOW_UP_TYPE", new string('x', 51)).Error); // ARWB_ClaimFollowUp.FollowUpType is nvarchar(50)
        Assert.NotNull(Validate("FOLLOW_UP_TYPE", "Call\nback").Error);
        Assert.NotNull(Validate("FOLLOW_UP_TYPE", "Call", sortOrder: -1).Error);
        Assert.Equal("Call", Validate("FOLLOW_UP_TYPE", "  Call ").Result!.Value);
    }

    [Theory]
    [InlineData("DENIAL_CATEGORY", "other")]
    [InlineData("FIX_RESOLUTION", "CIP - Client Escalations")]
    [InlineData("FIX_RESOLUTION", "Write Off")]
    [InlineData("CLAIM_STATUS", "Denied")]
    public void Values_the_workbench_rules_depend_on_are_reserved(string key, string value) =>
        Assert.True(ArWorkbenchMasterRules.IsReserved(Type(key), value));

    [Fact]
    public void ValidateDenialCode_normalizes_and_trims()
    {
        var result = ArWorkbenchMasterRules.ValidateDenialCode(new ArWorkbenchDenialCodeSaveRequest
        {
            DenialCode = "CO-16", DenialCategory = "  Timely Filing ", DenialReason = "   ", IsActive = true
        });
        Assert.Null(result.Error);
        Assert.Equal("16", result.Result!.DenialCode);
        Assert.Equal("Timely Filing", result.Result.DenialCategory);
        Assert.Null(result.Result.DenialReason);
    }

    [Fact]
    public void ValidateDenialCode_requires_a_category() =>
        Assert.NotNull(ArWorkbenchMasterRules.ValidateDenialCode(new ArWorkbenchDenialCodeSaveRequest { DenialCode = "16" }).Error);

    [Theory]
    [InlineData("", true)]
    [InlineData("yes", true)]
    [InlineData("Inactive", false)]
    [InlineData("0", false)]
    [InlineData("maybe", null)]
    public void ParseActive_reads_the_import_column(string text, bool? expected) =>
        Assert.Equal(expected, ArWorkbenchMasterRules.ParseActive(text));

    [Fact]
    public void Exported_workbook_parses_back_to_the_same_rows()
    {
        var rows = new List<ArWorkbenchDenialCodeRow>
        {
            new() { DenialCode = "16", DenialCategory = "Additional Documentation Required", DenialReason = "Missing info", IsActive = true, ClaimCount = 4 },
            new() { DenialCode = "N57", DenialCategory = "Other", IsActive = false }
        };
        var bytes = ArWorkbenchDenialCodeExcel.BuildExport(rows, ["Additional Documentation Required", "Other"]);

        var (parsed, skipped, error) = ArWorkbenchDenialCodeExcel.Parse(new MemoryStream(bytes));
        Assert.Null(error);
        Assert.Equal(0, skipped);
        Assert.Collection(parsed,
            r => { Assert.Equal(3, r.RowNumber); Assert.Equal("16", r.DenialCode); Assert.Equal("Additional Documentation Required", r.DenialCategory); Assert.Equal("Missing info", r.DenialReason); Assert.Equal("Yes", r.Active); },
            r => { Assert.Equal("N57", r.DenialCode); Assert.Null(r.DenialReason); Assert.Equal("No", r.Active); });
    }

    [Fact]
    public void Template_parses_to_its_sample_row()
    {
        var (parsed, _, error) = ArWorkbenchDenialCodeExcel.Parse(new MemoryStream(ArWorkbenchDenialCodeExcel.BuildTemplate(["Timely Filing"])));
        Assert.Null(error);
        Assert.Equal("CO-16", Assert.Single(parsed).DenialCode);
    }

    [Fact]
    public void Batch_criteria_clean_trims_dedupes_and_survives_null_lists()
    {
        var clean = new ArWorkbenchBatchCriteria { Category = null!, Payer = [" Aetna ", "aetna", "", "Cigna"], Priority = ["High"] }.Clean();
        Assert.Empty(clean.Category);
        Assert.Equal(["Aetna", "Cigna"], clean.Payer);
        Assert.False(clean.IsEmpty);
        Assert.True(new ArWorkbenchBatchCriteria().Clean().IsEmpty);
        Assert.False(new ArWorkbenchBatchCriteria { TflRiskOnly = true }.IsEmpty);
    }

    [Fact]
    public void Batch_criteria_summary_names_single_values_and_counts_the_rest()
    {
        Assert.Equal("All unassigned", SqlArWorkbenchRepository.CriteriaSummary(new ArWorkbenchBatchCriteria()));
        Assert.Equal("Medical Necessity · 2 payers · High · TFL at risk", SqlArWorkbenchRepository.CriteriaSummary(new ArWorkbenchBatchCriteria
        {
            Category = ["Medical Necessity"], Payer = ["Aetna", "Cigna"], Priority = ["High"], TflRiskOnly = true
        }));
        Assert.Equal("no category", SqlArWorkbenchRepository.CriteriaSummary(new ArWorkbenchBatchCriteria { Category = [ArWorkbenchFilterValues.None] }));
    }

    [Fact]
    public void Parse_rejects_a_workbook_with_other_headers()
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add(ArWorkbenchDenialCodeExcel.SheetName);
        sheet.Cell(2, 1).Value = "Code";
        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        stream.Position = 0;

        Assert.NotNull(ArWorkbenchDenialCodeExcel.Parse(stream).Error);
    }
}
