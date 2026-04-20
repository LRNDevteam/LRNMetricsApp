using ClosedXML.Excel;
using CodingMasterGenerator.Models;

namespace CodingMasterGenerator.Services;

/// <summary>
/// Exports the Coding Master output rows to a formatted Excel workbook.
/// </summary>
public static class CodingMasterExcelWriter
{
    private const string SheetName = "CodingMaster";

    // Header style
    private static readonly XLColor HeaderBg = XLColor.FromHtml("#1B3A4B");
    private static readonly XLColor HeaderFg = XLColor.White;

    // Alternating row colors
    private static readonly XLColor EvenRowBg = XLColor.FromHtml("#F0F4F8");
    private static readonly XLColor OddRowBg = XLColor.White;

    /// <summary>Creates and saves the Excel workbook. Returns the output file path.</summary>
    public static string Write(List<CodingMasterOutputRow> rows, string outputFolder, string labName, string runId)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentException.ThrowIfNullOrWhiteSpace(outputFolder);
        ArgumentException.ThrowIfNullOrWhiteSpace(runId);

        Directory.CreateDirectory(outputFolder);

        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var fileName = $"{labName}_CodingMaster_{runId}_{timestamp}.xlsx";
        var filePath = Path.Combine(outputFolder, fileName);

        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet(SheetName);

        // Column headers
        string[] headers =
        [
            "S.No",
            "Production Panel Name",
            "Coding Master Panel name",
            "Payer",
            "Payer_Common_Code",
            "Procedure",
            "Total Billed Charge",
            "Condition If any"
        ];

        for (int c = 0; c < headers.Length; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = headers[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = HeaderFg;
            cell.Style.Fill.BackgroundColor = HeaderBg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            cell.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
        }

        // Freeze header row
        ws.SheetView.FreezeRows(1);

        // Auto-filter
        ws.Range(1, 1, 1, headers.Length).SetAutoFilter();

        // Data rows
        for (int i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            int r = i + 2;
            var bgColor = i % 2 == 0 ? EvenRowBg : OddRowBg;

            ws.Cell(r, 1).Value = row.SNo;
            ws.Cell(r, 2).Value = row.ProductionPanelName;
            ws.Cell(r, 3).Value = row.CodingMasterPanelName;
            ws.Cell(r, 4).Value = row.Payer;
            ws.Cell(r, 5).Value = row.Payer_Common_Code;
            ws.Cell(r, 6).Value = row.Procedure;
            ws.Cell(r, 7).Value = row.TotalBilledCharge;
            ws.Cell(r, 8).Value = row.ConditionIfAny;

            // Format charge column as currency
            ws.Cell(r, 7).Style.NumberFormat.Format = "#,##0.00";

            // Bold the Payer_Common_Code column
            ws.Cell(r, 5).Style.Font.Bold = true;

            // Alternating row background
            var range = ws.Range(r, 1, r, headers.Length);
            range.Style.Fill.BackgroundColor = bgColor;
            range.Style.Border.BottomBorder = XLBorderStyleValues.Hair;
            range.Style.Border.BottomBorderColor = XLColor.FromHtml("#E0E0E0");
        }

        // Column widths
        ws.Column(1).Width = 6;    // S.No
        ws.Column(2).Width = 26;   // Production Panel Name
        ws.Column(3).Width = 30;   // Coding Master Panel name
        ws.Column(4).Width = 24;   // Payer
        ws.Column(5).Width = 22;   // Payer_Common_Code
        ws.Column(6).Width = 80;   // Procedure
        ws.Column(7).Width = 20;   // Total Billed Charge
        ws.Column(8).Width = 20;   // Condition If any

        wb.SaveAs(filePath);
        return filePath;
    }
}
