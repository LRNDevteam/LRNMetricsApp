using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Excel download of the Executive Summary value popup: the calculation rules on top,
/// then every source row behind the clicked value.
/// </summary>
public static class ExecSummaryCellRowsExcelBuilder
{
    private static readonly HashSet<string> AmountColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "Amount", "ChargeAmount", "InsurancePayment", "PatientPayment", "PatientBalance",
        "TotalAdjustments", "TotalInsuranceBalance",
    };

    public static byte[] Build(ExecSummaryCellRowsResult result, string labName, string title, string periodLabel, string valueText)
    {
        using var workbook = new XLWorkbook();
        var ws = workbook.AddWorksheet("Rows");
        ExcelTheme.ApplyDefaults(ws);
        ws.TabColor = ExcelTheme.Collection.TabYellow;

        var lastCol = Math.Max(result.Columns.Count, 4);
        var row = 1;
        ws.Cell(row, 1).Value = $"{labName} - Executive Summary - {title} - {periodLabel}";
        ws.Range(row, 1, row, lastCol).Merge();
        ws.Cell(row, 1).Style.Font.Bold = true;
        ws.Cell(row, 1).Style.Font.FontColor = XLColor.White;
        ws.Cell(row, 1).Style.Fill.BackgroundColor = ExcelTheme.Collection.HeaderBg;
        row++;
        ws.Cell(row, 1).Value = result.IsFormula
            ? $"Grid value: {valueText}    Result: {result.TotalAmount:N2}"
            : $"Grid value: {valueText}    Rows found: {result.TotalRows:N0}"
              + (result.AmountColumn is null ? string.Empty : $"    {result.Measure}: {result.TotalAmount:N2}");
        ws.Range(row, 1, row, lastCol).Merge();
        row += 2;

        ws.Cell(row, 1).Value = "How this value is calculated";
        ws.Cell(row, 1).Style.Font.Bold = true;
        row++;
        foreach (var rule in result.Rules)
        {
            ws.Cell(row, 1).Value = rule.Group;
            ws.Cell(row, 1).Style.Font.Bold = true;
            ws.Cell(row, 2).Value = rule.Text;
            ws.Range(row, 2, row, lastCol).Merge();
            row++;
        }
        row++;

        if (result.Columns.Count > 0)
        {
            // Formula breakdown: IsMoney / IsTotal steer formatting and are not written.
            var moneyIdx = result.Columns.IndexOf("IsMoney");
            var totalIdx = result.Columns.IndexOf("IsTotal");
            var cols = Enumerable.Range(0, result.Columns.Count).Where(c => c != moneyIdx && c != totalIdx).ToList();

            var headerRow = row;
            for (var k = 0; k < cols.Count; k++)
            {
                var cell = ws.Cell(row, k + 1);
                cell.Value = result.Columns[cols[k]];
                cell.Style.Font.Bold = true;
                cell.Style.Font.FontColor = XLColor.White;
                cell.Style.Fill.BackgroundColor = ExcelTheme.Collection.HeaderBg;
            }
            row++;
            foreach (var r in result.Rows)
            {
                var rowIsMoney = moneyIdx >= 0 && r[moneyIdx] is true;
                var rowIsTotal = totalIdx >= 0 && r[totalIdx] is true;
                for (var k = 0; k < cols.Count; k++)
                {
                    var c = cols[k];
                    var cell = ws.Cell(row, k + 1);
                    switch (r[c])
                    {
                        case null: break;
                        case decimal d:
                            cell.Value = d;
                            if (AmountColumns.Contains(result.Columns[c]) || rowIsMoney)
                                cell.Style.NumberFormat.Format = ExcelTheme.Collection.AccountingNumberFormat;
                            else if (result.IsFormula)
                                cell.Style.NumberFormat.Format = ExcelTheme.Collection.CountNumberFormat;
                            break;
                        case int i: cell.Value = i; break;
                        case long l: cell.Value = l; break;
                        default: cell.Value = r[c]!.ToString(); break;
                    }
                    if (rowIsTotal) cell.Style.Font.Bold = true;
                }
                row++;
            }
            if (!result.IsFormula)
            {
                ws.Range(headerRow, 1, Math.Max(headerRow, row - 1), cols.Count).SetAutoFilter();
                ws.SheetView.FreezeRows(headerRow);
            }
            ws.Columns(1, cols.Count).AdjustToContents(headerRow, Math.Min(row, headerRow + 500), 10, 60);
        }

        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }
}
