using System.IO;
using ClosedXML.Excel;
using LRN.ReportsApi.Controllers;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Denial Summary observations and snapshots (Denial Workflow v1.1, 4a-4i): the rich-text
/// sanitizer, snapshot periods, retention, status, request validation and workbook shape. The SQL
/// repository needs a lab database and is verified manually.
/// </summary>
public class DenialSummaryHtmlTests
{
    [Theory]
    [InlineData("<script>alert(1)</script>Hello", "Hello")]
    [InlineData("<img src=x onerror=alert(1)>Hi", "Hi")]
    [InlineData("<b onclick=\"alert(1)\">Bold</b>", "<b>Bold</b>")]
    [InlineData("<a href=\"javascript:alert(1)\">link</a>", "link")]
    [InlineData("<p style=\"background:url(javascript:alert(1))\">x</p>", "<p>x</p>")]
    [InlineData("<svg><script>alert(1)</script></svg>ok", "ok")]
    [InlineData("<iframe src=//evil></iframe>safe", "safe")]
    [InlineData("<!-- <script>alert(1)</script> -->text", "text")]
    [InlineData("<SCRIPT>alert(1)</SCRIPT >after", "after")]
    public void Strips_anything_that_can_run_script(string input, string expected)
        => Assert.Equal(expected, DenialSummaryHtml.Sanitize(input));

    [Fact]
    public void Keeps_formatting_tags_without_attributes()
    {
        var html = "<div class=\"x\"><strong>Payer</strong> <em>delay</em><ul><li>Call</li><li>Rebill</li></ul><u>u</u><br/><s>old</s></div>";
        Assert.Equal("<div><strong>Payer</strong> <em>delay</em><ul><li>Call</li><li>Rebill</li></ul><u>u</u><br><s>old</s></div>",
            DenialSummaryHtml.Sanitize(html));
    }

    [Theory]
    [InlineData("a < b > c", "a &lt; b &gt; c")]
    [InlineData("AT&T", "AT&amp;T")]
    [InlineData("Tom &amp; Jerry&nbsp;&#39;s", "Tom &amp; Jerry&nbsp;&#39;s")]
    [InlineData("&#60;script&#62;", "&#60;script&#62;")]
    [InlineData("<<b>x</b>", "&lt;<b>x</b>")]
    public void Text_characters_are_escaped_and_valid_entities_kept(string input, string expected)
        => Assert.Equal(expected, DenialSummaryHtml.Sanitize(input));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("<p><br></p>")]
    [InlineData("<div>&nbsp;</div>")]
    [InlineData("<script>only script</script>")]
    public void Empty_editor_content_is_stored_as_null(string? input)
        => Assert.Null(DenialSummaryHtml.Sanitize(input));

    [Fact]
    public void Plain_text_keeps_lines_and_bullets()
    {
        var text = DenialSummaryHtml.ToPlainText("<p><b>Payer</b> &amp; clinic</p><ul><li>Call</li><li>Rebill</li></ul>Done<br>Next");
        Assert.Equal("Payer & clinic\n\n• Call\n• Rebill\nDone\nNext", text);
    }
}

public class DenialSummaryScheduleTests
{
    [Theory]
    [InlineData("2026-09-14", "2026-09-07", "2026-09-13")] // Monday: the week just ended
    [InlineData("2026-09-15", "2026-09-07", "2026-09-13")] // Tuesday: still last week
    [InlineData("2026-09-13", "2026-08-31", "2026-09-06")] // Sunday: current week not finished
    [InlineData("2026-01-01", "2025-12-22", "2025-12-28")] // crosses a year
    public void Last_completed_week_is_monday_to_sunday(string today, string start, string end)
    {
        var (s, e) = DenialSummarySchedule.LastCompletedWeek(DateTime.Parse(today));
        Assert.Equal(DateTime.Parse(start), s);
        Assert.Equal(DateTime.Parse(end), e);
        Assert.Equal(DayOfWeek.Monday, s.DayOfWeek);
    }

    [Theory]
    [InlineData("2026-09-01", "2026-08-01", "2026-08-31")]
    [InlineData("2026-09-30", "2026-08-01", "2026-08-31")]
    [InlineData("2026-03-10", "2026-02-01", "2026-02-28")]
    [InlineData("2026-01-15", "2025-12-01", "2025-12-31")]
    public void Last_completed_month_is_the_previous_calendar_month(string today, string start, string end)
    {
        var (s, e) = DenialSummarySchedule.LastCompletedMonth(DateTime.Parse(today));
        Assert.Equal(DateTime.Parse(start), s);
        Assert.Equal(DateTime.Parse(end), e);
    }

    private static DenialSummarySnapshotInfo Snap(long id, string type, string start, bool archived = false)
        => new() { SnapshotId = id, PeriodType = type, PeriodStart = DateTime.Parse(start), CreatedOn = DateTime.Parse(start), IsArchived = archived };

    [Fact]
    public void Retention_archives_only_past_the_newest_n_per_period_type()
    {
        var options = new DenialSummarySnapshotOptions { WeeklyRetention = 2, MonthlyRetention = 1, OnDemandRetention = 3 };
        var snapshots = new[]
        {
            Snap(1, "Weekly", "2026-08-17"),
            Snap(2, "Weekly", "2026-08-24"),
            Snap(3, "Weekly", "2026-08-31"),
            Snap(4, "Weekly", "2026-09-07"),
            Snap(5, "Monthly", "2026-07-01"),
            Snap(6, "Monthly", "2026-08-01"),
            Snap(7, "OnDemand", "2026-09-10"),
            Snap(8, "Weekly", "2026-08-10", archived: true)
        };

        var archive = DenialSummarySchedule.SelectForArchive(snapshots, options).OrderBy(x => x).ToArray();

        Assert.Equal(new long[] { 1, 2, 5 }, archive);
    }

    [Fact]
    public void Zero_retention_never_archives_everything()
    {
        var options = new DenialSummarySnapshotOptions { WeeklyRetention = 0 };
        Assert.Empty(DenialSummarySchedule.SelectForArchive(new[] { Snap(1, "Weekly", "2026-08-17"), Snap(2, "Weekly", "2026-08-24") }, options));
    }

    [Theory]
    [InlineData(null, null, null, "Open")]
    [InlineData("2026-09-14", null, null, "Overdue")]
    [InlineData("2026-09-15", null, null, "Open")]
    [InlineData(null, "2026-09-15", null, "Follow-up Due")]
    [InlineData("2026-09-01", "2026-09-01", "2026-09-10", "Completed")]
    public void Status_follows_the_dates(string? target, string? followUp, string? completed, string expected)
    {
        var obs = new DenialSummaryObservation
        {
            ResponsiblePerson = "Priya",
            TargetDate = target is null ? null : DateTime.Parse(target),
            FollowUpDate = followUp is null ? null : DateTime.Parse(followUp),
            CompletedDate = completed is null ? null : DateTime.Parse(completed)
        };
        Assert.Equal(expected, DenialSummarySchedule.ObservationStatus(obs, DateTime.Parse("2026-09-15")));
    }

    [Fact]
    public void Status_is_blank_for_an_empty_row()
        => Assert.Equal(string.Empty, DenialSummarySchedule.ObservationStatus(new DenialSummaryObservation(), DateTime.Today));
}

public class DenialSummaryRequestValidationTests
{
    private static DenialSummaryObservationRequest Valid() => new()
    {
        SummaryType = "classification",
        SummaryKey = "  Medical Necessity ",
        ResponsiblePerson = "  Priya (Aetna rep) ",
        ObservationHtml = "<b>Call payer</b><script>x</script>",
        ObservationDate = new DateTime(2026, 9, 1, 15, 30, 0),
        TargetDate = new DateTime(2026, 9, 30)
    };

    [Fact]
    public void Normalizes_type_key_person_html_and_dates()
    {
        var request = Valid();
        Assert.Null(DenialSummaryController.NormalizeAndValidate(request));
        Assert.Equal(DenialSummaryTypes.Classification, request.SummaryType);
        Assert.Equal("Medical Necessity", request.SummaryKey);
        Assert.Equal("Priya (Aetna rep)", request.ResponsiblePerson);
        Assert.Equal("<b>Call payer</b>", request.ObservationHtml);
        Assert.Equal(new DateTime(2026, 9, 1), request.ObservationDate);
    }

    [Theory]
    [InlineData("Payer")]
    [InlineData("")]
    public void Rejects_unknown_summary_types(string type)
    {
        var request = Valid();
        request.SummaryType = type;
        Assert.NotNull(DenialSummaryController.NormalizeAndValidate(request));
    }

    [Fact]
    public void Rejects_blank_key_long_person_bad_year_and_completion_before_observation()
    {
        var blankKey = Valid(); blankKey.SummaryKey = " ";
        var longPerson = Valid(); longPerson.ResponsiblePerson = new string('x', 201);
        var badYear = Valid(); badYear.FollowUpDate = new DateTime(1900, 1, 1);
        var backwards = Valid(); backwards.CompletedDate = new DateTime(2026, 8, 1);

        Assert.NotNull(DenialSummaryController.NormalizeAndValidate(blankKey));
        Assert.NotNull(DenialSummaryController.NormalizeAndValidate(longPerson));
        Assert.NotNull(DenialSummaryController.NormalizeAndValidate(badYear));
        Assert.NotNull(DenialSummaryController.NormalizeAndValidate(backwards));
    }

    [Theory]
    [InlineData("AR Manager", true)]
    [InlineData("Admin", true)]
    [InlineData("AR Reviewer", false)]
    [InlineData("Client Manager", false)]
    [InlineData("Lab User", false)]
    [InlineData(null, false)]
    public void Only_ar_manager_and_admin_can_write(string? role, bool expected)
        => Assert.Equal(expected, DenialSummaryController.CanWriteRole(role));
}

public class DenialSummaryWorkbookTests
{
    [Fact]
    public void Workbook_puts_each_rows_observation_beside_its_numbers()
    {
        var summary = new DenialWorkflowDashboardSummary
        {
            DenialClassifications =
            [
                new DenialClassificationSummaryRow { Classification = "Medical Necessity", Count = 10, BilledAmount = 1000m, InsuranceBalance = 800m, PercentageOfTotal = 62.5m },
                new DenialClassificationSummaryRow { Classification = "", Count = 6, BilledAmount = 500m, InsuranceBalance = 200m, PercentageOfTotal = 37.5m }
            ],
            ActionCategories =
            [
                new ActionCategorySummaryRow { ActionCategory = "Rebill", Count = 16, BilledAmount = 1500m, InsuranceBalance = 1000m, PercentageOfTotal = 100m }
            ]
        };
        var observations = new[]
        {
            new DenialSummaryObservation
            {
                SummaryType = DenialSummaryTypes.Classification, SummaryKey = "medical necessity",
                ObservationHtml = "<b>Payer</b> wants notes<ul><li>Send records</li></ul>",
                ResponsiblePerson = "Priya", TargetDate = new DateTime(2026, 9, 1)
            },
            new DenialSummaryObservation
            {
                SummaryType = DenialSummaryTypes.ActionCategory, SummaryKey = "Rebill",
                ResponsiblePerson = "Sam", CompletedDate = new DateTime(2026, 9, 10)
            }
        };

        var bytes = DenialSummaryWorkbook.Build("Cove", DenialSummarySnapshotPeriodTypes.Weekly,
            new DateTime(2026, 9, 7), new DateTime(2026, 9, 13), new DateTime(2026, 9, 15, 8, 0, 0), "Scheduler", summary, observations);

        using var workbook = new XLWorkbook(new MemoryStream(bytes));
        var ws = workbook.Worksheet("Denial Summary");
        var cells = ws.CellsUsed().ToList();

        IXLCell Row(string name) => cells.First(c => c.Address.ColumnNumber == 1 && c.GetString() == name);

        Assert.Equal("Week 09/07/2026 - 09/13/2026", ws.Cell(2, 2).GetString());

        var medical = Row("Medical Necessity").Address.RowNumber;
        Assert.Equal(10, ws.Cell(medical, 2).GetValue<int>());
        Assert.Equal("Overdue", ws.Cell(medical, 6).GetString());
        Assert.Equal("Priya", ws.Cell(medical, 7).GetString());
        Assert.Equal("Payer wants notes\n• Send records", ws.Cell(medical, 12).GetString());

        var unclassified = Row("Unclassified").Address.RowNumber;
        Assert.Equal(string.Empty, ws.Cell(unclassified, 6).GetString());

        var rebill = Row("Rebill").Address.RowNumber;
        Assert.True(rebill > medical);
        Assert.Equal("Completed", ws.Cell(rebill, 6).GetString());
        Assert.Equal(new DateTime(2026, 9, 10), ws.Cell(rebill, 11).GetDateTime());

        Assert.Equal(2, cells.Count(c => c.Address.ColumnNumber == 1 && c.GetString() == "Total"));
    }

    [Theory]
    [InlineData("Weekly", "PCR_Labs_of_America_DenialSummary_Weekly_20260907-20260913.xlsx")]
    [InlineData("Monthly", "PCR_Labs_of_America_DenialSummary_Monthly_2026-09.xlsx")]
    [InlineData("OnDemand", "PCR_Labs_of_America_DenialSummary_20260915_0830.xlsx")]
    public void File_names_are_safe_and_describe_the_period(string periodType, string expected)
        => Assert.Equal(expected, DenialSummaryWorkbook.FileName("PCR Labs of America", periodType,
            new DateTime(2026, 9, 7), new DateTime(2026, 9, 13), new DateTime(2026, 9, 15, 8, 30, 0)));
}
