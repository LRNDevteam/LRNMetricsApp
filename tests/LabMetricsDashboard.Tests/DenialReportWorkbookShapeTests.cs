// This test project does not enable ImplicitUsings, so the BCL namespaces are spelled out.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// Locks the Denial Report workbook to the shape of the client template
/// (Template/01. Cove Dx_Denial Report_*.xlsx): two sheets, with the report header block, the
/// monthly pivot, the weekly pivot and Key Observations all on "Denial Insights", in that order.
///
/// These are structural assertions on purpose. The thing that broke before was the workbook
/// quietly drifting away from the deliverable the client actually reads, and that is not
/// something a compile catches.
/// </summary>
public sealed class DenialReportWorkbookShapeTests
{
    private static DenialDashboardExportData BuildSampleData()
    {
        var monthly = new BreakdownPivotViewModel
        {
            HeaderTitle = "All Months | Top 2 Payers | Covering 80.0% of the AR | Denial Posted Date",
            SectionTitle = "Monthly Summary",
            GrandTotalTitle = "Grand Total",
            TopPayerCount = 2,
            CoveragePercentage = 80m,
            ColumnGroups =
            {
                new BreakdownPivotColumnGroup { Label = "2025", ColumnSpan = 4 },
                new BreakdownPivotColumnGroup { Label = "2026", ColumnSpan = 4 }
            },
            Periods =
            {
                new BreakdownPivotPeriod { Key = "2025-11", Label = "Nov", Year = 2025, Month = 11, StartDate = new DateTime(2025, 11, 1), EndDate = new DateTime(2025, 11, 30) },
                new BreakdownPivotPeriod { Key = "2025-T",  Label = "2025 | Total", Year = 2025, IsYearTotal = true, StartDate = new DateTime(2025, 1, 1), EndDate = new DateTime(2025, 12, 31) },
                new BreakdownPivotPeriod { Key = "2026-01", Label = "Jan", Year = 2026, Month = 1, StartDate = new DateTime(2026, 1, 1), EndDate = new DateTime(2026, 1, 31) },
                new BreakdownPivotPeriod { Key = "2026-T",  Label = "2026 | Total", Year = 2026, IsYearTotal = true, StartDate = new DateTime(2026, 1, 1), EndDate = new DateTime(2026, 12, 31) }
            },
            Rows =
            {
                new BreakdownPivotRow
                {
                    IndexLabel = "A", Label = "HUMANA", IsInsuranceRow = true,
                    Cells = { new() { ClaimCount = 0, DenialBalance = 0m }, new() { ClaimCount = 1, DenialBalance = 420m }, new() { ClaimCount = 6, DenialBalance = 2800m }, new() { ClaimCount = 7, DenialBalance = 3220m } },
                    TotalClaimCount = 8, TotalBalance = 3640m
                },
                new BreakdownPivotRow
                {
                    IndexLabel = "1", Label = "M127 - Missing patient medical record", IsInsuranceRow = false,
                    Cells = { new() { ClaimCount = 0, DenialBalance = 0m }, new() { ClaimCount = 0, DenialBalance = 0m }, new() { ClaimCount = 6, DenialBalance = 2800m }, new() { ClaimCount = 6, DenialBalance = 2800m } },
                    TotalClaimCount = 6, TotalBalance = 2800m
                }
            },
            TotalsByPeriod =
            {
                new BreakdownPivotCell { ClaimCount = 0, DenialBalance = 0m },
                new BreakdownPivotCell { ClaimCount = 1, DenialBalance = 420m },
                new BreakdownPivotCell { ClaimCount = 6, DenialBalance = 2800m },
                new BreakdownPivotCell { ClaimCount = 7, DenialBalance = 3220m }
            },
            GrandTotalClaimCount = 8,
            GrandTotalBalance = 3640m
        };

        var weekly = new BreakdownPivotViewModel
        {
            HeaderTitle = "Last 4 Weeks | Top 2 Payers | Covering 80.0% of the AR | Denial Posted Date",
            SectionTitle = "Weekly Breakdown",
            GrandTotalTitle = "Grand Total",
            Periods =
            {
                new BreakdownPivotPeriod { Key = "W1", Label = "Aug 05 - Aug 11", StartDate = new DateTime(2026, 8, 5), EndDate = new DateTime(2026, 8, 11) },
                new BreakdownPivotPeriod { Key = "W2", Label = "Aug 12 - Aug 18", StartDate = new DateTime(2026, 8, 12), EndDate = new DateTime(2026, 8, 18) }
            },
            Rows =
            {
                new BreakdownPivotRow
                {
                    IndexLabel = "A", Label = "HUMANA", IsInsuranceRow = true,
                    Cells = { new() { ClaimCount = 93, DenialBalance = 46925m }, new() { ClaimCount = 208, DenialBalance = 126427m } },
                    TotalClaimCount = 301, TotalBalance = 173352m
                }
            },
            TotalsByPeriod =
            {
                new BreakdownPivotCell { ClaimCount = 93, DenialBalance = 46925m },
                new BreakdownPivotCell { ClaimCount = 208, DenialBalance = 126427m }
            },
            GrandTotalClaimCount = 301,
            GrandTotalBalance = 173352m
        };

        var insights = new List<DenialInsightRecord>
        {
            new()
            {
                DenialCodes = "M127", Descriptions = "Missing patient medical record",
                NoOfDenialCount = 1294, NoOfClaimsCount = 1200, TotalBalance = 841270.23m,
                HighImpactInsurance = "HUMANA", InsuranceBalance = 492066m, ImpactPercentage = 58.49m,
                ActionCategory = "Appeal / MR", Action = "Submit the patient's medical records",
                Task = "Appeal", Feedback = "Awaiting payer response", Responsibility = "Tarshann",
                DiscussionDate = new DateTime(2026, 9, 9), ETA = "7 days"
            }
        };

        return new DenialDashboardExportData(
            LabName: "Cove Diagnostics",
            RunId: "R20260902COV1487",
            LineItems: new List<DenialLineItemRecord>(),
            TaskRecords: new List<DenialRecord>(),
            Insights: insights,
            WeeklyPivot: weekly,
            MonthlyPivot: monthly,
            StatusBreakdown: new List<BreakdownItem>(),
            PriorityBreakdown: new List<BreakdownItem>(),
            ActionCategoryBreakdown: new List<BreakdownItem>(),
            ClassificationBreakdown: new List<BreakdownItem>(),
            DeadlineBreakdown: new List<BreakdownItem>(),
            AssignedToBreakdown: new List<BreakdownItem>(),
            Workflow: new DenialWorkflowLineItemAnnotator(new List<DenialRecord>()),
            ActiveFilters: new List<(string, string?)>());
    }

    private static IXLWorksheet Insights(XLWorkbook wb) =>
        wb.Worksheet(DenialDashboardExcelExportBuilder.DenialInsightsSheetName);

    [Fact]
    public void Workbook_has_the_template_two_sheets_in_order()
    {
        using var wb = DenialDashboardExcelExportBuilder.CreateWorkbook(BuildSampleData(), fileName: "Cove Dx_Denial Report.xlsx");

        var names = wb.Worksheets.Select(x => x.Name).ToArray();
        Assert.Equal(new[] { "Denial Insights", "Denial Masterfile" }, names);
    }

    [Fact]
    public void Report_header_block_matches_the_template_rows()
    {
        using var wb = DenialDashboardExcelExportBuilder.CreateWorkbook(BuildSampleData(), fileName: "Cove Dx_Denial Report.xlsx");
        var ws = Insights(wb);

        // Labels in column C, values in column D — the template's rows 2..7.
        Assert.Equal("Client Name: ", ws.Cell(2, 3).GetString());
        Assert.Equal("Cove Diagnostics", ws.Cell(2, 4).GetString());
        Assert.Equal("Report Type: ", ws.Cell(3, 3).GetString());
        Assert.Equal("Denial Report", ws.Cell(3, 4).GetString());
        Assert.StartsWith("Denial Posted Date |", ws.Cell(4, 4).GetString());
        Assert.StartsWith("Date Posted |", ws.Cell(5, 4).GetString());
        Assert.Equal("Cove Dx_Denial Report", ws.Cell(6, 4).GetString());
        Assert.Equal("R20260902COV1487", ws.Cell(7, 4).GetString());
    }

    [Fact]
    public void Both_pivots_and_the_observations_share_one_sheet_in_template_order()
    {
        using var wb = DenialDashboardExcelExportBuilder.CreateWorkbook(BuildSampleData());
        var ws = Insights(wb);

        var titles = new List<(int Row, string Text)>();
        for (var r = 1; r <= ws.LastRowUsed()!.RowNumber(); r++)
        {
            var text = ws.Cell(r, 2).GetString();
            if (text.StartsWith("All Months") || text.StartsWith("Last 4 Weeks") || text.StartsWith("Key Observations"))
                titles.Add((r, text));
        }

        Assert.Equal(3, titles.Count);
        Assert.StartsWith("All Months", titles[0].Text);
        Assert.StartsWith("Last 4 Weeks", titles[1].Text);
        Assert.StartsWith("Key Observations", titles[2].Text);
        Assert.True(titles[0].Row < titles[1].Row && titles[1].Row < titles[2].Row);
    }

    [Fact]
    public void Pivot_fill_is_inverted_the_template_way_payer_clear_denial_grey()
    {
        using var wb = DenialDashboardExcelExportBuilder.CreateWorkbook(BuildSampleData());
        var ws = Insights(wb);

        // Find the monthly payer row and the denial row beneath it.
        var payerRow = 0;
        for (var r = 1; r <= ws.LastRowUsed()!.RowNumber(); r++)
        {
            if (ws.Cell(r, 3).GetString() == "HUMANA") { payerRow = r; break; }
        }
        Assert.True(payerRow > 0, "monthly payer row not found");

        Assert.Equal(XLColor.NoColor, ws.Cell(payerRow, 3).Style.Fill.BackgroundColor);
        Assert.Equal(XLColor.FromHtml("#E7E6E6"), ws.Cell(payerRow + 1, 3).Style.Fill.BackgroundColor);
        Assert.Equal(1, ws.Row(payerRow + 1).OutlineLevel);
    }

    [Fact]
    public void Balances_are_numeric_accounting_and_counts_dash_on_zero()
    {
        using var wb = DenialDashboardExcelExportBuilder.CreateWorkbook(BuildSampleData());
        var ws = Insights(wb);

        var payerRow = 0;
        for (var r = 1; r <= ws.LastRowUsed()!.RowNumber(); r++)
        {
            if (ws.Cell(r, 3).GetString() == "HUMANA") { payerRow = r; break; }
        }

        // G/H are the first period pair: a zero count and a zero balance.
        var count = ws.Cell(payerRow, 7);
        var balance = ws.Cell(payerRow, 8);
        Assert.Equal(XLDataType.Number, count.DataType);
        Assert.Equal(XLDataType.Number, balance.DataType);
        Assert.Contains("\"-\"", count.Style.NumberFormat.Format);
        Assert.Contains("$", balance.Style.NumberFormat.Format);
        Assert.Contains("(", balance.Style.NumberFormat.Format);
    }

    [Fact]
    public void Observations_carry_the_template_column_groups_and_leave_analyst_columns_blank()
    {
        using var wb = DenialDashboardExcelExportBuilder.CreateWorkbook(BuildSampleData());
        var ws = Insights(wb);

        var headerRow = 0;
        for (var r = 1; r <= ws.LastRowUsed()!.RowNumber(); r++)
        {
            if (ws.Cell(r, 2).GetString().StartsWith("Key Observations")) { headerRow = r + 1; break; }
        }
        Assert.True(headerRow > 1, "observations header not found");

        Assert.Equal("#", ws.Cell(headerRow, 2).GetString());
        Assert.Equal("Denial Codes", ws.Cell(headerRow, 3).GetString());
        Assert.Equal("Descriptions", ws.Cell(headerRow, 4).GetString());
        Assert.Equal("Highest $ Impact - Insurance", ws.Cell(headerRow, 8).GetString());
        Assert.Equal("Observation", ws.Cell(headerRow, 13).GetString());
        Assert.Equal("Category", ws.Cell(headerRow, 17).GetString());
        Assert.Equal("Action", ws.Cell(headerRow, 18).GetString());
        Assert.Equal("Closed Date", ws.Cell(headerRow, 27).GetString());

        // The template's two accent bands.
        Assert.Equal(XLColor.FromHtml("#D09E00"), ws.Cell(headerRow, 8).Style.Fill.BackgroundColor);
        Assert.Equal(XLColor.FromHtml("#C00000"), ws.Cell(headerRow, 17).Style.Fill.BackgroundColor);

        // Analyst-authored columns ship empty, by design.
        var dataRow = headerRow + 1;
        Assert.Equal("M127", ws.Cell(dataRow, 3).GetString());
        Assert.Equal(string.Empty, ws.Cell(dataRow, 13).GetString());
        Assert.Equal(string.Empty, ws.Cell(dataRow, 27).GetString());
    }

    /// <summary>
    /// Not an assertion — writes a workbook next to the build output so the layout can be opened
    /// and compared against the client template by eye. Skipped unless DENIAL_REPORT_SAMPLE is set,
    /// so a normal test run does not litter the drive.
    /// </summary>
    [Fact]
    public void Write_sample_workbook_for_visual_comparison()
    {
        var target = Environment.GetEnvironmentVariable("DENIAL_REPORT_SAMPLE");
        if (string.IsNullOrWhiteSpace(target)) return;

        using var wb = DenialDashboardExcelExportBuilder.CreateWorkbook(
            BuildSampleData(), fileName: "Cove Dx_Denial Report_08.26.2026 - 09.01.2026.xlsx");
        wb.SaveAs(target);
        Assert.True(File.Exists(target));
    }
}
