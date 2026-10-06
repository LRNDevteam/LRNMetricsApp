using System.Linq;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchCodeMasterTests
{
    private static Dictionary<string, ArWorkbenchCodeMasterRow> Existing(params ArWorkbenchCodeMasterRow[] rows)
        => rows.ToDictionary(r => r.DenialCode, StringComparer.OrdinalIgnoreCase);

    private static CodeMasterImportLine Line(int line, string code, params (CodeMasterColumn, string?)[] values)
        => new() { Sheet = "Sheet1", Line = line, Code = code, Values = values.ToDictionary(v => v.Item1, v => v.Item2) };

    // The business workbook's shape: headers on row 1, a categorization column, a separate
    // "Non-collectible Denials" sheet, and B7 listed twice.
    private static MemoryStream BusinessWorkbook()
    {
        using var wb = new XLWorkbook();
        var main = wb.Worksheets.Add("Denial Category Clasification");
        main.Cell(1, 1).Value = "Denial Code"; main.Cell(1, 2).Value = "Denial Code Description"; main.Cell(1, 3).Value = "Denial Categorization";
        object[][] data =
        [
            ["4", "Procedure code inconsistent with modifier", "Procedure Code, Modifier or Coding Related Issues"],
            ["B7", "Provider not certified (first)", "Billing, Rendering or Referring Provider Eligibility Related Issues"],
            ["197", "Precert/authorization/notification absent", "Missing Prior Authorization"],
            ["B7", "Provider not certified", "Billing, Rendering or Referring Provider Eligibility Related Issues"],
            ["B7 ", "#N/A", "Billing, Rendering or Referring Provider Eligibility Related Issues"],   // as in the real sheet
            ["852", "#N/A", "Other Denials - Remark or Payer Review Required"]
        ];
        for (var i = 0; i < data.Length; i++)
            for (var j = 0; j < 3; j++) main.Cell(i + 2, j + 1).Value = data[i][j].ToString();
        var nc = wb.Worksheets.Add("Non-collectible Denials");
        nc.Cell(1, 1).Value = "Denial Code"; nc.Cell(1, 2).Value = "Denial Code Description";
        nc.Cell(2, 1).Value = 197; nc.Cell(2, 2).Value = "Precert/authorization/notification absent";
        nc.Cell(3, 1).Value = 29; nc.Cell(3, 2).Value = "Filing time limit expired";
        var ms = new MemoryStream();
        wb.SaveAs(ms);
        ms.Position = 0;
        return ms;
    }

    [Fact]
    public void Business_workbook_imports_as_is()
    {
        var (parsed, error) = ArWorkbenchCodeMasterExcel.Parse(BusinessWorkbook());
        Assert.Null(error);
        Assert.Equal(6, parsed!.Rows.Count);
        Assert.Equal(2, parsed.NonCollectibleCodes!.Count);
        Assert.True(parsed.Rows[0].Has(CodeMasterColumn.ActionCategory));      // "Denial Categorization"
        Assert.False(parsed.Rows[0].Has(CodeMasterColumn.Coverage));           // not in the sheet -> left alone

        var merge = ArWorkbenchCodeMasterRules.Merge(Existing(), parsed);
        Assert.Empty(merge.Errors);
        Assert.Equal(2, merge.Warnings.Count);                                 // B7 three times
        var byCode = merge.Inserts.ToDictionary(r => r.DenialCode);
        Assert.Equal(["197", "29", "4", "852", "B7"], byCode.Keys.OrderBy(k => k));
        Assert.Equal("Provider not certified", byCode["B7"].DenialDescription);   // later non-blank row wins; #N/A does not clear it
        Assert.Null(byCode["852"].DenialDescription);                             // #N/A loads as blank
        Assert.True(byCode["197"].IsNonCollectible);
        Assert.True(byCode["29"].IsNonCollectible);                             // only on the NC sheet: added
        Assert.Equal("Filing time limit expired", byCode["29"].DenialDescription);
        Assert.False(byCode["4"].IsNonCollectible);
        Assert.Equal(2, merge.NonCollectibleCodes);
    }

    [Fact]
    public void Prefixed_codes_share_one_row()
    {
        var parsed = new ArWorkbenchCodeMasterParsed();
        parsed.Rows.Add(Line(2, "PR4", (CodeMasterColumn.Description, "first")));
        parsed.Rows.Add(Line(3, "CO-4", (CodeMasterColumn.Description, "second")));
        var merge = ArWorkbenchCodeMasterRules.Merge(Existing(), parsed);
        var row = Assert.Single(merge.Inserts);
        Assert.Equal("4", row.DenialCode);
        Assert.Equal("second", row.DenialDescription);
    }

    [Fact]
    public void Columns_missing_from_the_sheet_keep_their_values()
    {
        var current = new ArWorkbenchCodeMasterRow { DenialCode = "4", DenialDescription = "old", CoverageStatus = "Covered", IsActive = true };
        var parsed = new ArWorkbenchCodeMasterParsed();
        parsed.Rows.Add(Line(2, "4", (CodeMasterColumn.Description, "new")));
        var row = Assert.Single(ArWorkbenchCodeMasterRules.Merge(Existing(current), parsed).Updates);
        Assert.Equal("new", row.DenialDescription);
        Assert.Equal("Covered", row.CoverageStatus);
    }

    [Fact]
    public void Blank_cell_in_a_present_column_clears_the_value()
    {
        var current = new ArWorkbenchCodeMasterRow { DenialCode = "4", CoverageStatus = "Covered", IsActive = true };
        var parsed = new ArWorkbenchCodeMasterParsed();
        parsed.Rows.Add(Line(2, "4", (CodeMasterColumn.Coverage, null)));
        Assert.Null(Assert.Single(ArWorkbenchCodeMasterRules.Merge(Existing(current), parsed).Updates).CoverageStatus);
    }

    [Fact]
    public void Non_collectible_sheet_is_the_whole_list()
    {
        var oldFlag = new ArWorkbenchCodeMasterRow { DenialCode = "27", IsNonCollectible = true, IsActive = true };
        var parsed = new ArWorkbenchCodeMasterParsed { NonCollectibleSheet = "NC", NonCollectibleCodes = [(2, "197", null)] };
        var merge = ArWorkbenchCodeMasterRules.Merge(Existing(oldFlag), parsed);
        Assert.False(Assert.Single(merge.Updates).IsNonCollectible);           // 27 unflagged
        Assert.True(Assert.Single(merge.Inserts).IsNonCollectible);            // 197 added
    }

    [Fact]
    public void Without_a_non_collectible_sheet_flags_are_untouched()
    {
        var flagged = new ArWorkbenchCodeMasterRow { DenialCode = "27", DenialDescription = "x", IsNonCollectible = true, IsActive = true };
        var parsed = new ArWorkbenchCodeMasterParsed();
        parsed.Rows.Add(Line(2, "27", (CodeMasterColumn.Description, "x")));
        var merge = ArWorkbenchCodeMasterRules.Merge(Existing(flagged), parsed);
        Assert.Equal(1, merge.Unchanged);
        Assert.Empty(merge.Updates);
    }

    [Theory]
    [InlineData("", false)]
    [InlineData("Yes", true)]
    [InlineData("no", false)]
    public void Non_collectible_column_blank_means_no(string text, bool expected)
    {
        var parsed = new ArWorkbenchCodeMasterParsed();
        parsed.Rows.Add(Line(2, "4", (CodeMasterColumn.NonCollectible, text.Length == 0 ? null : text)));
        Assert.Equal(expected, Assert.Single(ArWorkbenchCodeMasterRules.Merge(Existing(), parsed).Inserts).IsNonCollectible);
    }

    [Fact]
    public void Bad_rows_are_errors()
    {
        var parsed = new ArWorkbenchCodeMasterParsed();
        parsed.Rows.Add(Line(2, "4,5"));
        parsed.Rows.Add(Line(3, "6", (CodeMasterColumn.NonCollectible, "maybe")));
        parsed.Rows.Add(Line(4, "7", (CodeMasterColumn.Description, new string('x', 1001))));
        Assert.Equal(3, ArWorkbenchCodeMasterRules.Merge(Existing(), parsed).Errors.Count);
    }

    [Fact]
    public void Unknown_mapper_values_warn_but_save()
    {
        var parsed = new ArWorkbenchCodeMasterParsed();
        parsed.Rows.Add(Line(2, "4", (CodeMasterColumn.Coverage, "Sometimes")));
        var known = new ArWorkbenchCodeMasterOptions { CoverageStatuses = ["Covered", "Not Covered"] };
        var merge = ArWorkbenchCodeMasterRules.Merge(Existing(), parsed, known);
        Assert.Single(merge.Warnings);
        Assert.Equal("Sometimes", Assert.Single(merge.Inserts).CoverageStatus);
    }

    [Fact]
    public void Export_round_trips()
    {
        var rows = new List<ArWorkbenchCodeMasterRow>
        {
            new() { DenialCode = "016", DenialDescription = "Lacks info", ActionCategory = "Claims Edits Related Issues", CoverageStatus = "Covered", IsNonCollectible = true, IsActive = true }
        };
        var bytes = ArWorkbenchCodeMasterExcel.Build(rows, new ArWorkbenchCodeMasterOptions());
        var (parsed, error) = ArWorkbenchCodeMasterExcel.Parse(new MemoryStream(bytes));
        Assert.Null(error);
        var line = Assert.Single(parsed!.Rows);                                 // the Lists sheet is skipped
        Assert.Equal("016", line.Code);
        var merge = ArWorkbenchCodeMasterRules.Merge(Existing(), parsed);
        var row = Assert.Single(merge.Inserts);
        Assert.Equal("016", row.DenialCode);
        Assert.True(row.IsNonCollectible);
        Assert.Equal("Covered", row.CoverageStatus);
    }

    [Fact]
    public void Lab_sync_plan()
    {
        var (add, off, same) = ArWorkbenchCodeMasterRules.PlanNonCollectibleSync(["197", "29", "242"], ["197", "27", "31"]);
        Assert.Equal(["29", "242"], add);
        Assert.Equal(["27", "31"], off);
        Assert.Equal(1, same);
    }
}
