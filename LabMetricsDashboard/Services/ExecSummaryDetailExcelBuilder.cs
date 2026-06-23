using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Creates an Excel workbook from an <see cref="ExecSummaryDetailRowsViewModel"/> —
/// the row-level drill-down shown on the Executive Summary Detail page.
/// Column-agnostic: writes whatever columns/rows the detail SP returned,
/// formatting numeric and date values appropriately.
/// </summary>
public sealed class ExecSummaryDetailExcelBuilder
{
    public byte[] Build(ExecSummaryDetailRowsViewModel vm)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add(SheetName(vm));

        var darkBlue = XLColor.FromHtml("#0e3460");

        // ── Title / meta rows ───────────────────────────────────────
        sheet.Cell(1, 1).Value = vm.Description.Trim();
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 13;

        sheet.Cell(2, 1).Value = $"Category: {vm.Category}    Period: {vm.MonthLabel}" +
            (vm.SelectedValue.HasValue ? $"    Value: {vm.SelectedValueFormatted}" : "") +
            $"    Records: {vm.Rows.Count}    Source: {vm.SourceLabel}";
        sheet.Cell(2, 1).Style.Font.FontColor = XLColor.FromHtml("#555555");
        sheet.Cell(2, 1).Style.Font.Italic = true;

        const int headerRow = 4;

        // ── Header row ──────────────────────────────────────────────
        for (int c = 0; c < vm.Columns.Count; c++)
        {
            var cell = sheet.Cell(headerRow, c + 1);
            cell.Value = vm.Columns[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = darkBlue;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // ── Data rows ───────────────────────────────────────────────
        var r = headerRow + 1;
        foreach (var row in vm.Rows)
        {
            for (int c = 0; c < row.Length; c++)
            {
                var cell = sheet.Cell(r, c + 1);
                WriteCellValue(cell, row[c]);
            }
            r++;
        }

        if (vm.Columns.Count > 0 && vm.Rows.Count > 0)
        {
            sheet.SheetView.FreezeRows(headerRow);
            sheet.Range(headerRow, 1, r - 1, vm.Columns.Count).SetAutoFilter();
            sheet.Columns().AdjustToContents();
        }

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static void WriteCellValue(IXLCell cell, object? value)
    {
        switch (value)
        {
            case null:
                break;
            case DateTime dt:
                cell.Value = dt;
                cell.Style.DateFormat.Format = dt.TimeOfDay == TimeSpan.Zero ? "MM/dd/yyyy" : "MM/dd/yyyy HH:mm";
                break;
            case decimal dec:
                cell.Value = (double)dec;
                cell.Style.NumberFormat.Format = "#,##0.00";
                break;
            case double dbl:
                cell.Value = dbl;
                cell.Style.NumberFormat.Format = "#,##0.00";
                break;
            case float flt:
                cell.Value = (double)flt;
                cell.Style.NumberFormat.Format = "#,##0.00";
                break;
            case int or long or short:
                cell.Value = Convert.ToDouble(value);
                cell.Style.NumberFormat.Format = "#,##0";
                break;
            case bool b:
                cell.Value = b ? "Yes" : "No";
                break;
            default:
                cell.Value = value.ToString();
                break;
        }
    }

    private static string SheetName(ExecSummaryDetailRowsViewModel vm)
    {
        var raw = $"{vm.Category} {vm.RowCode}".Trim();
        if (string.IsNullOrWhiteSpace(raw)) raw = "Detail";

        // Excel sheet names: max 31 chars, no \ / ? * [ ]
        foreach (var ch in "\\/?*[]")
            raw = raw.Replace(ch, '-');

        return raw.Length > 31 ? raw[..31] : raw;
    }
}
