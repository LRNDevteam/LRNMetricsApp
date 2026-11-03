using System;
using System.Linq;
using LabMetricsDashboard.Models.Notes;
using LabMetricsDashboard.Services.ReportSnapshots;
using LabMetricsDashboard.ViewModels;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>Report Snapshots: the Key Insights a week's snapshot holds, and which reports have them.</summary>
public sealed class ReportInsightsSnapshotTests
{
    [Fact]
    public void Only_the_weeks_insights_are_kept_in_entry_order()
    {
        var week = new DateTime(2026, 10, 16);
        var rows = new[]
        {
            new NoteInsight { NoteId = 3, EntryNo = 2, WeekRangeStart = week },
            new NoteInsight { NoteId = 1, EntryNo = 1, WeekRangeText = "10.16.2026  -  10.22.2026" },
            new NoteInsight { NoteId = 2, WeekRangeStart = week.AddDays(-7), WeekRangeText = "10.09.2026 - 10.15.2026" },
            new NoteInsight { NoteId = 4 }   // no week at all: shown, as the panel does
        };

        var kept = ReportInsightsSnapshotModel.InWeek(rows, week, "10.16.2026 - 10.22.2026");

        Assert.Equal([1, 3, 4], kept.Select(n => n.NoteId));
    }

    [Fact]
    public void Without_a_week_every_insight_is_kept()
    {
        var rows = new[] { new NoteInsight { NoteId = 1, WeekRangeStart = new DateTime(2026, 1, 1) } };
        Assert.Single(ReportInsightsSnapshotModel.InWeek(rows, null, null));
    }

    [Theory]
    [InlineData("LIS Report", "LISINSIGHT")]
    [InlineData("Production Report", "PRODINSIGHT")]
    [InlineData("Collection Report", "COLLINSIGHT")]
    [InlineData("Executive Summary", null)]
    public void Saving_an_insight_refreshes_its_reports_snapshot(string notesReport, string? code)
    {
        Assert.Equal(code, ReportSnapshotViewContext.ReportCodes.InsightForNotesReport(notesReport));
    }

    [Fact]
    public void Each_report_with_the_panel_names_its_insights_snapshot()
    {
        Assert.Equal("LISINSIGHT", ReportSnapshotViewContext.ReportCodes.InsightFor("LISSUMMARY"));
        Assert.Equal("PRODINSIGHT", ReportSnapshotViewContext.ReportCodes.InsightFor("PRODSUMMARY"));
        Assert.Equal("COLLINSIGHT", ReportSnapshotViewContext.ReportCodes.InsightFor("COLLSUMMARY"));
        Assert.Null(ReportSnapshotViewContext.ReportCodes.InsightFor("EXECSUMMARY"));
    }
}
