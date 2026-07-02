using ClosedXML.Excel;
using System.IO.Compression;
using System.Text;

namespace DenialDatabaseProcessorWorker.Services;

public sealed class ExcelWriter
{
    public ExportResult Write(
        string outputPath,
        List<string> insightHeaders,
        List<Dictionary<string, string>> insightRows,
        List<Dictionary<string, string>> lineRows,
        List<Dictionary<string, string>> taskRows,
        BreakdownSheetModel? weeklyBreakdown = null,
        BreakdownSheetModel? monthlyBreakdown = null)
    {
        var outputDirectory = Path.GetDirectoryName(outputPath);
        if (!string.IsNullOrWhiteSpace(outputDirectory) && !Directory.Exists(outputDirectory))
            Directory.CreateDirectory(outputDirectory);

        var baseFileName = Path.GetFileNameWithoutExtension(outputPath);

        var excelPath = Path.Combine(outputDirectory!, $"{baseFileName}_Summary.xlsx");
        var csvPath = Path.Combine(outputDirectory!, $"{baseFileName}_LineItem.csv");
        var zipPath = Path.Combine(outputDirectory!, $"{baseFileName}.zip");

        // 1. Build summary workbook only
        using (var workbook = new XLWorkbook())
        {
            BuildDenialInsightsSheet(workbook, insightHeaders, insightRows);

            if (weeklyBreakdown is not null && weeklyBreakdown.Periods.Count > 0)
                BuildBreakdownSheet(workbook, "Weekly Breakdown", weeklyBreakdown);

            if (monthlyBreakdown is not null && monthlyBreakdown.Periods.Count > 0)
                BuildBreakdownSheet(workbook, "Monthly Breakdown", monthlyBreakdown);

            BuildTaskBoardSheetLight(workbook, taskRows);

            workbook.SaveAs(excelPath);
        }

        // 2. Build line item CSV only
        WriteCsv(csvPath, lineRows);

        // 3. Create ZIP
        if (File.Exists(zipPath))
            File.Delete(zipPath);

        using (var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create))
        {
            if (File.Exists(excelPath))
                zip.CreateEntryFromFile(excelPath, Path.GetFileName(excelPath), CompressionLevel.Fastest);

            if (File.Exists(csvPath))
                zip.CreateEntryFromFile(csvPath, Path.GetFileName(csvPath), CompressionLevel.Fastest);
        }

        return new ExportResult
        {
            ExcelPath = excelPath,
            CsvPath = csvPath,
            ZipPath = zipPath
        };
    }

    private static void BuildTaskBoardSheetLight(
        XLWorkbook wb,
        List<Dictionary<string, string>> taskRows)
    {
        var ws = wb.AddWorksheet("Task Board");

        if (taskRows.Count == 0)
        {
            ws.Cell(1, 1).Value = "No data available";
            ws.Cell(1, 1).Style.Font.Bold = true;
            return;
        }

        var taskHeaders = taskRows[0].Keys.ToList();

        for (int c = 0; c < taskHeaders.Count; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = taskHeaders[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#34495E");
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            cell.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
        }

        ws.SheetView.FreezeRows(1);

        for (int r = 0; r < taskRows.Count; r++)
        {
            var row = taskRows[r];
            for (int c = 0; c < taskHeaders.Count; c++)
            {
                var key = taskHeaders[c];
                row.TryGetValue(key, out var val);
                var cell = ws.Cell(r + 2, c + 1);

                if (key is "Date Opened" or "Due Date" or "Date Completed" or "CreatedOn")
                {
                    if (DateTime.TryParse(val, out var dt))
                    {
                        cell.Value = dt;
                        cell.Style.NumberFormat.Format = "yyyy-MM-dd";
                    }
                    else
                    {
                        cell.Value = val ?? string.Empty;
                    }
                }
                else if (key == "Insurance Balance" && decimal.TryParse(val, out var amt))
                {
                    cell.Value = amt;
                    cell.Style.NumberFormat.Format = "$#,##0.00";
                }
                else
                {
                    cell.Value = val ?? string.Empty;
                }

                if (key is "Recommended Action" or "Task")
                    cell.Style.Alignment.WrapText = true;
            }
        }

        for (int i = 1; i <= taskHeaders.Count; i++)
            ws.Column(i).Width = 18;

        SetWidth(ws, taskHeaders, "Denial Description", 35);
        SetWidth(ws, taskHeaders, "Recommended Action", 40);
        SetWidth(ws, taskHeaders, "Task", 35);
        SetWidth(ws, taskHeaders, "Assigned To", 22);
        SetWidth(ws, taskHeaders, "Action Category", 24);
    }

    private static void BuildDenialInsightsSheet(
        XLWorkbook wb,
        List<string> insightHeaders,
        List<Dictionary<string, string>> insightRows)
    {
        var ws = wb.AddWorksheet("Denial Insights");

        int rowOffset = 3;
        int colOffset = 2;

        var titleCell = ws.Cell(rowOffset, colOffset);
        titleCell.Value = "Denial Insights Summary";
        ws.Range(rowOffset, colOffset, rowOffset, colOffset + insightHeaders.Count - 1).Merge();
        titleCell.Style.Font.Bold = true;
        titleCell.Style.Font.FontColor = XLColor.White;
        titleCell.Style.Font.FontSize = 18;
        titleCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        titleCell.Style.Fill.BackgroundColor = XLColor.FromHtml("#1E3D2F");
        titleCell.Style.Border.BottomBorder = XLBorderStyleValues.Thick;

        int headerRow = rowOffset + 2;

        for (int c = 0; c < insightHeaders.Count; c++)
        {
            var cell = ws.Cell(headerRow, colOffset + c);
            cell.Value = insightHeaders[c];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#6B8E23");
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        }

        for (int r = 0; r < insightRows.Count; r++)
        {
            var row = insightRows[r];
            bool isEven = (r % 2 == 0);

            for (int c = 0; c < insightHeaders.Count; c++)
            {
                var key = insightHeaders[c];
                row.TryGetValue(key, out var val);
                var cell = ws.Cell(headerRow + 1 + r, colOffset + c);

                cell.Style.Fill.BackgroundColor = isEven ? XLColor.FromHtml("#E8F5E9") : XLColor.White;

                if (key.Equals("Data", StringComparison.OrdinalIgnoreCase))
                {
                    cell.Value = "Link";
                    cell.Style.Font.FontColor = XLColor.Blue;
                    cell.Style.Font.Underline = XLFontUnderlineValues.Single;
                }
                else if ((key.Contains("Balance", StringComparison.OrdinalIgnoreCase) ||
                          key.Contains("Total Balance", StringComparison.OrdinalIgnoreCase)) &&
                         decimal.TryParse(val, out var d))
                {
                    cell.Value = d;
                    cell.Style.NumberFormat.Format = "$#,##0.00";
                }
                else
                {
                    cell.Value = val ?? string.Empty;
                }

                if (key is "Descriptions" or "Observation" or "Action" or "Task")
                    cell.Style.Alignment.WrapText = true;

                cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            }
        }

        SetInsightWidth(ws, insightHeaders, colOffset, "Descriptions", 45);
        SetInsightWidth(ws, insightHeaders, colOffset, "Observation", 35);
        SetInsightWidth(ws, insightHeaders, colOffset, "Action Code", 25);
        SetInsightWidth(ws, insightHeaders, colOffset, "Action", 40);
        SetInsightWidth(ws, insightHeaders, colOffset, "Task", 30);
        SetInsightWidth(ws, insightHeaders, colOffset, "Data", 12);
        SetInsightWidth(ws, insightHeaders, colOffset, "# of Denial", 15);
        SetInsightWidth(ws, insightHeaders, colOffset, "# of Claims", 15);
        SetInsightWidth(ws, insightHeaders, colOffset, "Total Balance ($)", 18);
        SetInsightWidth(ws, insightHeaders, colOffset, "Ins. Balance ($)", 18);
        SetInsightWidth(ws, insightHeaders, colOffset, "$ Impact (%)", 15);

        ws.SheetView.FreezeRows(headerRow);
    }

    private static void BuildBreakdownSheet(XLWorkbook wb, string sheetName, BreakdownSheetModel model)
    {
        var ws = wb.AddWorksheet(sheetName);
        var totalColumns = 2 + (model.Periods.Count * 2) + 2;

        ws.Cell(1, 1).Value = model.HeaderTitle;
        ws.Range(1, 1, 1, totalColumns).Merge();
        var titleRange = ws.Range(1, 1, 1, totalColumns);
        titleRange.Style.Font.Bold = true;
        titleRange.Style.Font.FontColor = XLColor.White;
        titleRange.Style.Font.FontSize = 14;
        titleRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        titleRange.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        titleRange.Style.Fill.BackgroundColor = XLColor.FromHtml("#1F5E16");
        titleRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

        ws.Cell(2, 1).Value = "Insurance & Top Denials";
        ws.Range(2, 1, 3, 2).Merge();
        var leftHeader = ws.Range(2, 1, 3, 2);
        leftHeader.Style.Font.Bold = true;
        leftHeader.Style.Font.FontColor = XLColor.White;
        leftHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        leftHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        leftHeader.Style.Fill.BackgroundColor = XLColor.FromHtml("#245B14");
        leftHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

        if (model.Periods.Count > 0)
        {
            ws.Cell(2, 3).Value = model.SectionTitle;
            ws.Range(2, 3, 2, 2 + (model.Periods.Count * 2)).Merge();
            var sectionHeader = ws.Range(2, 3, 2, 2 + (model.Periods.Count * 2));
            sectionHeader.Style.Font.Bold = true;
            sectionHeader.Style.Font.FontColor = XLColor.White;
            sectionHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            sectionHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            sectionHeader.Style.Fill.BackgroundColor = XLColor.FromHtml("#245B14");
            sectionHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        }

        ws.Cell(2, 3 + (model.Periods.Count * 2)).Value = "Total";
        ws.Range(2, 3 + (model.Periods.Count * 2), 3, totalColumns).Merge();
        var totalHeader = ws.Range(2, 3 + (model.Periods.Count * 2), 3, totalColumns);
        totalHeader.Style.Font.Bold = true;
        totalHeader.Style.Font.FontColor = XLColor.White;
        totalHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        totalHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        totalHeader.Style.Fill.BackgroundColor = XLColor.FromHtml("#245B14");
        totalHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

        var periodCol = 3;
        foreach (var period in model.Periods)
        {
            ws.Cell(3, periodCol).Value = period.Label;
            ws.Range(3, periodCol, 3, periodCol + 1).Merge();
            var periodHeader = ws.Range(3, periodCol, 3, periodCol + 1);
            periodHeader.Style.Font.Bold = true;
            periodHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            periodHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            periodHeader.Style.Fill.BackgroundColor = XLColor.FromHtml("#DDE8D2");
            periodHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

            ws.Cell(4, periodCol).Value = "No. of Claims";
            ws.Cell(4, periodCol + 1).Value = "Denial Bal";
            ws.Range(4, periodCol, 4, periodCol + 1).Style.Font.Bold = true;
            ws.Range(4, periodCol, 4, periodCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            ws.Range(4, periodCol, 4, periodCol + 1).Style.Fill.BackgroundColor = XLColor.FromHtml("#F3F3F3");
            ws.Range(4, periodCol, 4, periodCol + 1).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            ws.Range(4, periodCol, 4, periodCol + 1).Style.Border.InsideBorder = XLBorderStyleValues.Thin;

            periodCol += 2;
        }

        ws.Cell(4, periodCol).Value = "No. of Claims";
        ws.Cell(4, periodCol + 1).Value = "Denial Bal";
        ws.Range(4, periodCol, 4, periodCol + 1).Style.Font.Bold = true;
        ws.Range(4, periodCol, 4, periodCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Range(4, periodCol, 4, periodCol + 1).Style.Fill.BackgroundColor = XLColor.FromHtml("#F3F3F3");
        ws.Range(4, periodCol, 4, periodCol + 1).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        ws.Range(4, periodCol, 4, periodCol + 1).Style.Border.InsideBorder = XLBorderStyleValues.Thin;

        var dataRow = 5;
        foreach (var row in model.Rows)
        {
            ws.Cell(dataRow, 1).Value = row.IndexLabel;
            ws.Cell(dataRow, 2).Value = row.Label;

            var rowRange = ws.Range(dataRow, 1, dataRow, totalColumns);
            rowRange.Style.Fill.BackgroundColor = row.IsInsuranceRow ? XLColor.FromHtml("#E7ECE3") : XLColor.White;
            rowRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            rowRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;

            ws.Cell(dataRow, 1).Style.Font.Bold = true;
            ws.Cell(dataRow, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            ws.Cell(dataRow, 2).Style.Alignment.WrapText = true;
            ws.Cell(dataRow, 2).Style.Font.Bold = row.IsInsuranceRow;

            var cellCol = 3;
            for (var i = 0; i < model.Periods.Count; i++)
            {
                var cell = i < row.Cells.Count ? row.Cells[i] : new BreakdownCellModel();

                ws.Cell(dataRow, cellCol).Value = cell.ClaimCount == 0 ? "-" : cell.ClaimCount;

                if (cell.DenialBalance == 0)
                {
                    ws.Cell(dataRow, cellCol + 1).Value = "$ -";
                }
                else
                {
                    ws.Cell(dataRow, cellCol + 1).Value = cell.DenialBalance;
                    ws.Cell(dataRow, cellCol + 1).Style.NumberFormat.Format = "$#,##0.00";
                }

                ws.Cell(dataRow, cellCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
                ws.Cell(dataRow, cellCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
                cellCol += 2;
            }

            ws.Cell(dataRow, cellCol).Value = row.TotalClaimCount == 0 ? "-" : row.TotalClaimCount;
            if (row.TotalBalance == 0)
            {
                ws.Cell(dataRow, cellCol + 1).Value = "$ -";
            }
            else
            {
                ws.Cell(dataRow, cellCol + 1).Value = row.TotalBalance;
                ws.Cell(dataRow, cellCol + 1).Style.NumberFormat.Format = "$#,##0.00";
            }

            ws.Cell(dataRow, cellCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            ws.Cell(dataRow, cellCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;

            dataRow++;
        }

        ws.Cell(dataRow, 1).Value = "";
        ws.Cell(dataRow, 2).Value = "Total";
        ws.Range(dataRow, 1, dataRow, totalColumns).Style.Font.Bold = true;
        ws.Range(dataRow, 1, dataRow, totalColumns).Style.Fill.BackgroundColor = XLColor.FromHtml("#E1E9D9");
        ws.Range(dataRow, 1, dataRow, totalColumns).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        ws.Range(dataRow, 1, dataRow, totalColumns).Style.Border.InsideBorder = XLBorderStyleValues.Thin;

        var totalCol = 3;
        for (var i = 0; i < model.TotalsByPeriod.Count; i++)
        {
            var total = model.TotalsByPeriod[i];
            ws.Cell(dataRow, totalCol).Value = total.ClaimCount == 0 ? "-" : total.ClaimCount;
            if (total.DenialBalance == 0)
            {
                ws.Cell(dataRow, totalCol + 1).Value = "$ -";
            }
            else
            {
                ws.Cell(dataRow, totalCol + 1).Value = total.DenialBalance;
                ws.Cell(dataRow, totalCol + 1).Style.NumberFormat.Format = "$#,##0.00";
            }
            totalCol += 2;
        }

        ws.Cell(dataRow, totalCol).Value = model.GrandTotalClaimCount == 0 ? "-" : model.GrandTotalClaimCount;
        if (model.GrandTotalBalance == 0)
        {
            ws.Cell(dataRow, totalCol + 1).Value = "$ -";
        }
        else
        {
            ws.Cell(dataRow, totalCol + 1).Value = model.GrandTotalBalance;
            ws.Cell(dataRow, totalCol + 1).Style.NumberFormat.Format = "$#,##0.00";
        }

        ws.SheetView.FreezeRows(4);
        ws.SheetView.FreezeColumns(2);
        ws.Column(1).Width = 6;
        ws.Column(2).Width = 56;
        for (var c = 3; c <= totalColumns; c++)
            ws.Column(c).Width = 14;

        ws.Rows(1, 4).AdjustToContents();
        ws.Columns().Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
    }

    private static void WriteCsv(string filePath, List<Dictionary<string, string>> rows)
    {
        if (rows == null || rows.Count == 0)
        {
            File.WriteAllText(filePath, string.Empty, new UTF8Encoding(true));
            return;
        }

        var headers = rows[0].Keys.ToList();

        using var writer = new StreamWriter(filePath, false, new UTF8Encoding(true));
        writer.WriteLine(string.Join(",", headers.Select(EscapeCsv)));

        foreach (var row in rows)
        {
            var values = headers.Select(h =>
            {
                row.TryGetValue(h, out var v);
                return EscapeCsv(v ?? string.Empty);
            });

            writer.WriteLine(string.Join(",", values));
        }
    }

    private static string EscapeCsv(string value)
    {
        if (value.Contains('"'))
            value = value.Replace("\"", "\"\"");

        if (value.Contains(',') || value.Contains('"') || value.Contains('\r') || value.Contains('\n'))
            return $"\"{value}\"";

        return value;
    }

    private static void SetWidth(IXLWorksheet ws, List<string> headers, string header, double width)
    {
        int index = headers.IndexOf(header);
        if (index >= 0)
            ws.Column(index + 1).Width = width;
    }

    private static void SetInsightWidth(IXLWorksheet ws, List<string> headers, int colOffset, string header, double width)
    {
        int index = headers.IndexOf(header);
        if (index >= 0)
            ws.Column(colOffset + index).Width = width;
    }
}

public sealed class ExportResult
{
    public string ExcelPath { get; set; } = string.Empty;
    public string CsvPath { get; set; } = string.Empty;
    public string ZipPath { get; set; } = string.Empty;
}

public sealed class BreakdownSheetModel
{
    public string HeaderTitle { get; set; } = string.Empty;
    public string SectionTitle { get; set; } = string.Empty;
    public List<BreakdownPeriodModel> Periods { get; set; } = new();
    public List<BreakdownRowModel> Rows { get; set; } = new();
    public List<BreakdownCellModel> TotalsByPeriod { get; set; } = new();
    public int GrandTotalClaimCount { get; set; }
    public decimal GrandTotalBalance { get; set; }
}

public sealed class BreakdownPeriodModel
{
    public string Label { get; set; } = string.Empty;
}

public sealed class BreakdownRowModel
{
    public string IndexLabel { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public bool IsInsuranceRow { get; set; }
    public List<BreakdownCellModel> Cells { get; set; } = new();
    public int TotalClaimCount { get; set; }
    public decimal TotalBalance { get; set; }
}

public sealed class BreakdownCellModel
{
    public int ClaimCount { get; set; }
    public decimal DenialBalance { get; set; }
}