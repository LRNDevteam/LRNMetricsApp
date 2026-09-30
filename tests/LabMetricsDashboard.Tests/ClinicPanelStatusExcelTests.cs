using System.Collections.Generic;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

public sealed class ClinicPanelStatusExcelTests
{
    [Fact]
    public void Panel_status_sheet_uses_client_pivot_layout_with_collapsed_panels()
    {
        var vm = new ClinicPanelStatusViewModel
        {
            SelectedLab = "RisingTides",
            Statuses = ["Fully Paid", "No Response", "Complete W/O"],
            Clinics =
            [
                new ClinicPanelStatusClinicRow
                {
                    ClinicName = "Advanced Urogynecology",
                    StatusCounts = new() { ["Fully Paid"] = 200, ["No Response"] = 124, ["Complete W/O"] = 107 },
                    GrandTotal = 431,
                    Panels =
                    [
                        new ClinicPanelStatusPanelRow
                        {
                            PanelName = "UTI Panel",
                            StatusCounts = new() { ["Fully Paid"] = 108, ["No Response"] = 66, ["Complete W/O"] = 67 },
                            GrandTotal = 241,
                        },
                        new ClinicPanelStatusPanelRow
                        {
                            PanelName = "STI Panel, UTI ABR Panel",
                            StatusCounts = new() { ["Fully Paid"] = 0, ["Complete W/O"] = 0 },
                            GrandTotal = 0,
                        },
                    ],
                },
            ],
            GrandTotals = new() { ["Fully Paid"] = 200, ["No Response"] = 124, ["Complete W/O"] = 107 },
            GrandTotalAll = 431,
        };

        using var wb = ClinicSummaryExcelExportBuilder.CreateWorkbook(
            [], null, [], [], [], [], [], [], [], [], "RisingTides", panelStatus: vm);

        var ws = wb.Worksheets.Worksheet("Clinic Panel Status");
        Assert.Equal("Clinic Name", ws.Cell(1, 1).GetString());
        Assert.Equal("Fully Paid", ws.Cell(1, 2).GetString());
        Assert.Equal("Grand Total", ws.Cell(1, 5).GetString());

        Assert.Equal("Advanced Urogynecology", ws.Cell(2, 1).GetString());
        Assert.Equal(200, ws.Cell(2, 2).GetValue<int>());
        Assert.True(ws.Cell(2, 1).Style.Font.Bold);

        Assert.Equal("UTI Panel", ws.Cell(3, 1).GetString());
        Assert.Equal(2, ws.Cell(3, 1).Style.Alignment.Indent);
        Assert.True(ws.Cell(4, 2).IsEmpty());

        Assert.Equal(1, ws.Row(3).OutlineLevel);
        Assert.Equal(1, ws.Row(4).OutlineLevel);
        Assert.True(ws.Row(3).IsHidden);
        Assert.Equal(0, ws.Row(2).OutlineLevel);

        Assert.Equal("Grand Total", ws.Cell(5, 1).GetString());
        Assert.Equal(431, ws.Cell(5, 5).GetValue<int>());
    }
}
