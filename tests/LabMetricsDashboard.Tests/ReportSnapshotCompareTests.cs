using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.ReportSnapshots;
using LabMetricsDashboard.ViewModels;
using LRN.ProductionReports.Models;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// Report Snapshots: comparing two weeks of a report, and the historical download's workbooks - both from the
/// view models the snapshots bind back to.
/// </summary>
public sealed class ReportSnapshotCompareTests
{
    [Theory]
    [InlineData("BilledCount", typeof(decimal), "count")]
    [InlineData("UnbilledCount", typeof(decimal), "count")]
    [InlineData("SelfPayCount", typeof(int), "count")]
    [InlineData("BilledCountPct", typeof(decimal), "percent")]
    [InlineData("BilledCharges", typeof(decimal), "money")]
    [InlineData("AccountBalance", typeof(decimal), "money")]
    [InlineData("DiscountAmount", typeof(decimal), "money")]
    public void Count_columns_are_not_printed_as_money(string name, Type type, string expected) =>
        Assert.Equal(expected, ReportSnapshotComparer.FormatFor(name, type));

    [Fact]
    public void Rows_are_matched_by_label_and_a_row_only_one_week_has_is_null_in_the_other()
    {
        var a = new ProductionReportViewModel
        {
            GrandTotalClaims = 30, GrandTotalCharges = 1000m,
            PanelRows = [Panel("Tox", 10, 400m), Panel("PGx", 20, 600m)]
        };
        var b = new ProductionReportViewModel
        {
            GrandTotalClaims = 35, GrandTotalCharges = 1100m,
            PanelRows = [Panel("PGx", 18, 540m), Panel("UTI", 5, 60m), Panel("Tox", 12, 500m)]
        };

        var result = ReportSnapshotComparer.Compare(a, b);

        var claims = Assert.Single(result.Totals, t => t.Key == "GrandTotalClaims");
        Assert.Equal((30m, 35m), (claims.A, claims.B));
        Assert.Equal("money", result.Totals.Single(t => t.Key == "GrandTotalCharges").Format);

        var panels = Assert.Single(result.Sections, s => s.Key == "PanelRows");
        Assert.Equal("Panel", panels.Title);
        Assert.Equal("Panel Name", panels.LabelName);
        Assert.Equal(["PGx", "UTI", "Tox"], panels.Rows.Select(r => r.Label));   // Week B's order
        var claimsIndex = panels.Measures.FindIndex(m => m.Key == "TotalClaims");
        Assert.Equal(12m, panels.Rows.Single(r => r.Label == "Tox").B![claimsIndex]);
        Assert.Null(panels.Rows.Single(r => r.Label == "UTI").A);
    }

    [Fact]
    public void A_keyed_map_of_cells_is_a_section_keyed_by_its_key()
    {
        var a = new ProductionReportViewModel { GrandTotalByMonth = new() { ["2026-09"] = new ProductionMonthCell(10, 100m) } };
        var b = new ProductionReportViewModel { GrandTotalByMonth = new() { ["2026-09"] = new ProductionMonthCell(12, 120m), ["2026-10"] = new ProductionMonthCell(3, 30m) } };

        var months = Assert.Single(ReportSnapshotComparer.Compare(a, b).Sections, s => s.Key == "GrandTotalByMonth");

        Assert.Equal(["2026-09", "2026-10"], months.Rows.Select(r => r.Label));
        Assert.Null(months.Rows[1].A);
    }

    [Fact]
    public void A_label_repeated_in_one_week_keeps_every_row()
    {
        var a = new ProductionReportViewModel { PanelRows = [Panel("Tox", 1, 1m), Panel("Tox", 2, 2m)] };
        var b = new ProductionReportViewModel { PanelRows = [Panel("Tox", 3, 3m)] };

        var panels = ReportSnapshotComparer.Compare(a, b).Sections.Single(s => s.Key == "PanelRows");

        Assert.Equal(["Tox", "Tox (2)"], panels.Rows.Select(r => r.Label));
    }

    [Fact]
    public void Lis_summary_rows_are_labelled_by_their_text_not_their_outline_code()
    {
        static LisSummaryResult Lis(int samples, int billed) => new("Logic", "file.csv", ["2026-10"], [2026],
            [
                new LisSummaryRow { Code = "A", Description = "Total Samples", Level = 0, Total = samples },
                new LisSummaryRow { Code = "1", Description = "Billed", Level = 1, Total = billed }
            ],
            new() { ["2026-10"] = samples }, new() { [2026] = samples }, samples, new LisSummaryKpiCards(samples, billed, 0, 0));

        var rows = ReportSnapshotComparer.Compare(Lis(100, 60), Lis(120, 70)).Sections.Single(s => s.Key == "Rows");

        Assert.Equal("Description", rows.LabelName);
        Assert.Equal(["Total Samples", "Billed"], rows.Rows.Select(r => r.Label));
        // The outline level places a row; it is not a number the report reports.
        Assert.DoesNotContain(rows.Measures, m => m.Key == "Level");
        Assert.Equal(120m, rows.Rows[0].B![rows.Measures.FindIndex(m => m.Key == "Total")]);
    }

    [Theory]
    [MemberData(nameof(ReportSnapshotViewerTests.ModelTypes), MemberType = typeof(ReportSnapshotViewerTests))]
    public void Every_report_view_model_compares(Type type)
    {
        var a = Bound(type);
        var b = Bound(type);

        var result = ReportSnapshotComparer.Compare(a, b);

        Assert.True(result.Sections.Count > 0 || result.Totals.Count > 0, $"{type.Name}: nothing to compare");
        Assert.All(result.Sections, s => Assert.All(s.Rows, r => Assert.Equal(s.Measures.Count, (r.A ?? r.B)!.Length)));
        Assert.DoesNotContain(result.Sections, s => s.Key.StartsWith("Available", StringComparison.Ordinal) || s.Key.StartsWith("Filter", StringComparison.Ordinal));
    }

    [Fact]
    public void Two_different_reports_are_refused()
    {
        Assert.Throws<ArgumentException>(() => ReportSnapshotComparer.Compare(new ProductionReportViewModel(), new CollectionSummaryViewModel()));
    }

    /// <summary>The builders LRN.ReportWorker's ReportSnapshotDownloadGenerator calls, on snapshot-bound models.</summary>
    [Fact]
    public void Every_report_snapshot_builds_its_workbook()
    {
        const string lab = "TexasDiagnostic";
        var dir = Path.Combine(Path.GetTempPath(), "rs-dl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var es = new ExecutiveSummaryExcelBuilder().Build((PhiExecutiveSummaryViewModel)Bound(typeof(PhiExecutiveSummaryViewModel)));
            Assert.True(es.Length > 1000);

            AssertSheets(LisSummaryExcelExportBuilder.CreateWorkbook((LisSummaryResult)Bound(typeof(LisSummaryResult)),
                null, lab, "", null, null, null, null, null, null, null), "LIS Summary");

            // Production's sheets parse their month keys ("2026-09"), which the generic sample cannot fill.
            var prod = new ProductionReportViewModel
            {
                SelectedLab = lab, Months = ["2026-08", "2026-09"], Years = [2026],
                GrandTotalClaims = 30, GrandTotalCharges = 1234.5m,
                GrandTotalByMonth = new() { ["2026-08"] = new ProductionMonthCell(10, 100m), ["2026-09"] = new ProductionMonthCell(20, 1134.5m) },
                PanelRows = [new ProductionPanelRow
                {
                    PanelName = "Tox", TotalClaims = 30, TotalCharges = 1234.5m,
                    ByMonth = new() { ["2026-08"] = new ProductionMonthCell(10, 100m), ["2026-09"] = new ProductionMonthCell(20, 1134.5m) },
                    ByYear = new() { [2026] = new ProductionYearTotal(30, 1234.5m) }
                }]
            };
            var prodBound = System.Text.Json.JsonSerializer.Deserialize<ProductionReportViewModel>(
                System.Text.Json.JsonSerializer.Serialize(prod, ReportSnapshotJson.Options), ReportSnapshotJson.Options)!;
            AssertSheets(LRN.ProductionReports.Services.ProductionReportExcelExportBuilder.CreateWorkbookSummaryOnly(
                prodBound, lab, "10.16.2026 - 10.22.2026", "R1"));

            var coll = (CollectionSummaryViewModel)Bound(typeof(CollectionSummaryViewModel));
            using (var wb = LabMetricsDashboard.Services.CollectionSummaryExcelExportBuilder.CreateWorkbook(coll, [], [], lab, [("Snapshot week", "10.16.2026 - 10.22.2026")]))
            {
                foreach (var ws in wb.Worksheets.Where(w => w.Name is "ClaimLevelData" or "LineLevelData").ToList()) ws.Delete();
                var path = Path.Combine(dir, "coll.xlsx");
                wb.SaveAs(path);
                LRN.ProductionReports.Services.OpenXmlPivotCacheFix.Apply(path);
                using var back = new XLWorkbook(path);
                Assert.True(back.Worksheets.Count > 0);
            }

            var denial = (DenialClaimReportViewModel)Bound(typeof(DenialClaimReportViewModel));
            denial.Insight.Rows = ((DenialInsightSnapshotModel)Bound(typeof(DenialInsightSnapshotModel))).CurrentWeek;
            AssertSheets(DenialClaimReportExcelBuilder.Build(denial), "Monthly Summary", "Denial Insight");
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }

        static void AssertSheets(XLWorkbook wb, params string[] names)
        {
            using (wb)
            {
                Assert.True(wb.Worksheets.Count > 0);
                foreach (var name in names) Assert.Contains(wb.Worksheets, w => w.Name == name);
                using var ms = new MemoryStream();
                wb.SaveAs(ms);
                Assert.True(ms.Length > 1000);
            }
        }
    }

    private static ProductionPanelRow Panel(string name, int claims, decimal charges) =>
        new() { PanelName = name, TotalClaims = claims, TotalCharges = charges };

    /// <summary>A populated model as the viewer gets it: the binding tests' sample, through the snapshot JSON.</summary>
    private static object Bound(Type type)
    {
        var sample = ReportSnapshotViewerTests.Sample.Create(type, 0)!;
        foreach (var p in type.GetProperties())
            if (p.Name is "ErrorMessage" or "Error" && p.PropertyType == typeof(string) && p.SetMethod is not null)
                p.SetValue(sample, null);
        var json = System.Text.Json.JsonSerializer.Serialize(sample, type, ReportSnapshotJson.Options);
        return System.Text.Json.JsonSerializer.Deserialize(json, type, ReportSnapshotJson.Options)!;
    }
}
