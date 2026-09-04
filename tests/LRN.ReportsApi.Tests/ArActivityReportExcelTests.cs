using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArReports;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// RPT-01 Excel export.
///
/// The workbook is the artefact an AR Manager takes away and reconciles against, so these tests
/// pin the two things a reader depends on: that the sheets the spec requires are all present, and
/// that the Reconciliation sheet actually recomputes the measures from the detail rows rather than
/// echoing the summary back (which would make it incapable of detecting a disagreement).
/// </summary>
public class ArActivityReportExcelTests
{
    /// <summary>
    /// The spec's own worked example: three activities by one analyst on one claim on one day
    /// (two notes and one escalation), plus a second claim worked by a second analyst. That is
    /// 4 activity events but only 2 distinct claim-days.
    /// </summary>
    private static ArActivityReportResult SpecWorkedExample()
    {
        var day = new DateTime(2026, 9, 3);
        ArActivityEventRow Row(string id, string claim, string line, string author, string type, decimal balance, bool escalated = false, bool completed = false) => new()
        {
            ActivityId = id,
            SourceType = escalated ? "Escalation" : "Note",
            ClaimId = claim,
            LineItemId = line,
            Author = author,
            AnalystName = author,
            ActivityDate = day.AddHours(9),
            ActivityDateKey = "2026-09-03",
            ActivityType = type,
            BalanceSnapshot = balance,
            BalanceIsSnapshot = true,
            Escalated = escalated,
            ActionCompleted = completed,
            ActionCompletionIsEvent = completed,
            PayerName = "Aetna",
            ReportingBucket = "Active Follow-up",
            NoteText = "Reviewed denial and attached clinical notes.",
            UpdateSource = "Application"
        };

        var rows = new List<ArActivityEventRow>
        {
            Row("N:1", "CLM-10041", "LN-01", "anita.rao", "Work Note", 860m),
            Row("N:2", "CLM-10041", "LN-01", "anita.rao", "Work Note", 860m),
            Row("N:3", "CLM-10041", "LN-02", "anita.rao", "Work Note", 860m, completed: true),
            Row("E:1", "CLM-10058", "LN-01", "daniel.kim", "Escalation Raised", 680m, escalated: true)
        };

        return new ArActivityReportResult
        {
            Metadata = new ArReportRunMetadata
            {
                ReportCode = "RPT-01",
                ReportName = "AR Follow-up Activity Detail",
                RunId = "RPT01-19-20260903084200-ABC123",
                LabId = 19,
                LabName = "Augustus Labs",
                GeneratedBy = "priya.s",
                GeneratedByRole = "AR Manager",
                GeneratedOn = new DateTime(2026, 9, 3, 8, 42, 0),
                AsOf = new DateTime(2026, 9, 3, 8, 42, 0),
                DataRefreshedOn = new DateTime(2026, 9, 3, 7, 30, 0),
                DataRefreshRunId = "RUN-5812",
                Grain = "Claim",
                RoleView = "Internal Management",
                InternalNotesVisible = true,
                AppliedFilters = [new ArAppliedFilter { Label = "Activity period", Value = "28 Aug 2026 to 03 Sep 2026" }],
                UnavailableMeasures = ["Contact method is blank for activities recorded before the note form captured it."]
            },
            Summary = new ArActivitySummary
            {
                ActivityEvents = 4,
                DistinctClaimDaysWorked = 2,
                DistinctLineDaysWorked = 3,
                DistinctClaimsWorked = 2,
                DistinctLinesWorked = 3,
                DistinctAnalysts = 2,
                ActionsCompleted = 1,
                ActionsCompletedFromEvents = 1,
                EscalationsRaised = 1,
                NotesRecorded = 3,
                StatusChanges = 0,
                // One balance per claim/analyst/day: 860 (Anita on CLM-10041) + 680 (Daniel on
                // CLM-10058). NOT 860 x 3 + 680, which is what summing per row would give.
                BalanceWorked = 1540m,
                RowsWithFallbackBalance = 0
            },
            Detail = new PagedResult<ArActivityEventRow> { Items = rows, Page = 1, PageSize = 50, TotalCount = rows.Count },
            Groups =
            [
                new ArActivityGroupRow { GroupKey = "anita.rao", GroupLabel = "anita.rao", ActivityEvents = 3, DistinctClaimDaysWorked = 1, DistinctLineDaysWorked = 2, DistinctClaims = 1, ActionsCompleted = 1, EscalationsRaised = 0, BalanceWorked = 860m },
                new ArActivityGroupRow { GroupKey = "daniel.kim", GroupLabel = "daniel.kim", ActivityEvents = 1, DistinctClaimDaysWorked = 1, DistinctLineDaysWorked = 1, DistinctClaims = 1, ActionsCompleted = 0, EscalationsRaised = 1, BalanceWorked = 680m }
            ]
        };
    }

    private static XLWorkbook BuildWorkbook(ArActivityReportResult report)
    {
        var bytes = ArActivityReportExcelBuilder.Build(report);
        Assert.NotEmpty(bytes);
        return new XLWorkbook(new MemoryStream(bytes));
    }

    [Fact]
    public void Export_ContainsEverySheetTheSpecRequires()
    {
        using var workbook = BuildWorkbook(SpecWorkedExample());
        var names = workbook.Worksheets.Select(w => w.Name).ToList();

        // Applied filters + run metadata, summary totals, grouping, detail rows, reconciliation.
        Assert.Contains("Report Info", names);
        Assert.Contains("Summary", names);
        Assert.Contains("Grouped Summary", names);
        Assert.Contains("Activity Detail", names);
        Assert.Contains("Reconciliation", names);
    }

    [Fact]
    public void Export_CarriesTheRunIdAndGenerationMetadata()
    {
        using var workbook = BuildWorkbook(SpecWorkedExample());
        var info = workbook.Worksheet("Report Info");
        var text = string.Join("\n", info.CellsUsed().Select(c => c.GetString()));

        Assert.Contains("RPT01-19-20260903084200-ABC123", text);
        Assert.Contains("Augustus Labs", text);
        Assert.Contains("priya.s", text);
        Assert.Contains("Activity period", text);
    }

    [Fact]
    public void Export_WritesOneDetailRowPerActivityEvent()
    {
        var report = SpecWorkedExample();
        using var workbook = BuildWorkbook(report);
        var detail = workbook.Worksheet("Activity Detail");

        // Header row plus one row per event.
        Assert.Equal(report.Detail.Items.Count + 1, detail.RowsUsed().Count());
    }

    /// <summary>
    /// The whole point of the Reconciliation sheet: recomputed-from-detail must equal the summary,
    /// so every difference is zero. Three same-day notes on one claim by one analyst count as three
    /// activity events and ONE claim-day — the spec's single most important assertion.
    /// </summary>
    [Fact]
    public void Reconciliation_RecomputesFromDetailAndAgreesWithTheSummary()
    {
        using var workbook = BuildWorkbook(SpecWorkedExample());
        var sheet = workbook.Worksheet("Reconciliation");

        var checkedRows = 0;
        foreach (var row in sheet.RowsUsed().Skip(1))
        {
            var label = row.Cell(1).GetString();
            if (string.IsNullOrWhiteSpace(label) || !row.Cell(4).TryGetValue<double>(out var difference)) continue;

            Assert.True(difference == 0d, $"Reconciliation mismatch on '{label}': summary and detail differ by {difference}.");
            checkedRows++;
        }

        // Activity events, claim-days, line-days, claims, actions, escalations, balance.
        Assert.Equal(7, checkedRows);
    }

    [Fact]
    public void Reconciliation_ShowsClaimDaysBelowActivityEvents_NotEqualToThem()
    {
        // Guards the inflation the spec is written to prevent: if these ever match on this fixture,
        // repeated notes are being counted as repeated claim coverage.
        using var workbook = BuildWorkbook(SpecWorkedExample());
        var sheet = workbook.Worksheet("Reconciliation");

        double Recomputed(string label) => sheet.RowsUsed()
            .First(r => r.Cell(1).GetString() == label)
            .Cell(3).GetValue<double>();

        Assert.Equal(4d, Recomputed("Activity events"));
        Assert.Equal(2d, Recomputed("Distinct claim-days worked"));
        Assert.Equal(3d, Recomputed("Distinct line-days worked"));
        Assert.Equal(1540d, Recomputed("Outstanding balance worked"));
    }

    [Fact]
    public void Export_FlagsAPartialExportSoDifferencesAreNotMistakenForABug()
    {
        var report = SpecWorkedExample();
        report.Detail.TotalCount = 250_000;   // more matching rows than the export ceiling allows

        using var workbook = BuildWorkbook(report);
        var text = string.Join("\n", workbook.Worksheet("Reconciliation").CellsUsed().Select(c => c.GetString()));

        Assert.Contains("PARTIAL EXPORT", text);
    }

    [Fact]
    public void Export_SurvivesAnEmptyResult()
    {
        var report = SpecWorkedExample();
        report.Detail = new PagedResult<ArActivityEventRow> { Items = [], Page = 1, PageSize = 50, TotalCount = 0 };
        report.Summary = new ArActivitySummary();
        report.Groups = [];
        report.EmptyStateReason = "No qualifying activity events matched the selected filters.";

        using var workbook = BuildWorkbook(report);
        Assert.Contains("Activity Detail", workbook.Worksheets.Select(w => w.Name));
        Assert.Contains(
            "No qualifying activity events matched the selected filters.",
            string.Join("\n", workbook.Worksheet("Report Info").CellsUsed().Select(c => c.GetString())));
    }

    [Fact]
    public void Export_MarksRowsWhoseBalanceIsCurrentRatherThanASnapshot()
    {
        var report = SpecWorkedExample();
        report.Detail.Items[0].BalanceIsSnapshot = false;
        report.Summary.RowsWithFallbackBalance = 1;

        using var workbook = BuildWorkbook(report);
        var detailText = string.Join("\n", workbook.Worksheet("Activity Detail").CellsUsed().Select(c => c.GetString()));
        var summaryText = string.Join("\n", workbook.Worksheet("Summary").CellsUsed().Select(c => c.GetString()));

        Assert.Contains("Current (not snapshot)", detailText);
        Assert.Contains("Snapshot at activity", detailText);
        Assert.Contains("predate snapshot capture", summaryText);
    }
}
