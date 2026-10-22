using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>FR-SET-01 / DEF-28: Workbench Lists CSV template round trip and bulk replace.</summary>
public class ArWorkbenchMasterListCsvTests
{
    private static ArWorkbenchMasterType Type(string key) => ArWorkbenchMasterRules.Find(key)!;
    private static ArWorkbenchMasterValidated V(string value, int sort = 10, bool active = true) => new(value, sort, active);

    [Fact]
    public void Template_round_trips_through_parse()
    {
        var csv = ArWorkbenchMasterListCsv.Template([
            new ArWorkbenchMasterValue { Value = "197", SortOrder = 10, IsActive = true },
            new ArWorkbenchMasterValue { Value = "242", SortOrder = 20, IsActive = false }
        ]);
        var (rows, errors) = ArWorkbenchMasterListCsv.Parse(Type("NON_COLLECTIBLE_CODE"), csv);
        Assert.Empty(errors);
        Assert.Equal([V("197", 10), V("242", 20, false)], rows);
    }

    [Fact]
    public void Parse_normalizes_codes_and_reports_every_bad_row()
    {
        var (rows, errors) = ArWorkbenchMasterListCsv.Parse(Type("NON_COLLECTIBLE_CODE"),
            "Value,Sort Order,Active\nCO-197,,\nPR 197,,\n29,x,\n204,,maybe\n119;204,,\n");
        Assert.Equal(["197"], rows.Select(r => r.Value));
        Assert.Equal(4, errors.Count);
        Assert.Contains(errors, e => e.StartsWith("Row 3:") && e.Contains("already on row 2"));
        Assert.Contains(errors, e => e.StartsWith("Row 4:") && e.Contains("Sort Order"));
        Assert.Contains(errors, e => e.StartsWith("Row 5:") && e.Contains("Active"));
        Assert.Contains(errors, e => e.StartsWith("Row 6:") && e.Contains("more than one code"));
    }

    [Fact]
    public void Parse_rejects_a_file_without_the_value_header_or_rows()
    {
        Assert.NotEmpty(ArWorkbenchMasterListCsv.Parse(Type("ESCALATION_REASON"), "Code,Active\nX,Yes").Errors);
        Assert.NotEmpty(ArWorkbenchMasterListCsv.Parse(Type("ESCALATION_REASON"), "Value,Sort Order,Active\n").Errors);
        Assert.NotEmpty(ArWorkbenchMasterListCsv.Parse(Type("ESCALATION_REASON"), "").Errors);
    }

    [Fact]
    public void Parse_strips_the_csv_injection_guard()
    {
        var (rows, errors) = ArWorkbenchMasterListCsv.Parse(Type("ESCALATION_REASON"), "Value\n'-Other reason\n");
        Assert.Empty(errors);
        Assert.Equal("-Other reason", Assert.Single(rows).Value);
    }

    [Fact]
    public void Plan_adds_updates_and_deactivates_what_the_file_leaves_out()
    {
        var plan = ArWorkbenchMasterListCsv.Plan(Type("NON_COLLECTIBLE_CODE"),
            [V("197", 10), V("242", 20), V("29", 30, false)],
            [V("197", 10), V("29", 30), V("204", 40)]);
        Assert.Null(plan.Error);
        Assert.Equal(["204"], plan.Adds.Select(a => a.Value));
        Assert.Equal([V("29", 30, true)], plan.Updates);
        Assert.Equal(["242"], plan.Deactivations);
        Assert.True(plan.HasChanges);
    }

    [Fact]
    public void Plan_matches_by_duplicate_key_and_never_renames()
    {
        var plan = ArWorkbenchMasterListCsv.Plan(Type("ESCALATION_REASON"), [V("Payer Issue", 10)], [V("Payer-Issue", 10)]);
        Assert.False(plan.HasChanges);
    }

    [Fact]
    public void Plan_keeps_reserved_values_active_and_one_active_value()
    {
        var fix = Type("FIX_RESOLUTION");
        var plan = ArWorkbenchMasterListCsv.Plan(fix, [V("Write Off", 10), V("Appealed", 20)], [V("Appealed", 20)]);
        Assert.Empty(plan.Deactivations);
        Assert.Equal(["Write Off"], plan.KeptReserved);

        var none = ArWorkbenchMasterListCsv.Plan(Type("ESCALATION_REASON"), [V("A", 10)], [V("A", 10, false)]);
        Assert.NotNull(none.Error);
    }
}
