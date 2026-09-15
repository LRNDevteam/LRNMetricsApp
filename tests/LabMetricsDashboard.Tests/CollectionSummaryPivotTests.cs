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
}
