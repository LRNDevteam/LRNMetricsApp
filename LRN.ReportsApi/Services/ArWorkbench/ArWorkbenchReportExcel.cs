using ClosedXML.Excel;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Any <see cref="ArWorkbenchReport"/> as one Excel sheet in the house theme (DenialExcelTheme):
/// title bar, data date, header row, rows typed by column format (totals bold on the total fill,
/// detail rows indented), then the insights and the definitions note.
/// </summary>
public static class ArWorkbenchReportExcel
{
    public static byte[] Build(ArWorkbenchReport report)
    {
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add(SheetName(report.Title));
        DenialExcelTheme.ApplyDefaults(ws);
        ws.SetTabColor(DenialExcelTheme.TabGreen);
        var cols = Math.Max(1, report.Columns.Count);

        var title = ws.Range(1, 1, 1, cols).Merge();
        title.Value = report.Code is null ? report.Title : $"{report.Code} · {report.Title}";
        title.Style.Font.Bold = true;
        title.Style.Font.FontSize = DenialExcelTheme.FontSizeTitle;
        title.Style.Font.FontColor = XLColor.White;
        title.Style.Fill.BackgroundColor = DenialExcelTheme.TitleBg;
        var asOf = report.DataRefreshedOn is { } on ? $"Data as of {on:MMM dd, yyyy}" : "Data date not available";
        ws.Cell(2, 1).Value = report.From is { } f && report.To is { } t ? $"Period {f:MMM dd, yyyy} – {t:MMM dd, yyyy} · {asOf}" : asOf;
        ws.Cell(2, 1).Style.Font.Italic = true;

        const int headerRow = 4;
        for (var c = 0; c < report.Columns.Count; c++)
            DenialExcelTheme.StyleHeaderCell(ws.Cell(headerRow, c + 1).SetValue(report.Columns[c].Label));

        var row = headerRow + 1;
        foreach (var r in report.Rows)
        {
            for (var c = 0; c < report.Columns.Count; c++)
            {
                var cell = ws.Cell(row, c + 1);
                var value = c < r.Values.Count ? r.Values[c] : null;
                SetValue(cell, value, report.Columns[c].Format);
                if (c == 0 && r.Level > 0) cell.Style.Alignment.Indent = r.Level * 2;
            }
            if (r.IsTotal)
            {
                var range = ws.Range(row, 1, row, cols);
                range.Style.Font.Bold = true;
                range.Style.Fill.BackgroundColor = DenialExcelTheme.TotalRowBg;
            }
            row++;
        }
        if (report.Rows.Count > 0)
        {
            var body = ws.Range(headerRow, 1, row - 1, cols);
            body.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
            body.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            body.Style.Border.InsideBorderColor = DenialExcelTheme.BorderColor;
            body.Style.Border.OutsideBorderColor = DenialExcelTheme.BorderColor;
        }

        row++;
        if (report.Insights.Count > 0)
        {
            ws.Cell(row++, 1).SetValue("Insights").Style.Font.Bold = true;
            foreach (var insight in report.Insights) ws.Cell(row++, 1).Value = "• " + insight;
            row++;
        }
        if (!string.IsNullOrWhiteSpace(report.Note))
        {
            ws.Cell(row, 1).Value = report.Note;
            ws.Cell(row, 1).Style.Font.Italic = true;
        }

        ws.SheetView.FreezeRows(headerRow);
        ws.Columns(1, cols).AdjustToContents(headerRow, Math.Max(headerRow, row - 1), 10, 60);
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static void SetValue(IXLCell cell, object? value, string format)
    {
        switch (value)
        {
            case null:
                cell.Value = format is "money" or "count" or "pct" or "decimal" ? "—" : string.Empty;
                if (format != "text") cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
                return;
            case DateTime d:
                cell.Value = d;
                cell.Style.DateFormat.Format = "yyyy-mm-dd";
                return;
            case int or long or decimal or double:
                cell.Value = Convert.ToDecimal(value);
                cell.Style.NumberFormat.Format = format switch
                {
                    "money" => DenialExcelTheme.AccountingNumberFormat2,
                    "pct" => "0.0%",
                    "decimal" => "#,##0.0",
                    _ => "#,##0"
                };
                return;
            default:
                cell.SetValue(value.ToString());
                return;
        }
    }

    // Excel sheet names: 31 characters, none of : \ / ? * [ ].
    private static string SheetName(string title)
    {
        var clean = new string(title.Where(ch => !":\\/?*[]".Contains(ch)).ToArray()).Trim();
        return clean.Length == 0 ? "Report" : clean.Length > 31 ? clean[..31] : clean;
    }
}
