using System.Text.Json;
using LRN.MasterFileProcessorWorker.Snapshots;
using LRN.ProductionReports.Models;

namespace LRN.SnapshotGenerator;

/// <summary>
/// <c>--selftest</c>: a Production Summary view model with a month pivot, year totals and child rows,
/// through <see cref="ViewModelSections"/> and the Parquet writer, read back. No database, vault or storage.
/// </summary>
public static class SelfTest
{
    public static async Task<int> RunAsync()
    {
        int failed = 0;
        void Check(bool ok, string what)
        {
            Console.WriteLine($"  {(ok ? "ok  " : "FAIL")} {what}");
            if (!ok) failed++;
        }

        var vm = new ProductionReportViewModel
        {
            AvailableLabs = ["A", "B"],
            SelectedLab = "TexasDiagnostic",
            Months = ["2026-08", "2026-09"],
            Years = [2026],
            GrandTotalClaims = 30,
            GrandTotalCharges = 1234.5678m,
            GrandTotalByMonth = new() { ["2026-08"] = new ProductionMonthCell(10, 100m), ["2026-09"] = new ProductionMonthCell(20, 1134.5678m) },
            PanelRows =
            [
                new ProductionPanelRow
                {
                    PanelName = "Tox",
                    ByMonth = new() { ["2026-08"] = new ProductionMonthCell(4, 40m), ["2026-09"] = new ProductionMonthCell(6, 60.123456m) },
                    ByYear = new() { [2026] = new ProductionYearTotal(10, 100.123456m) },
                    TotalClaims = 10,
                    TotalCharges = 100.123456m
                },
                // A month the first row lacks: the column still appears, the first row's cell is null.
                new ProductionPanelRow
                {
                    PanelName = "PGx",
                    ByMonth = new() { ["2026-10"] = new ProductionMonthCell(1, 5m) },
                    TotalClaims = 1,
                    TotalCharges = 5m
                }
            ]
        };

        var sections = ViewModelSections.Extract(vm);
        Console.WriteLine("Sections: " + string.Join(", ", sections.Select(s => $"{s.Name}[{s.Table.Rows.Count}x{s.Table.Columns.Count}]")));

        var summary = sections.FirstOrDefault(s => s.Name == "Summary");
        Check(summary is not null && summary.Table.Rows.Count == 1 && summary.Table.Columns.Contains("GrandTotalCharges"), "Summary row holds the model's scalars");
        Check(summary is not null && !summary.Table.Columns.Contains("SelectedLab"), "Selected*/Available*/Filter* left out");
        Check(sections.All(s => s.Name != "AvailableLabs"), "AvailableLabs list left out");

        var panels = sections.FirstOrDefault(s => s.Name == "PanelRows")?.Table;
        Check(panels is not null && panels.Rows.Count == 2, "PanelRows: one row per panel");
        Check(panels is not null && panels.Columns.Contains("ByMonth.2026-08.ClaimCount") && panels.Columns.Contains("ByMonth.2026-10.BilledCharges"),
            "Month pivot becomes one column per month and measure, across all rows");
        Check(panels is not null && panels.Rows[0]["ByMonth.2026-10.ClaimCount"] is DBNull, "A month a row lacks is null");
        Check(panels is not null && panels.Columns["TotalCharges"]!.DataType == typeof(decimal), "Money stays decimal");

        var months = sections.FirstOrDefault(s => s.Name == "Months")?.Table;
        Check(months is not null && months.Rows.Count == 2 && (string)months.Rows[1]["Value"] == "2026-09", "Months keep the page's order");
        Check(sections.Any(s => s.Name == "GrandTotalByMonth" && s.Table.Rows.Count == 2), "GrandTotalByMonth: one row per key");

        // Parquet round trip of every section, footer row count = table rows.
        var dir = Path.Combine(Path.GetTempPath(), "LRN-SnapshotSelfTest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            foreach (var s in sections)
            {
                var file = Path.Combine(dir, ReportSnapshotService.SafeName(s.Name) + ".parquet");
                using var reader = s.Table.CreateDataReader();
                var result = await ParquetSnapshotWriter.WriteAsync(reader, file, 1000, Parquet.CompressionMethod.Snappy, CancellationToken.None);
                var footer = await ParquetSnapshotWriter.ReadRowCountAsync(file, CancellationToken.None);
                Check(footer == s.Table.Rows.Count && result.ColumnCount == s.Table.Columns.Count,
                    $"Parquet {s.Name}: {footer} row(s), {result.ColumnCount} column(s)");
            }

            var panelSchema = await ParquetSnapshotWriter.WriteAsync(sections.First(s => s.Name == "PanelRows").Table.CreateDataReader(),
                Path.Combine(dir, "schema.parquet"), 1000, Parquet.CompressionMethod.Snappy, CancellationToken.None);
            Check(panelSchema.SchemaJson.Contains("\"scale\":10"), "In-memory decimals keep 10 decimal places");

            // The display copy: written, read back, and bound to the page's own view model type as a viewer would.
            var page = new ReportPageSnapshot
            {
                ReportCode = "PRODSUMMARY", LabKey = "TexasDiagnostic", RunId = "R1", WeekFolder = "10.16.2026 - 10.22.2026",
                ModelType = vm.GetType().FullName!, Model = vm,
                Logic = new ReportLogicVersion { AppVersion = "1.0", Objects = [new("dbo.usp_X", "SQL_STORED_PROCEDURE", "aa", DateTime.UtcNow)] }
            };
            var pagePath = Path.Combine(dir, "page.json.gz");
            await page.WriteAsync(pagePath, CancellationToken.None);
            var back = await ReportPageSnapshot.ReadAsync(pagePath, CancellationToken.None);
            Check(back?.Format == ReportPageSnapshot.FormatName && back.Logic.Objects.Count == 1, "Page model: envelope and logic version read back");
            var model = back?.Model is System.Text.Json.JsonElement el
                ? el.Deserialize<ProductionReportViewModel>(ReportPageSnapshot.JsonOptions)
                : null;
            Check(model is not null && model.PanelRows.Count == 2 && model.GrandTotalCharges == 1234.5678m
                  && model.PanelRows[0].ByMonth["2026-09"].BilledCharges == 60.123456m && model.PanelRows[0].ByYear[2026].ClaimCount == 10,
                "Page model binds back to ProductionReportViewModel with the same values");
            Check(PageModelIndexInfo.Parse(page.IndexJson())?.Logic.Objects.Count == 1, "Page model index entry carries the logic version");
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }

        Check(ReportSnapshotService.SafeName("PanelRows.Payers / x") == "PanelRows.Payers_x", "Section names are safe path segments");

        // Report logic: the objects a report ran, and what changed since last week.
        var sp = ReportLogicFingerprint.ObjectNames(new RecordedSqlCommand("s", "db", System.Data.CommandType.StoredProcedure, "[dbo].[usp_GetTD_ExecutiveSummary]")).ToList();
        Check(sp.SequenceEqual(["dbo.usp_GetTD_ExecutiveSummary"]), "Logic: a stored procedure call names the procedure");
        var text = ReportLogicFingerprint.ObjectNames(new RecordedSqlCommand("s", "db", System.Data.CommandType.Text,
            "EXEC dbo.usp_X @a = 1; SELECT * FROM [dbo].[vw_Y] t JOIN OtherDb.dbo.Z z ON t.Id = z.Id; EXEC usp_Bare")).ToList();
        Check(text.Contains("dbo.usp_X") && text.Contains("dbo.vw_Y") && text.Contains("dbo.usp_Bare") && !text.Contains("dbo.Z"),
            "Logic: two-part names and one-part EXEC targets, not three-part names");
        var before = new ReportLogicVersion { AppVersion = "1", Objects = [new("dbo.A", "P", "1", DateTime.UtcNow), new("dbo.B", "P", "1", DateTime.UtcNow)] };
        var after = new ReportLogicVersion { AppVersion = "1", Objects = [new("dbo.A", "P", "2", DateTime.UtcNow), new("dbo.C", "P", "1", DateTime.UtcNow)] };
        var changes = after.ChangesSince(before);
        Check(changes.Count == 3 && changes.Any(c => c.StartsWith("Changed: dbo.A")) && changes.Contains("Added: dbo.C") && changes.Contains("No longer used: dbo.B"),
            "Logic: changed, added and dropped objects are reported");
        Check(after.ChangesSince(null).Count == 0, "Logic: the first snapshot is the baseline");

        // The Denial Insight model: both weeks as sections, even when empty.
        var insight = ViewModelSections.Extract(new DenialInsightSnapshotModel { CurrentLab = "TexasDiagnostic" });
        Check(insight.Any(s => s.Name == "CurrentWeek" && s.Table.Columns.Contains("DenialCode")) && insight.Any(s => s.Name == "PreviousWeek"),
            "Denial Insight: Current Week and Previous Week sections with their columns");

        Console.WriteLine(failed == 0 ? "All self-tests passed." : $"{failed} self-test(s) FAILED.");
        return failed == 0 ? 0 : 1;
    }
}
