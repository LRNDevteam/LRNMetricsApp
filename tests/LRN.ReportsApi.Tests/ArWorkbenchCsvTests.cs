using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchCsvTests
{
    [Fact]
    public void Round_trips_quotes_commas_and_line_breaks()
    {
        var csv = ArWorkbenchCsv.Write(["Case ID", "Response"], [new[] { "CIP-000001", "Line one, with comma\nline \"two\"" }]);
        var rows = ArWorkbenchCsv.Parse(csv);
        Assert.Equal(2, rows.Count);
        Assert.Equal(["Case ID", "Response"], rows[0]);
        Assert.Equal("Line one, with comma\nline \"two\"", rows[1][1]);
    }

    [Fact]
    public void Excel_bom_and_crlf_are_handled()
    {
        var rows = ArWorkbenchCsv.Parse("﻿Case ID,Response\r\nCIP-1,ok\r\n");
        Assert.Equal("Case ID", rows[0][0]);
        Assert.Equal(["CIP-1", "ok"], rows[1]);
    }

    [Fact]
    public void Empty_trailing_cells_are_kept()
    {
        var rows = ArWorkbenchCsv.Parse("a,b,c\nx,,\n");
        Assert.Equal(["x", "", ""], rows[1]);
    }

    [Theory]
    [InlineData("=HYPERLINK(1)")]
    [InlineData("+1")]
    [InlineData("@cmd")]
    public void Formula_like_values_are_neutralised(string value)
        => Assert.StartsWith("'", ArWorkbenchCsv.Escape(value));
}
