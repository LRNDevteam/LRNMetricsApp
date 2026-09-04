using ClosedXML.Excel;
using LabMetricsDashboard.Models.Notes;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds the Key Insights &amp; Highlights worksheet (mockup layout) and
/// inserts it as sheet 1 of a Production / LIS / Collection workbook.
/// </summary>
public static class InsightsExcelBuilder
{
    private static readonly XLColor HeaderGreen = XLColor.FromHtml("#1F5C3A");
    private static readonly XLColor ActionRed = XLColor.FromHtml("#C00000");
    private static readonly XLColor RiskRed = XLColor.FromHtml("#C00000");
    private static readonly XLColor StatusPeach = XLColor.FromHtml("#FCE4D6");
    private static readonly XLColor FooterGray = XLColor.FromHtml("#D9D9D9");
    private static readonly XLColor LinkBlue = XLColor.FromHtml("#0563C1");

    public const string SheetName = "Key Insights & Highlights";

    public static void InsertAsFirstSheet(
        XLWorkbook workbook,
        IReadOnlyList<NoteInsight> insights,
        string? labName = null,
        string? reportName = null)
    {
        ArgumentNullException.ThrowIfNull(workbook);
        insights ??= [];

        if (workbook.Worksheets.TryGetWorksheet(SheetName, out var existing))
            existing.Delete();

        var ws = workbook.Worksheets.Add(SheetName);
        ws.Position = 1;
        WriteSheet(ws, insights, labName, reportName);
        ExcelTheme.GroupIndentedChildRows(workbook, skipSheetName: SheetName);
    }

    public static byte[] InjectIntoExistingWorkbook(
        string workbookPath,
        IReadOnlyList<NoteInsight> insights,
        string? labName = null,
        string? reportName = null)
    {
        using var wb = new XLWorkbook(workbookPath);
        InsertAsFirstSheet(wb, insights, labName, reportName);
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    public static async Task<IReadOnlyList<NoteInsight>> LoadAsync(
        INotesRepository notes, string connectionString, string reportName, CancellationToken ct = default)
    {
        try
        {
            if (!await notes.IsFeatureAvailableAsync(connectionString, ct))
                return [];
            var reportKeyId = await notes.EnsureReportAsync(connectionString, reportName, ct);
            return await notes.GetActiveAsync(connectionString, reportKeyId, ct: ct);
        }
        catch
        {
            return [];
        }
    }

    public static InsightsSheetLayout LayoutFor(string? reportName)
    {
        var name = reportName ?? "";
        if (name.Contains("Collection", StringComparison.OrdinalIgnoreCase))
        {
            return new InsightsSheetLayout(
                ["#", "Risk", "Responsible Party", "Insights", "# of Cases", "Total Bill", "Case Link",
                 "Action / Solution / Suggestion", "Feedback / Response", "Response By",
                 "Discussion Date", "ETA", "Closed Date", "Status"],
                "Previously Analysed Data - Pending Items",
                "(Refer Old Reports for Data Links)");
        }
        if (name.Contains("LIS", StringComparison.OrdinalIgnoreCase))
        {
            return new InsightsSheetLayout(
                ["#", "Risk", "Responsible Party", "Insights", "# of Claims", "Expected Reimbursement ($)", "Data Link",
                 "Action / Solution / Suggestions", "Feedback / Response", "Responsibility",
                 "Discussion Date", "ETA", "Closed Date", "Status"],
                "Previously Analyzed Data - All Data",
                "(Refer Old Reports for Data Links)");
        }
        return new InsightsSheetLayout(
            ["#", "Risk", "Responsible Party", "Insights", "# of Claims", "Total Charge", "Data",
             "Action / Solution / Suggestions", "Feedback / Response", "Responsibility",
             "Discussion Date", "ETA", "Closed Date", "Status"],
            "Previously Analysed Data - Pending Items",
            "(Refer Old Reports for Data Links)");
    }

    public sealed record InsightsSheetLayout(string[] Headers, string FooterTitle, string FooterSub);

    private static void WriteSheet(IXLWorksheet ws, IReadOnlyList<NoteInsight> insights, string? labName, string? reportName)
    {
        var layout = LayoutFor(reportName);
        const int colCount = 14;
        ws.SheetView.FreezeRows(2);

        ws.Range(1, 1, 1, colCount).Merge();
        var title = ws.Cell(1, 1);
        title.Value = "Key Insights & Highlights";
        title.Style.Font.Bold = true;
        title.Style.Font.FontSize = 14;
        title.Style.Font.FontColor = XLColor.White;
        title.Style.Fill.BackgroundColor = HeaderGreen;
        title.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
        title.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(1).Height = 22;

        for (var c = 1; c <= colCount; c++)
        {
            var cell = ws.Cell(2, c);
            cell.Value = layout.Headers[c - 1];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = c == 8 ? ActionRed : HeaderGreen;
            cell.Style.Alignment.WrapText = true;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        }
        ws.Row(2).Height = 32;

        var row = 3;
        var displayNo = 1;
        foreach (var n in insights.OrderBy(x => x.EntryNo ?? int.MaxValue).ThenBy(x => x.NoteId))
        {
            ws.Cell(row, 1).Value = n.EntryNo ?? displayNo;
            ws.Cell(row, 2).Value = DisplayRisk(n);
            ws.Cell(row, 3).Value = n.ResponsibleParty ?? "";
            ws.Cell(row, 4).Value = StripHtml(n.Insights);
            if (n.NoOfSamples.HasValue) ws.Cell(row, 5).Value = n.NoOfSamples.Value;
            if (n.TotalCharge.HasValue)
            {
                ws.Cell(row, 6).Value = n.TotalCharge.Value;
                ws.Cell(row, 6).Style.NumberFormat.Format = "\"$\" #,##0";
                ws.Cell(row, 6).Style.Font.Bold = true;
            }

            if (!string.IsNullOrWhiteSpace(n.DataLink))
            {
                var dataCell = ws.Cell(row, 7);
                dataCell.Value = "Link";
                try { dataCell.SetHyperlink(new XLHyperlink(n.DataLink)); }
                catch { dataCell.Value = n.DataLink; }
                dataCell.Style.Font.FontColor = LinkBlue;
                dataCell.Style.Font.Underline = XLFontUnderlineValues.Single;
            }

            ws.Cell(row, 8).Value = StripHtml(n.ActionSolution);
            ws.Cell(row, 9).Value = StripHtml(n.FeedbackResponse);
            ws.Cell(row, 10).Value = n.Responsibility ?? "";
            WriteDate(ws.Cell(row, 11), n.DiscussionDate);
            WriteDate(ws.Cell(row, 12), n.ETA);
            WriteDate(ws.Cell(row, 13), n.ClosedDate);
            ws.Cell(row, 14).Value = n.StatusLabel ?? n.StatusCode;

            ApplyRiskStyle(ws.Cell(row, 2), n);
            ApplyStatusStyle(ws.Cell(row, 14), n);

            for (var c = 1; c <= colCount; c++)
            {
                ws.Cell(row, c).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
                ws.Cell(row, c).Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
                ws.Cell(row, c).Style.Alignment.WrapText = c is 4 or 8 or 9;
            }

            row++;
            displayNo++;
        }

        if (insights.Count == 0)
        {
            ws.Range(row, 1, row, colCount).Merge();
            ws.Cell(row, 1).Value = "No insights saved for this report yet.";
            ws.Cell(row, 1).Style.Font.Italic = true;
            ws.Cell(row, 1).Style.Font.FontColor = XLColor.FromHtml("#64748B");
            row++;
        }

        var footerRow = row + 1;
        ws.Range(footerRow, 1, footerRow + 1, colCount).Merge();
        var footer = ws.Cell(footerRow, 1);
        footer.Value = layout.FooterTitle + Environment.NewLine + layout.FooterSub;
        footer.Style.Fill.BackgroundColor = FooterGray;
        footer.Style.Font.FontColor = XLColor.FromHtml("#C00000");
        footer.Style.Font.Bold = true;
        footer.Style.Alignment.WrapText = true;
        footer.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(footerRow).Height = 36;
        ws.Row(footerRow + 1).Height = 8;

        ws.Column(1).Width = 6;
        ws.Column(2).Width = 12;
        ws.Column(3).Width = 22;
        ws.Column(4).Width = 48;
        ws.Column(5).Width = 14;
        ws.Column(6).Width = 16;
        ws.Column(7).Width = 12;
        ws.Column(8).Width = 42;
        ws.Column(9).Width = 28;
        ws.Column(10).Width = 16;
        ws.Column(11).Width = 16;
        ws.Column(12).Width = 12;
        ws.Column(13).Width = 14;
        ws.Column(14).Width = 16;

        if (!string.IsNullOrWhiteSpace(labName))
            ws.TabColor = HeaderGreen;
    }

    private static void WriteDate(IXLCell cell, DateTime? value)
    {
        if (!value.HasValue) return;
        cell.Value = value.Value;
        cell.Style.DateFormat.Format = "d-MMM";
    }

    private static string DisplayRisk(NoteInsight n)
    {
        var label = (n.RiskLabel ?? "").Trim();
        if (label.StartsWith("High", StringComparison.OrdinalIgnoreCase)) return "High";
        if (label.StartsWith("Low", StringComparison.OrdinalIgnoreCase)) return "Low";
        if (label.StartsWith("Medium", StringComparison.OrdinalIgnoreCase)) return "Medium";
        return n.RiskCode switch
        {
            "Red" => "High",
            "Green" => "Low",
            _ => "Medium"
        };
    }

    private static void ApplyRiskStyle(IXLCell cell, NoteInsight n)
    {
        var display = DisplayRisk(n);
        if (display.Equals("High", StringComparison.OrdinalIgnoreCase))
        {
            cell.Style.Font.FontColor = RiskRed;
            cell.Style.Font.Bold = true;
        }
        else if (display.Equals("Low", StringComparison.OrdinalIgnoreCase))
        {
            cell.Style.Font.FontColor = XLColor.FromHtml("#548235");
            cell.Style.Font.Bold = true;
        }
        else
        {
            cell.Style.Font.FontColor = XLColor.FromHtml("#BF8F00");
            cell.Style.Font.Bold = true;
        }
    }

    private static void ApplyStatusStyle(IXLCell cell, NoteInsight n)
    {
        var label = (n.StatusLabel ?? n.StatusCode ?? "").Trim();
        if (label.Contains("Yet to Discuss", StringComparison.OrdinalIgnoreCase)
            || label.Equals("Discuss", StringComparison.OrdinalIgnoreCase))
        {
            cell.Style.Fill.BackgroundColor = StatusPeach;
            cell.Style.Font.FontColor = XLColor.FromHtml("#C45911");
            cell.Style.Font.Bold = true;
        }
    }

    private static string StripHtml(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return "";
        var s = html.Replace("<br>", "\n", StringComparison.OrdinalIgnoreCase)
                    .Replace("<br/>", "\n", StringComparison.OrdinalIgnoreCase)
                    .Replace("<br />", "\n", StringComparison.OrdinalIgnoreCase)
                    .Replace("</p>", "\n", StringComparison.OrdinalIgnoreCase)
                    .Replace("</li>", "\n", StringComparison.OrdinalIgnoreCase)
                    .Replace("<li>", "• ", StringComparison.OrdinalIgnoreCase);
        return System.Text.RegularExpressions.Regex.Replace(s, "<[^>]+>", "").Trim();
    }
}
