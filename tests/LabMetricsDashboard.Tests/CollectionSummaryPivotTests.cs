using System;
using System.IO;
using System.Linq;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

public sealed class CollectionSummaryPivotTests
{
    [Fact]
    public void Collection_workbook_includes_client_style_excel_pivots()
    {
        var vm = new CollectionSummaryViewModel
        {
            InsurancePaymentPct =
            [
                new InsurancePaymentPctRow(1, "MEDICARE FL", 7, 700m, 700m, 1000m, BillYear: 2026, BillMonth: 1),
            ],
            InsuranceVsPayment =
            [
                new InsuranceVsPaymentRow("MEDICARE FL", 2026, 1, 7, 700m, 70m),
            ],
            PanelPayments =
            [
                new PanelPaymentRow("UTI", 10, 1000m, 2026, 1),
            ],
            InsuranceAging =
            [
                new InsuranceAgingRow("MEDICARE FL", 1, 100m, 2, 200m, 0, 0m, 0, 0m, 3, 300m, 6, 600m),
            ],
            CptPaymentPct =
            [
                new CptPaymentPctRow("87798", 13m, 500m, 800m),
            ],
            ProviderSummary = new ProviderSummaryResult
            {
                Rows = [new ProviderSummaryRow(1, "Dr Smith", 4, 400m, 50m, 10m)],
                GrandNoClaims = 4,
                GrandInsurancePayments = 400m,
                GrandInsuranceBalance = 50m,
                GrandPatientBalance = 10m,
            },
            RepPayments = new RepPaymentResult(
            [
                new RepPaymentFlatRow("Jane Doe", 2026, 1, 5, 500m),
            ]),
            AvgPaymentsLast3Months = new PanelAveragesResult(
            [
                new PanelAveragesRow
                {
                    PanelName = "UTI",
                    Metrics = new PanelAveragesMetrics(10, 1000m, 400m, 4, 200m, 8, 350m, 3, 120m, 6, 250m),
                },
            ]),
            MonthlyClaimVolume = new CollectionMonthlyVolumePivot
            {
                Years = [2026],
                Periods = [new CollectionMonthlyPeriod(2026, 1)],
                PanelRows =
                [
                    new CollectionPanelRow
                    {
                        PanelName = "UTI",
                        ByMonth = { ["2026-01"] = new CollectionMonthlyCell(10, 1000m) },
                        TotalEncounters = 10,
                        TotalInsurancePaid = 1000m,
                    },
                ],
            },
        };

        using var wb = CollectionSummaryExcelExportBuilder.CreateWorkbook(vm, [], [], "Cove");

        Assert.Contains("Insights", wb.Worksheets.Select(s => s.Name));
        Assert.Contains(wb.Worksheets.Worksheet("Insurance vs Payment %").PivotTables, p => p.Name == "InsuranceVsPaymentsPctPivot");
        Assert.Contains(wb.Worksheets.Worksheet("Insurance Vs Payments").PivotTables, p => p.Name == "InsuranceVsPaymentsPivot");
        Assert.Contains(wb.Worksheets.Worksheet("Panel Vs Payments").PivotTables, p => p.Name == "PanelVsPaymentsPivot");
        Assert.Contains(wb.Worksheets.Worksheet("No Response Vs Aging").PivotTables, p => p.Name == "NoResponseVsAgingPivot");
        Assert.Contains(wb.Worksheets.Worksheet("CPT vs Payment %").PivotTables, p => p.Name == "CptVsPaymentPctPivot");
        Assert.Contains(wb.Worksheets.Worksheet("Provider Summary").PivotTables, p => p.Name == "ProviderSummaryPivot");
        Assert.Contains(wb.Worksheets.Worksheet("Rep Vs Payment").PivotTables, p => p.Name == "RepVsPaymentPivot");
        Assert.Contains("Avg payments_Last 3 Months", wb.Worksheets.Select(s => s.Name));

        var cptPct = vm.CptPaymentPct[0].PaymentPct;
        Assert.Equal(62.5m, cptPct);

        var panel = wb.Worksheets.Worksheet("Panel Vs Payments").PivotTables.First();
        Assert.Equal(XLPivotTableTheme.PivotStyleMedium21, panel.Theme);
        Assert.False(panel.ShowRowStripes);
        Assert.False(panel.ShowColumnStripes);
        Assert.False(panel.ShowValuesRow);
        Assert.False(panel.AutofitColumns);
        Assert.Equal("Panel", panel.RowHeaderCaption);
        Assert.Equal("Panel Vs Payments", panel.ColumnHeaderCaption);
        Assert.True(wb.Worksheets.Worksheet("Panel Vs Payments").Column(1).Width >= 40);

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        var fixedBytes = LRN.ProductionReports.Services.OpenXmlPivotCacheFix.Apply(ms.ToArray());
        Assert.True(fixedBytes.Length > 0);
        using var zip = new System.IO.Compression.ZipArchive(new MemoryStream(fixedBytes));
        Assert.Contains(zip.Entries, e => e.FullName.StartsWith("xl/pivotCache/", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(zip.Entries, e => e.FullName.StartsWith("pivotCache/", StringComparison.OrdinalIgnoreCase));
        var theme = zip.Entries.First(e => e.FullName.Equals("xl/theme/theme1.xml", StringComparison.OrdinalIgnoreCase));
        string themeXml;
        using (var reader = new StreamReader(theme.Open()))
            themeXml = reader.ReadToEnd();
        Assert.Contains("70AD47", themeXml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("F79646", themeXml, StringComparison.OrdinalIgnoreCase);

        var stylesEntry = zip.Entries.First(e => e.FullName.Equals("xl/styles.xml", StringComparison.OrdinalIgnoreCase));
        string stylesXml;
        using (var stylesReader = new StreamReader(stylesEntry.Open()))
            stylesXml = stylesReader.ReadToEnd();
        Assert.DoesNotContain("CovePivotHeader", stylesXml, StringComparison.Ordinal);
        Assert.Equal('<', stylesXml[0] == '\uFEFF' ? stylesXml[1] : stylesXml[0]);
        var stylesDoc = new System.Xml.XmlDocument { XmlResolver = null };
        stylesDoc.LoadXml(stylesXml);
        ExcelRepairGuard.AssertDifferentialFillsAreNotAuto(stylesXml, "385624");
        ExcelRepairGuard.AssertOpensWithoutRepair(fixedBytes);

        var doc = new System.Xml.XmlDocument { XmlResolver = null };
        var sawMedium21 = false;
        foreach (var entry in zip.Entries.Where(e =>
                     e.FullName.StartsWith("xl/pivotTables/pivotTable", StringComparison.OrdinalIgnoreCase)
                     && e.FullName.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
                     && !e.FullName.Contains("/_rels/", StringComparison.Ordinal)))
        {
            using var stream = entry.Open();
            using var reader = new StreamReader(stream);
            var xml = reader.ReadToEnd();
            doc.LoadXml(xml);
            Assert.Contains("PivotStyleMedium21", xml, StringComparison.Ordinal);
            Assert.DoesNotContain("PivotStyleMedium16", xml, StringComparison.Ordinal);
            // reference/@field is a UInt32 so the Values axis must be 4294967294
            // there, while pivotArea/@field is an Int32 and keeps -2.
            Assert.DoesNotContain("<reference field=\"-2\"", xml, StringComparison.Ordinal);
            Assert.Contains("type=\"origin\"", xml, StringComparison.Ordinal);
            sawMedium21 = true;
        }
        Assert.True(sawMedium21);
    }

    [Fact]
    public void Aging_sheet_has_grand_total_and_wide_balance_columns()
    {
        var vm = new CollectionSummaryViewModel
        {
            InsuranceAging =
            [
                new InsuranceAgingRow("MEDICARE FLORIDA - MCR", 220, 194_887m, 66, 66_418m, 25, 24_304m, 8, 7_299m, 34, 30_057m, 353, 322_966m),
                new InsuranceAgingRow("UHC - UHC", 112, 32_864m, 86, 35_725m, 51, 13_291m, 47, 11_537m, 313, 89_043m, 609, 182_460m),
            ],
        };

        using var wb = CollectionSummaryExcelExportBuilder.CreateWorkbook(vm, [], [], "Rising_Tides");

        var ws = wb.Worksheets.Worksheet("No Response Vs Aging");
        Assert.Equal("Grand Total", ws.Cell(5, 1).GetString());
        Assert.Equal(332, ws.Cell(5, 2).GetValue<int>());
        Assert.Equal(505_426m, ws.Cell(5, 13).GetValue<decimal>());
        for (int c = 3; c <= 13; c += 2)
            Assert.True(ws.Column(c).Width >= 17, $"balance column {c} too narrow: {ws.Column(c).Width}");
    }

    [Fact]
    public void Rising_Tides_workbook_includes_genetics_vs_id_avg_side_by_side()
    {
        var vm = new CollectionSummaryViewModel
        {
            SelectedLab = "RisingTides",
            ShowGeneticsVsIdAvg = true,
            GeneticsVsIdAvg = new GeneticsVsIdAvgResult
            {
                FullyPaid = new GeneticsVsIdAvgBlock
                {
                    Rows =
                    [
                        new GeneticsVsIdAvgRow("UTI ABR Panel", 643, 298_700m),
                        new GeneticsVsIdAvgRow("Wound Panel", 291, 157_967m),
                    ],
                },
                ExcludingNoResponse = new GeneticsVsIdAvgBlock
                {
                    Rows =
                    [
                        new GeneticsVsIdAvgRow("UTI ABR Panel", 1704, 311_847m),
                        new GeneticsVsIdAvgRow("Genesis 2", 34, 17m),
                    ],
                },
            },
        };

        using var wb = CollectionSummaryExcelExportBuilder.CreateWorkbook(vm, [], [], "RisingTides");

        var ws = wb.Worksheets.Worksheet("Genetics vs ID Avg");
        Assert.Equal("Fully Paid", ws.Cell(3, 2).GetString());
        Assert.Equal("Panel Group (IDs)", ws.Cell(5, 1).GetString());
        Assert.Equal("Panel Group (IDs)", ws.Cell(5, 6).GetString());
        Assert.Equal("Grand Total", ws.Cell(8, 1).GetString());
        Assert.Equal(934, ws.Cell(8, 2).GetValue<int>());
        Assert.Equal(456_667m, ws.Cell(8, 3).GetValue<decimal>());
        Assert.Equal(Math.Round(456_667m / 934, 2), Math.Round(ws.Cell(8, 4).GetValue<decimal>(), 2));
        Assert.Equal("Genesis 2", ws.Cell(7, 6).GetString());
        Assert.Equal(0.5m, ws.Cell(7, 9).GetValue<decimal>());

        vm.ShowGeneticsVsIdAvg = false;
        using var otherLab = CollectionSummaryExcelExportBuilder.CreateWorkbook(vm, [], [], "Cove");
        Assert.DoesNotContain("Genetics vs ID Avg", otherLab.Worksheets.Select(s => s.Name));
    }

    [Fact]
    public void Rising_Tides_workbook_splits_avg_payments_by_dos_and_check_date()
    {
        static PanelAveragesResult Result(int claims, decimal charges, int from, int to) =>
            new([new PanelAveragesRow
            {
                PanelName = "UTI ABR Panel",
                Metrics = new PanelAveragesMetrics(claims, charges, 100m, 1, 50m, 2, 100m, 2, 90m, 1, 40m),
            }])
            {
                WindowFrom = new DateOnly(2026, 3, from),
                WindowTo   = new DateOnly(2026, 9, to),
            };

        var vm = new CollectionSummaryViewModel
        {
            SelectedLab = "RisingTides",
            ShowAvgPaymentsByDateBasis = true,
            AvgPaymentsDos = Result(10, 1_000m, 23, 22),
            AvgPayments    = Result(12, 1_200m, 25, 24),
            AvgPaymentsLast3Months = Result(5, 500m, 1, 1),
        };

        using var wb = CollectionSummaryExcelExportBuilder.CreateWorkbook(vm, [], [], "RisingTides");
        var names = wb.Worksheets.Select(s => s.Name).ToList();

        Assert.Contains("Avg Payments - DOS", names);
        Assert.Contains("Avg Payments - Check Date", names);
        Assert.DoesNotContain("Avg payments_Last 3 Months", names);
        Assert.DoesNotContain("Avg Payments", names);

        var dos = wb.Worksheets.Worksheet("Avg Payments - DOS");
        Assert.Contains("Based on Date of Service (03/23/2026 - 09/22/2026)", dos.Cell(1, 1).GetString());
        Assert.Equal(10, dos.Cell(4, 2).GetValue<int>());

        var chk = wb.Worksheets.Worksheet("Avg Payments - Check Date");
        Assert.Contains("Based on Check Date (03/25/2026 - 09/24/2026)", chk.Cell(1, 1).GetString());
        Assert.Equal(12, chk.Cell(4, 2).GetValue<int>());
    }
}
