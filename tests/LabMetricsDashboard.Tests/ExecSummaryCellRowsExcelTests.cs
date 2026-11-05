using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Linq;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

public sealed class ExecSummaryCellRowsExcelTests
{
    private static readonly List<(string, string)> Info =
    [
        ("Lab", "Beech_Tree"),
        ("Report generated", "29-Oct-2026 07:15 CET"),
        ("Week Range", "10.16.2026 - 10.22.2026"),
        ("Filters used", "Panels: Toxicology"),
    ];

    [Fact]
    public void Popup_excel_has_report_details_rules_and_rows()
    {
        var head = new ExecSummaryCellRowsResult
        {
            SourceTable = "dbo.ClaimLevelData", Measure = "Sum of ChargeAmount", AmountColumn = "ChargeAmount",
            TotalRows = 2, TotalAmount = 300.50m,
        };
        head.Rules.Add(new ExecSummaryCellRule("Row rule", "BilledUnbilled = Billed"));

        var table = new DataTable();
        table.Columns.Add("ClaimID", typeof(string));
        table.Columns.Add("Amount", typeof(decimal));
        table.Rows.Add("C1", 100.25m);
        table.Rows.Add("C2", 200.25m);

        var wb = Build(head, table);
        Assert.Equal(["Summary", "Rows"], wb.Worksheets.Select(s => s.Name));

        var sum = wb.Worksheet("Summary");
        Assert.Equal("Beech_Tree - Executive Summary - Total Billed ($) - Grand Total", sum.Cell(1, 1).GetString());
        Assert.Equal("A1:B1", sum.Cell(1, 1).MergedRange().RangeAddress.ToString());
        Assert.Equal("Lab", sum.Cell(3, 1).GetString());
        Assert.Equal("Beech_Tree", sum.Cell(3, 2).GetString());
        Assert.Equal("Report generated", sum.Cell(4, 1).GetString());
        Assert.Equal("29-Oct-2026 07:15 CET", sum.Cell(4, 2).GetString());
        Assert.Equal("Week Range", sum.Cell(5, 1).GetString());
        Assert.Equal("10.16.2026 - 10.22.2026", sum.Cell(5, 2).GetString());
        Assert.Equal("Filters used", sum.Cell(6, 1).GetString());
        Assert.Equal("Panels: Toxicology", sum.Cell(6, 2).GetString());
        Assert.Equal("Grid value", sum.Cell(8, 1).GetString());
        Assert.Equal("$300.50", sum.Cell(8, 2).GetString());
        Assert.Equal("Rows found", sum.Cell(9, 1).GetString());
        Assert.Equal(2, sum.Cell(9, 2).GetValue<int>());
        Assert.Equal("Sum of ChargeAmount", sum.Cell(10, 1).GetString());
        Assert.Equal(300.50m, sum.Cell(10, 2).GetValue<decimal>());
        Assert.Equal("How this value is calculated", sum.Cell(12, 1).GetString());
        Assert.Equal("Row rule", sum.Cell(13, 1).GetString());
        Assert.Equal("BilledUnbilled = Billed", sum.Cell(13, 2).GetString());

        // The Rows sheet holds only the rows: header on row 1, data from row 2.
        var ws = wb.Worksheet("Rows");
        Assert.Equal("ClaimID", ws.Cell(1, 1).GetString());
        Assert.Equal("Amount", ws.Cell(1, 2).GetString());
        Assert.Equal("C1", ws.Cell(2, 1).GetString());
        Assert.Equal(200.25m, ws.Cell(3, 2).GetValue<decimal>());
        Assert.Contains("$", ws.Cell(3, 2).Style.NumberFormat.Format);
        Assert.Equal(3, ws.LastRowUsed()!.RowNumber());
        Assert.Equal(1, ws.SheetView.SplitRow);
        Assert.NotNull(ws.AutoFilter);
    }

    [Fact]
    public void Formula_breakdown_hides_flag_columns()
    {
        var head = new ExecSummaryCellRowsResult { Measure = "Formula", TotalAmount = 41.56m, IsFormula = true };
        head.Rules.Add(new ExecSummaryCellRule("Formula", "(X + AA + AB) / G"));

        var table = new DataTable();
        table.Columns.Add("Section", typeof(string));
        table.Columns.Add("Component", typeof(string));
        table.Columns.Add("Value", typeof(decimal));
        table.Columns.Add("IsMoney", typeof(bool));
        table.Columns.Add("IsTotal", typeof(bool));
        table.Rows.Add("Numerator", "Total Payments ($)", 1000m, true, true);
        table.Rows.Add("Result", "Average Payment ($)", 41.56m, true, true);

        var wb = Build(head, table);
        Assert.Equal("Result", wb.Worksheet("Summary").Search("Result").Single().GetString());

        var ws = wb.Worksheet("Rows");
        Assert.Equal("Section", ws.Cell(1, 1).GetString());
        Assert.Empty(ws.Search("IsMoney"));
        Assert.Equal(41.56m, ws.Cell(3, 3).GetValue<decimal>());
        Assert.True(ws.Cell(3, 3).Style.Font.Bold);
    }

    private static XLWorkbook Build(ExecSummaryCellRowsResult head, DataTable rows)
    {
        var ms = new MemoryStream();
        using (var reader = rows.CreateDataReader())
            ExecSummaryCellRowsExcelBuilder.Write(ms, head, reader, "Beech_Tree", "Total Billed ($)", "Grand Total", "$300.50", Info);

        ms.Position = 0;
        using (var doc = DocumentFormat.OpenXml.Packaging.SpreadsheetDocument.Open(ms, false))
        {
            var errors = new DocumentFormat.OpenXml.Validation.OpenXmlValidator().Validate(doc)
                .Select(e => $"{e.Path?.XPath}: {e.Description}").ToList();
            Assert.True(errors.Count == 0, string.Join(Environment.NewLine, errors));
        }
        ms.Position = 0;
        return new XLWorkbook(ms);
    }
}
