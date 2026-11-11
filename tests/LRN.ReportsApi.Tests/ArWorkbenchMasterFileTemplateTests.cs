using System.Linq;
using ClosedXML.Excel;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchMasterFileTemplateTests
{
    // The downloaded template, filled with the given rows (column name -> value) on each sheet.
    private static MemoryStream Filled(
        IEnumerable<Dictionary<string, object>> claims,
        IEnumerable<Dictionary<string, object>> lines,
        Action<XLWorkbook>? tweak = null)
    {
        using var wb = new XLWorkbook(new MemoryStream(ArWorkbenchMasterFileTemplate.Build()));
        Fill(wb.Worksheet("Claim Level"), claims);
        Fill(wb.Worksheet("Line Level"), lines);
        tweak?.Invoke(wb);
        var ms = new MemoryStream();
        wb.SaveAs(ms);
        ms.Position = 0;
        return ms;
    }

    private static void Fill(IXLWorksheet sheet, IEnumerable<Dictionary<string, object>> rows)
    {
        var columns = sheet.Row(1).CellsUsed().ToDictionary(c => c.GetString(), c => c.Address.ColumnNumber);
        var r = 2;
        foreach (var row in rows)
        {
            foreach (var (name, value) in row)
                sheet.Cell(r, columns[name]).Value = XLCellValue.FromObject(value);
            r++;
        }
    }

    private static Dictionary<string, object> Claim(string id, object? charge = null) => new()
    {
        ["ClaimID"] = id, ["PayerName_Raw"] = "Aetna", ["DateofService"] = new DateTime(2026, 10, 1),
        ["ChargeAmount"] = charge ?? 250.5, ["ClaimStatus"] = "Denied", ["DenialCode"] = "CO-16"
    };

    private static Dictionary<string, object> Line(string id, string cpt = "87798") => new()
    {
        ["ClaimID"] = id, ["PayerName_Raw"] = "Aetna", ["DateofService"] = new DateTime(2026, 10, 1),
        ["CPTCode"] = cpt, ["ChargeAmount"] = 125.25, ["Units"] = 1
    };

    [Fact]
    public void Template_has_the_guide_and_both_data_sheets_with_the_schema_headers_on_row_1()
    {
        using var wb = new XLWorkbook(new MemoryStream(ArWorkbenchMasterFileTemplate.Build()));

        Assert.Equal(["Instructions", "Claim Level", "Line Level"], wb.Worksheets.Select(s => s.Name).ToArray());
        var claimHeaders = wb.Worksheet("Claim Level").Row(1).CellsUsed().Select(c => c.GetString()).ToList();
        Assert.Equal(ArWorkbenchMasterFileTemplate.ClaimSchema.Columns.Select(c => c.Name), claimHeaders);
        Assert.Contains("CPTCode", wb.Worksheet("Line Level").Row(1).CellsUsed().Select(c => c.GetString()));
        // No sample rows: nothing below the header can be loaded by mistake.
        Assert.Equal(1, wb.Worksheet("Claim Level").LastRowUsed()!.RowNumber());
    }

    [Fact]
    public void A_correctly_filled_template_is_valid_and_counts_rows()
    {
        using var file = Filled([Claim("1001"), Claim("1002")], [Line("1001"), Line("1001", "87481"), Line("1002")]);

        var result = ArWorkbenchMasterFileTemplate.Validate(file);

        Assert.True(result.Valid, string.Join(" | ", result.Errors));
        Assert.Equal(2, result.ClaimRows);
        Assert.Equal(3, result.LineRows);
        Assert.Empty(result.Warnings);
    }

    [Fact]
    public void A_missing_sheet_is_an_error()
    {
        using var file = Filled([Claim("1001")], [Line("1001")], wb => wb.Worksheet("Line Level").Delete());

        var result = ArWorkbenchMasterFileTemplate.Validate(file);

        Assert.False(result.Valid);
        Assert.Contains(result.Errors, e => e.Contains("no \"Line Level\" sheet"));
    }

    [Fact]
    public void A_removed_required_column_is_an_error_but_a_removed_optional_column_is_not()
    {
        using var file = Filled([Claim("1001")], [Line("1001")], wb =>
        {
            var claims = wb.Worksheet("Claim Level");
            claims.Column(claims.Row(1).CellsUsed().First(c => c.GetString() == "AccessionNumber").Address.ColumnNumber).Delete();
            var lines = wb.Worksheet("Line Level");
            lines.Column(lines.Row(1).CellsUsed().First(c => c.GetString() == "CPTCode").Address.ColumnNumber).Delete();
        });

        var result = ArWorkbenchMasterFileTemplate.Validate(file);

        Assert.Equal(["\"Line Level\": required column(s) missing: CPTCode."], result.Errors);
    }

    [Fact]
    public void Blank_required_values_and_bad_amounts_are_reported_by_row_number_only()
    {
        var blankId = Claim("");
        using var file = Filled([Claim("1001"), blankId, Claim("1003", "TBD-SECRET")], [Line("1001")]);

        var result = ArWorkbenchMasterFileTemplate.Validate(file);

        Assert.False(result.Valid);
        Assert.Contains("\"Claim Level\": required column \"ClaimID\" is empty on 1 row(s) (row 3).", result.Errors);
        Assert.Contains("\"Claim Level\": \"ChargeAmount\" is not a valid amount on 1 row(s) (row 4).", result.Errors);
        // The workbook is PHI: no cell value ever comes back in a message.
        Assert.DoesNotContain(result.Errors.Concat(result.Warnings), m => m.Contains("TBD-SECRET"));
    }

    [Fact]
    public void Lines_without_a_claim_and_unknown_columns_are_warnings()
    {
        using var file = Filled([Claim("1001")], [Line("1001"), Line("9999")], wb =>
            wb.Worksheet("Claim Level").Cell(1, 40).Value = "My Own Column");

        var result = ArWorkbenchMasterFileTemplate.Validate(file);

        Assert.True(result.Valid, string.Join(" | ", result.Errors));
        Assert.Contains(result.Warnings, w => w.StartsWith("1 distinct ClaimID(s) on \"Line Level\""));
        Assert.Contains(result.Warnings, w => w.Contains("My Own Column"));
    }

    [Fact]
    public void A_non_excel_file_is_rejected()
    {
        using var file = new MemoryStream("ClaimID,ChargeAmount\n1,2\n"u8.ToArray());

        var result = ArWorkbenchMasterFileTemplate.Validate(file);

        Assert.False(result.Valid);
        Assert.Single(result.Errors);
    }
}
