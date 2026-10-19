// This test project does not enable ImplicitUsings, so the BCL namespaces are spelled out.
using System.Linq;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// NorthWest's Denial Summary download carries the page's Panel vs Payer, Facility wise and
/// Denial vs Facility % tabs, with child rows grouped under their parent row.
/// </summary>
public sealed class DenialClaimReportNorthWestSheetsTests
{
    private static DenialClaimReportViewModel BuildModel() => new()
    {
        CurrentLab = "NorthWest",
        HasDenialLists = true,
        HasDenialFacilityTabs = true,
        PayorVsPayer =
        [
            new("P", "PAYER A", "", "Commercial", "", 1, 0, 5, 500m, 1),
            new("P", "PAYER A", "", "Commercial", "Blood", 1, 0, 2, 200m, 1),
            new("P", "PAYER A", "", "Commercial", "Toxicology", 1, 0, 3, 300m, 1),
            new("C", "PAYER A", "197", "Commercial", "", 1, 1, 5, 500m, 2),
            new("C", "PAYER A", "197", "Commercial", "Blood", 1, 1, 2, 200m, 2),
            new("C", "PAYER A", "197", "Commercial", "Toxicology", 1, 1, 3, 300m, 2),
            new("T", "Grand Total", "", "", "", 0, 0, 5, 500m, 3),
            new("T", "Grand Total", "", "", "Blood", 0, 0, 2, 200m, 3),
            new("T", "Grand Total", "", "", "Toxicology", 0, 0, 3, 300m, 3),
        ],
        FacilityDenial =
        [
            new("F", "Clinic 1", "", 1, 0, 5, 500m, 1),
            new("D", "Clinic 1", "197", 1, 1, 5, 500m, 2),
            new("T", "Grand Total", "", 0, 0, 5, 500m, 3),
        ],
        FacilityPct =
        [
            new("F", "Clinic 1", 1, 10, 8, 2, 0.25m, 1),
            new("T", "Grand Total", 0, 10, 8, 2, 0.25m, 2),
        ],
    };

    [Fact]
    public void NorthWest_workbook_has_the_facility_tabs()
    {
        using var wb = DenialClaimReportExcelBuilder.Build(BuildModel());
        var names = wb.Worksheets.Select(w => w.Name).ToArray();

        Assert.Contains("Panel vs Payer", names);
        Assert.Contains("Facility wise Denial", names);
        Assert.Contains("Denial vs Facility %", names);
    }

    [Fact]
    public void Panel_vs_Payer_has_panel_columns_by_claim_count_and_grouped_denial_codes()
    {
        using var wb = DenialClaimReportExcelBuilder.Build(BuildModel());
        var ws = wb.Worksheet("Panel vs Payer");

        // Panels ordered by grand-total claim count, then the Grand Total pair.
        Assert.Equal("Toxicology", ws.Cell(4, 2).GetString());
        Assert.Equal("Blood", ws.Cell(4, 4).GetString());
        Assert.Equal("Grand Total", ws.Cell(4, 6).GetString());

        Assert.Equal("PAYER A", ws.Cell(6, 1).GetString());
        Assert.Equal(0, ws.Row(6).OutlineLevel);
        Assert.Equal(3, ws.Cell(6, 2).GetValue<int>());
        Assert.Equal(5, ws.Cell(6, 6).GetValue<int>());

        Assert.Equal("197", ws.Cell(7, 1).GetString());
        Assert.Equal(1, ws.Row(7).OutlineLevel);

        Assert.Equal("Grand Total", ws.Cell(8, 1).GetString());
        Assert.Equal(500m, ws.Cell(8, 7).GetValue<decimal>());
    }

    [Fact]
    public void Facility_sheets_carry_the_page_values()
    {
        using var wb = DenialClaimReportExcelBuilder.Build(BuildModel());

        var fac = wb.Worksheet("Facility wise Denial");
        Assert.Equal("Clinic 1", fac.Cell(5, 1).GetString());
        Assert.Equal("197", fac.Cell(6, 1).GetString());
        Assert.Equal(1, fac.Row(6).OutlineLevel);

        var pct = wb.Worksheet("Denial vs Facility %");
        Assert.Equal("Clinic 1", pct.Cell(5, 1).GetString());
        Assert.Equal(10, pct.Cell(5, 2).GetValue<int>());
        Assert.Equal(0.25m, pct.Cell(5, 5).GetValue<decimal>());
        Assert.Equal("Grand Total", pct.Cell(6, 1).GetString());
    }
}
