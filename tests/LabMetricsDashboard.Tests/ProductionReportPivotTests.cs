using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using ClosedXML.Excel;
using LRN.ProductionReports.Models;
using LRN.ProductionReports.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

public sealed class ProductionReportPivotTests
{
    [Fact]
    public void Production_workbook_includes_client_style_excel_pivots()
    {
        var vm = new ProductionReportViewModel
        {
            Years = [2026],
            Months = ["2026-01"],
            PanelRows =
            [
                new ProductionPanelRow
                {
                    PanelName = "UTI",
                    ByMonth = { ["2026-01"] = new ProductionMonthCell(10, 1000m) },
                    ByYear = { [2026] = new ProductionYearTotal(10, 1000m) },
                    TotalClaims = 10,
                    TotalCharges = 1000m,
                    TopPayers =
                    [
                        new ProductionPayerDrillDown
                        {
                            PayerName = "MEDICARE FL",
                            ByMonth = { ["2026-01"] = new ProductionMonthCell(7, 700m) },
                            TotalClaims = 7,
                            TotalCharges = 700m,
                        },
                    ],
                },
            ],
            GrandTotalByMonth = { ["2026-01"] = new ProductionMonthCell(10, 1000m) },
            GrandTotalClaims = 10,
            GrandTotalCharges = 1000m,
            CptBreakdownYears = [2026],
            CptBreakdownMonths = ["2026-01"],
            CptBreakdownRows =
            [
                new CptBreakdownRow
                {
                    CptCode = "87798",
                    ByMonth = { ["2026-01"] = new CptBreakdownCell(13, 500m, 4) },
                    GrandTotalUnits = 13,
                    GrandTotalCharges = 500m,
                    GrandTotalClaims = 4,
                },
            ],
            PayerBreakdownYears = [2026],
            PayerBreakdownMonths = ["2026-01"],
            PayerBreakdownRows =
            [
                new PayerBreakdownRow
                {
                    PayerName = "MEDICARE FL",
                    ByMonth = { ["2026-01"] = 7 },
                    ByMonthCharges = { ["2026-01"] = 700m },
                    GrandTotal = 7,
                    GrandTotalCharges = 700m,
                },
            ],
            PayerPanelColumns = ["UTI"],
            PayerPanelRows =
            [
                new PayerPanelRow
                {
                    PayerName = "MEDICARE FL",
                    ByPanel = { ["UTI"] = new ProductionMonthCell(7, 700m) },
                    GrandTotalClaims = 7,
                    GrandTotalCharges = 700m,
                },
            ],
            PanelBreakdownYears = [2026],
            PanelBreakdownMonths = ["2026-01"],
            PanelBreakdownRows =
            [
                new PayerBreakdownRow
                {
                    PayerName = "UTI",
                    ByMonth = { ["2026-01"] = 10 },
                    ByMonthCharges = { ["2026-01"] = 1000m },
                    GrandTotal = 10,
                    GrandTotalCharges = 1000m,
                },
            ],
        };

        using var wb = ProductionReportExcelExportBuilder.CreateWorkbook(vm, "Cove");
        var names = wb.Worksheets.Select(s => s.Name).ToList();

        Assert.Contains("Insights", names);
        Assert.Contains("Production Summary", names);
        Assert.Contains("CPT Breakdown", names);
        Assert.Contains("Payer Breakdown", names);
        Assert.Contains("Payor x Panel", names);
        Assert.Contains("Panel Breakdown", names);
        Assert.Contains("Master", names);
        Assert.Contains("Data 1", names);

        Assert.Contains(wb.Worksheets.Worksheet("Production Summary").PivotTables, p => p.Name == "ProductionSummaryPivot");
        Assert.Contains(wb.Worksheets.Worksheet("CPT Breakdown").PivotTables, p => p.Name == "CptPivot");
        Assert.Contains(wb.Worksheets.Worksheet("Payer Breakdown").PivotTables, p => p.Name == "PayorPivot");
        Assert.Contains(wb.Worksheets.Worksheet("Payor x Panel").PivotTables, p => p.Name == "PayorPanelPivot");
        Assert.Contains(wb.Worksheets.Worksheet("Panel Breakdown").PivotTables, p => p.Name == "PanelPivot");

        var cpt = wb.Worksheets.Worksheet("CPT Breakdown").PivotTables.First();
        Assert.Equal(XLPivotTableTheme.PivotStyleMedium21, cpt.Theme);
        Assert.False(cpt.ShowRowStripes);
        Assert.False(cpt.ShowColumnStripes);
        Assert.False(cpt.ShowValuesRow);
        Assert.False(cpt.AutofitColumns);
        Assert.Equal("CPTs", cpt.RowHeaderCaption);
        Assert.Equal("CPT Breakdown", cpt.ColumnHeaderCaption);
        Assert.True(wb.Worksheets.Worksheet("CPT Breakdown").Column(1).Width >= 40);

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        var raw = ms.ToArray();
        Assert.True(raw.Length > 0);
        AssertZipHasEntry(raw, "pivotCache/pivotCacheDefinition1.xml");

        var fixedBytes = OpenXmlPivotCacheFix.Apply(raw);
        AssertZipHasEntry(fixedBytes, "xl/pivotCache/pivotCacheDefinition1.xml");
        AssertZipDoesNotHavePrefix(fixedBytes, "pivotCache/");
        AssertZipContains(fixedBytes, "xl/pivotTables/pivotTable.xml", "firstHeaderRow=\"1\"");
        AssertZipContains(fixedBytes, "xl/pivotTables/pivotTable.xml", "PivotStyleMedium21");
        AssertZipDoesNotContain(fixedBytes, "xl/pivotTables/", "PivotStyleMedium16");
        AssertZipDoesNotContain(fixedBytes, "xl/styles.xml", "CovePivotHeader");
        AssertZipDoesNotContain(fixedBytes, "xl/pivotTables/", "CovePivotHeader");
        AssertZipContains(fixedBytes, "xl/pivotTables/pivotTable.xml", "outline=\"1\"");
        AssertZipContains(fixedBytes, "xl/pivotTables/pivotTable.xml", "useAutoFormatting=\"1\"");
        AssertZipContains(fixedBytes, "xl/theme/theme1.xml", "70AD47");
        AssertZipDoesNotContain(fixedBytes, "xl/theme/theme1.xml", "F79646");
        // reference/@field is a UInt32 so the Values axis must be 4294967294
        // there, while pivotArea/@field is an Int32 and keeps -2.
        AssertZipDoesNotContain(fixedBytes, "xl/pivotTables/", "<reference field=\"-2\"");
        AssertZipContains(fixedBytes, "xl/pivotTables/pivotTable.xml", "type=\"origin\"");
        AssertPivotTableXmlWellFormed(fixedBytes);
        AssertStylesXmlSafe(fixedBytes);
        AssertZipContains(fixedBytes, "xl/styles.xml", "fgColor rgb=\"FF385624\"");
        AssertZipContains(fixedBytes, "xl/styles.xml", "fgColor rgb=\"FFE2EFDA\"");
        AssertZipContains(fixedBytes, "xl/styles.xml", "fgColor rgb=\"FFFFFFFF\"");
        AssertZipDoesNotContain(fixedBytes, "xl/styles.xml", "fgColor auto=\"1\"");
        ExcelRepairGuard.AssertOpensWithoutRepair(fixedBytes);
        using (var open = DocumentFormat.OpenXml.Packaging.SpreadsheetDocument.Open(new MemoryStream(fixedBytes), false))
            Assert.NotNull(open.WorkbookPart);
    }

    private static void AssertZipHasEntry(byte[] zipBytes, string fullName)
    {
        using var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read);
        Assert.Contains(zip.Entries, e => e.FullName.Equals(fullName, StringComparison.OrdinalIgnoreCase));
    }

    private static void AssertZipDoesNotHavePrefix(byte[] zipBytes, string prefix)
    {
        using var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read);
        Assert.DoesNotContain(zip.Entries, e => e.FullName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
    }

    private static void AssertZipContains(byte[] zipBytes, string entryName, string snippet)
    {
        using var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read);
        var entry = zip.Entries.First(e => e.FullName.Equals(entryName, StringComparison.OrdinalIgnoreCase));
        using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
        var xml = reader.ReadToEnd();
        Assert.Contains(snippet, xml, StringComparison.Ordinal);
    }

    private static void AssertZipDoesNotContain(byte[] zipBytes, string entryPrefix, string snippet)
    {
        using var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read);
        foreach (var entry in zip.Entries.Where(e =>
                     e.FullName.StartsWith(entryPrefix, StringComparison.OrdinalIgnoreCase)
                     && e.FullName.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
                     && !e.FullName.Contains("/_rels/", StringComparison.Ordinal)))
        {
            using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
            var xml = reader.ReadToEnd();
            Assert.DoesNotContain(snippet, xml, StringComparison.Ordinal);
        }
    }

    private static void AssertPivotTableXmlWellFormed(byte[] zipBytes)
    {
        using var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read);
        var doc = new System.Xml.XmlDocument { XmlResolver = null };
        foreach (var entry in zip.Entries.Where(e =>
                     e.FullName.StartsWith("xl/pivotTables/pivotTable", StringComparison.OrdinalIgnoreCase)
                     && e.FullName.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
                     && !e.FullName.Contains("/_rels/", StringComparison.Ordinal)))
        {
            using var stream = entry.Open();
            doc.Load(stream);
        }
    }

    private static void AssertStylesXmlSafe(byte[] zipBytes)
    {
        using var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read);
        var entry = zip.Entries.First(e => e.FullName.Equals("xl/styles.xml", StringComparison.OrdinalIgnoreCase));
        using var ms = new MemoryStream();
        using (var src = entry.Open())
            src.CopyTo(ms);
        var bytes = ms.ToArray();
        Assert.True(bytes.Length > 0);
        Assert.Equal((byte)'<', bytes[0]);
        var xml = Encoding.UTF8.GetString(bytes);
        Assert.DoesNotContain("utf-16", xml, StringComparison.OrdinalIgnoreCase);
        var doc = new System.Xml.XmlDocument { XmlResolver = null };
        doc.LoadXml(xml);
        Assert.Equal("styleSheet", doc.DocumentElement!.LocalName);
        Assert.DoesNotContain("CovePivotHeader", xml, StringComparison.Ordinal);
        Assert.Contains("</", xml, StringComparison.Ordinal); // not truncated
    }
}
