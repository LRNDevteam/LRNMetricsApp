// This test project does not enable ImplicitUsings, so the BCL namespaces are spelled out.
using System;
using System.Linq;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// The Executive Summary download's Denial Highlights: the same three panes the page's Denial
/// Highlights tab shows - Monthly, Weekly and the Current Week Denial Insight.
/// </summary>
public sealed class DenialHighlightsWorkbookTests
{
    private static DenialClaimReportViewModel Model(params DenialInsightRow[] rows) => new()
    {
        CurrentLab = "Cove",
        Insight = new DenialInsightPanelViewModel
        {
            CurrentLab = "Cove",
            Bucket = DenialInsightBuckets.Current,
            Rows = rows
        }
    };

    [Fact]
    public void Highlights_workbook_has_monthly_weekly_and_insight_sheets()
    {
        using var wb = DenialClaimReportExcelBuilder.BuildHighlights(Model());

        var names = wb.Worksheets.Select(x => x.Name).ToArray();
        Assert.Equal(new[] { "Monthly Summary", "Weekly Summary", "Denial Insight" }, names);
    }

    [Fact]
    public void Insight_sheet_carries_the_current_week_rows()
    {
        var row = new DenialInsightRow
        {
            Bucket = DenialInsightBuckets.Current,
            WeekStart = new DateTime(2026, 11, 9),
            DenialCode = "CO-16",
            DenialDescription = "Claim lacks information",
            PayerName = "HUMANA",
            NoOfDenials = 12,
            TotalBalance = 4200m
        };

        using var wb = DenialClaimReportExcelBuilder.BuildHighlights(Model(row));
        var ws = wb.Worksheet("Denial Insight");

        Assert.StartsWith("Current Week", ws.Cell(2, 1).GetString());
        var used = ws.RangeUsed()!;
        Assert.Contains(used.CellsUsed(), c => c.GetString() == "CO-16");
    }

    [Fact]
    public void Summary_workbook_stays_monthly_and_weekly_only()
    {
        using var wb = DenialClaimReportExcelBuilder.BuildSummary(Model());

        Assert.Equal(new[] { "Monthly Summary", "Weekly Summary" }, wb.Worksheets.Select(x => x.Name).ToArray());
    }
}
