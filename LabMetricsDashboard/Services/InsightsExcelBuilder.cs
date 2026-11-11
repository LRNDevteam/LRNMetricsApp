using ClosedXML.Excel;
using LabMetricsDashboard.Models.Notes;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds the Key Insights &amp; Highlights block on the Cove-style Insights sheet.
/// Production / Collection already write Monthly + Weekly onto Insights; this
/// appends the notes table below that content. LIS still gets Insights as sheet 1.
/// </summary>
public static class InsightsExcelBuilder
{
    private static readonly XLColor HeaderGreen = XLColor.FromHtml("#385624");
    private static readonly XLColor ActionRed = XLColor.FromHtml("#C00000");
    private static readonly XLColor RiskRed = XLColor.FromHtml("#C00000");
    private static readonly XLColor StatusPeach = XLColor.FromHtml("#FCE4D6");
    private static readonly XLColor FooterGray = XLColor.FromHtml("#D9D9D9");

    public const string SheetName = "Insights";
    public const string LegacyNotesSheetName = "Key Insights & Highlights";
    public const string LegacyVolumeSheetName = "MonthlyAndWeeklyVolume";

    public static void InsertAsFirstSheet(
        XLWorkbook workbook,
        IReadOnlyList<NoteInsight> insights,
        string? labName = null,
        string? reportName = null,
        IReadOnlyList<NotesTemplateColumnDef>? templateColumns = null)
    {
        ArgumentNullException.ThrowIfNull(workbook);
        insights ??= [];

        if (workbook.Worksheets.TryGetWorksheet(LegacyNotesSheetName, out var legacyNotes))
            legacyNotes.Delete();

        IXLWorksheet ws;
        if (workbook.Worksheets.TryGetWorksheet(SheetName, out var existing))
        {
            ws = existing;
        }
        else if (workbook.Worksheets.TryGetWorksheet(LegacyVolumeSheetName, out var volume))
        {
            volume.Name = SheetName;
            ws = volume;
        }
        else
        {
            ws = workbook.Worksheets.Add(SheetName);
        }

        var lastRow = ws.LastRowUsed()?.RowNumber() ?? 0;
        var startRow = lastRow <= 1 ? 1 : lastRow + 3;
        WriteSheet(ws, insights, labName, reportName, startRow, templateColumns);
        ws.Position = 1;
        if ((reportName ?? "").Contains("Collection", StringComparison.OrdinalIgnoreCase))
            CollectionSummaryExcelExportBuilder.ApplySheetOrder(workbook);
        ExcelTheme.GroupIndentedChildRows(workbook, skipSheetName: SheetName);
    }

    public static byte[] InjectIntoExistingWorkbook(
        string workbookPath,
        IReadOnlyList<NoteInsight> insights,
        string? labName = null,
        string? reportName = null,
        IReadOnlyList<NotesTemplateColumnDef>? templateColumns = null)
    {
        using var wb = new XLWorkbook(workbookPath);
        InsertAsFirstSheet(wb, insights, labName, reportName, templateColumns);
        ExcelTheme.ConvertCurrencyFormatsToAccounting(wb);
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

    public static async Task<IReadOnlyList<NotesTemplateColumnDef>> LoadTemplateColumnsAsync(
        INotesRepository notes, string connectionString, string reportName, CancellationToken ct = default)
    {
        try
        {
            if (!await notes.IsFeatureAvailableAsync(connectionString, ct))
                return [];
            var reportKeyId = await notes.EnsureReportAsync(connectionString, reportName, ct);
            var templates = await notes.GetTemplatesByReportAsync(connectionString, reportKeyId, ct);
            var tpl = templates.FirstOrDefault(t =>
                    string.Equals(t.TemplateName, "Key Insights & Highlights", StringComparison.OrdinalIgnoreCase))
                ?? templates.FirstOrDefault(t => t.IsActive)
                ?? templates.FirstOrDefault();
            return tpl?.Columns ?? [];
        }
        catch
        {
            return [];
        }
    }

    public static InsightsSheetLayout LayoutFor(
        string? reportName, IReadOnlyList<NotesTemplateColumnDef>? columns = null)
    {
        var name = reportName ?? "";
        InsightsSheetLayout layout;
        if (name.Contains("Collection", StringComparison.OrdinalIgnoreCase))
        {
            layout = new InsightsSheetLayout(
                ["#", "Risk", "Responsible Party", "Insights", "# of Cases", "Total Billed",
                 "Action / Solution / Suggestion", "Feedback / Response", "Response By",
                 "Discussion Date", "ETA", "Closed Date", "Status"],
                "Previously Analysed Data - Pending Items",
                "(Refer Old Reports for Data Links)");
        }
        else if (name.Contains("LIS", StringComparison.OrdinalIgnoreCase))
        {
            layout = new InsightsSheetLayout(
                ["#", "Risk", "Responsible Party", "Insights", "# of Claims", "Expected Reimbursement ($)",
                 "Action / Solution / Suggestions", "Feedback / Response", "Responsibility",
                 "Discussion Date", "ETA", "Closed Date", "Status"],
                "Previously Analyzed Data - All Data",
                "(Refer Old Reports for Data Links)");
        }
        else
        {
            layout = new InsightsSheetLayout(
                ["#", "Risk", "Responsible Party", "Insights", "# of Claims", "Total Charge",
                 "Action / Solution / Suggestions", "Feedback / Response", "Responsibility",
                 "Discussion Date", "ETA", "Closed Date", "Status"],
                "Previously Analysed Data - Pending Items",
                "(Refer Old Reports for Data Links)");
        }

        if (columns is not { Count: > 0 })
            return layout;

        var headers = (string[])layout.Headers.Clone();
        OverlayHeader(headers, 1, "Risk", columns);
        OverlayHeader(headers, 2, "ResponsibleParty", columns);
        OverlayHeader(headers, 3, "Insights", columns);
        OverlayHeader(headers, 4, "NoOfClaims", columns);
        OverlayHeader(headers, 5, "TotalCharge", columns);
        OverlayHeader(headers, 6, "ActionSolution", columns);
        OverlayHeader(headers, 7, "FeedbackResponse", columns);
        OverlayHeader(headers, 8, "Responsibility", columns);
        OverlayHeader(headers, 9, "DiscussionDate", columns);
        OverlayHeader(headers, 10, "ETA", columns);
        OverlayHeader(headers, 11, "ClosedDate", columns);
        OverlayHeader(headers, 12, "Status", columns);
        return layout with { Headers = headers };
    }

    private static void OverlayHeader(
        string[] headers, int index, string fieldKey, IReadOnlyList<NotesTemplateColumnDef> columns)
    {
        var hit = columns.FirstOrDefault(c => MatchesField(c, fieldKey));
        var name = hit?.ColumnName?.Trim();
        if (!string.IsNullOrEmpty(name))
            headers[index] = name;
    }

    private static bool MatchesField(NotesTemplateColumnDef col, string fieldKey) =>
        string.Equals((col.FieldKey ?? "").Trim(), fieldKey, StringComparison.OrdinalIgnoreCase)
        || string.Equals(GuessFieldKey(col), fieldKey, StringComparison.OrdinalIgnoreCase);

    /// <summary>Field key per layout header index (0 = row number).</summary>
    private static readonly string[] FieldKeys =
    [
        "#", "Risk", "ResponsibleParty", "Insights", "NoOfClaims", "TotalCharge", "ActionSolution",
        "FeedbackResponse", "Responsibility", "DiscussionDate", "ETA", "ClosedDate", "Status"
    ];

    private static readonly double[] FieldWidths = [6, 12, 22, 48, 14, 16, 42, 28, 16, 16, 12, 14, 16];

    private const int ActionField = 6;
    private const int StatusField = 12;

    /// <summary>Layout header indexes to write: every field when there is no template, otherwise
    /// the row number, Risk, Insights and Status plus the fields on the template.</summary>
    private static int[] VisibleFields(IReadOnlyList<NotesTemplateColumnDef>? columns) =>
        Enumerable.Range(0, FieldKeys.Length)
            .Where(i => columns is not { Count: > 0 }
                || i is 0 or 1 or 3 or StatusField
                || columns.Any(c => MatchesField(c, FieldKeys[i])))
            .ToArray();

    private static string GuessFieldKey(NotesTemplateColumnDef col)
    {
        var n = (col.ColumnName ?? "").Trim().ToLowerInvariant();
        if (n == "risk") return "Risk";
        if (n.Contains("responsible party")) return "ResponsibleParty";
        if (n == "insights") return "Insights";
        if (n.Contains("link") || n == "data") return "DataLink";
        if (n.Contains("claim") || n.Contains("sample") || n.Contains("case")) return "NoOfClaims";
        if (n.Contains("charge") || n.Contains("bill") || n.Contains("reimbursement") || n.Contains("balance"))
            return "TotalCharge";
        if (n.Contains("action")) return "ActionSolution";
        if (n.Contains("feedback")) return "FeedbackResponse";
        if (n.Contains("response by") || n == "responsibility") return "Responsibility";
        if (n.Contains("discussion")) return "DiscussionDate";
        if (n == "eta") return "ETA";
        if (n.Contains("closed")) return "ClosedDate";
        if (n == "status") return "Status";
        return col.ColumnName ?? "";
    }

    public sealed record InsightsSheetLayout(string[] Headers, string FooterTitle, string FooterSub);

    private static void WriteSheet(
        IXLWorksheet ws,
        IReadOnlyList<NoteInsight> insights,
        string? labName,
        string? reportName,
        int startRow = 1,
        IReadOnlyList<NotesTemplateColumnDef>? templateColumns = null)
    {
        var layout = LayoutFor(reportName, templateColumns);
        var fields = VisibleFields(templateColumns);
        var colCount = fields.Length;
        int ColOf(int field) => Array.IndexOf(fields, field) + 1;
        var splitCol = Array.FindIndex(fields, f => f >= ActionField) + 1;
        var isProduction = (reportName ?? "").Contains("Production", StringComparison.OrdinalIgnoreCase);
        var isCollection = (reportName ?? "").Contains("Collection", StringComparison.OrdinalIgnoreCase);
        var splitTitle = isProduction || isCollection;
        var append = startRow > 1;
        ws.Style.Font.FontName = "Calibri";
        ws.Style.Font.FontSize = 10;

        var titleRow = startRow;
        if (splitTitle)
        {
            var leftTitle = ws.Range(titleRow, 1, titleRow, splitCol - 1);
            leftTitle.Merge();
            ws.Cell(titleRow, 1).Value = "Key Insights & Highlights";
            ws.Cell(titleRow, 1).Style.Font.Bold = true;
            ws.Cell(titleRow, 1).Style.Font.FontSize = 12;
            ws.Cell(titleRow, 1).Style.Font.FontColor = XLColor.White;
            leftTitle.Style.Fill.BackgroundColor = HeaderGreen;
            leftTitle.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            leftTitle.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

            var rightTitle = ws.Range(titleRow, splitCol, titleRow, colCount);
            rightTitle.Merge();
            ws.Cell(titleRow, splitCol).Value = "Active Priorities / Suggestions";
            ws.Cell(titleRow, splitCol).Style.Font.Bold = true;
            ws.Cell(titleRow, splitCol).Style.Font.FontSize = 12;
            ws.Cell(titleRow, splitCol).Style.Font.FontColor = XLColor.White;
            rightTitle.Style.Fill.BackgroundColor = ActionRed;
            rightTitle.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            rightTitle.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        }
        else
        {
            ws.Range(titleRow, 1, titleRow, colCount).Merge();
            var title = ws.Cell(titleRow, 1);
            title.Value = "Key Insights & Highlights";
            title.Style.Font.Bold = true;
            title.Style.Font.FontSize =
                (reportName ?? "").Contains("Collection", StringComparison.OrdinalIgnoreCase)
                || (reportName ?? "").Contains("LIS", StringComparison.OrdinalIgnoreCase)
                    ? 10 : 14;
            title.Style.Font.FontColor = XLColor.White;
            title.Style.Fill.BackgroundColor = HeaderGreen;
            title.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
            title.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        }
        ws.Row(titleRow).Height = 22;

        var headerRow = titleRow + 1;
        for (var c = 1; c <= colCount; c++)
        {
            var field = fields[c - 1];
            var cell = ws.Cell(headerRow, c);
            cell.Value = layout.Headers[field];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = splitTitle
                ? (field >= ActionField ? ActionRed : HeaderGreen)
                : (field == ActionField ? ActionRed : HeaderGreen);
            cell.Style.Alignment.WrapText = true;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.OutsideBorderColor = XLColor.FromHtml("#CCCCCC");
        }
        ws.Row(headerRow).Height = 32;

        var row = headerRow + 1;
        var displayNo = 1;
        foreach (var n in insights.OrderBy(x => x.EntryNo ?? int.MaxValue).ThenBy(x => x.NoteId))
        {
            for (var c = 1; c <= colCount; c++)
                WriteField(ws.Cell(row, c), fields[c - 1], n, displayNo);

            var rowBg = splitTitle && row % 2 == 0
                ? XLColor.FromHtml("#F2F2F2")
                : XLColor.White;
            for (var c = 1; c <= colCount; c++)
            {
                var cell = ws.Cell(row, c);
                if (splitTitle)
                    cell.Style.Fill.BackgroundColor = rowBg;
                cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
                cell.Style.Border.OutsideBorderColor = XLColor.FromHtml("#CCCCCC");
                cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
                cell.Style.Alignment.WrapText = fields[c - 1] is 3 or ActionField or 7;
            }

            ApplyRiskStyle(ws.Cell(row, ColOf(1)), n);
            ApplyStatusStyle(ws.Cell(row, ColOf(StatusField)), n);

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

        if (!append)
        {
            for (var c = 1; c <= colCount; c++)
                ws.Column(c).Width = FieldWidths[fields[c - 1]];
            ws.TabColor = ActionRed;
        }
    }

    private static void WriteField(IXLCell cell, int field, NoteInsight n, int displayNo)
    {
        switch (field)
        {
            case 0: cell.Value = displayNo; break;
            case 1: cell.Value = ExcelTheme.SanitizeText(DisplayRisk(n)); break;
            case 2: cell.Value = ExcelTheme.SanitizeText(n.ResponsibleParty ?? ""); break;
            case 3: cell.Value = ExcelTheme.SanitizeText(StripHtml(n.Insights)); break;
            case 4:
                if (n.NoOfSamples.HasValue)
                {
                    cell.Value = n.NoOfSamples.Value;
                    cell.Style.NumberFormat.Format = "#,##0";
                }
                break;
            case 5:
                if (n.TotalCharge.HasValue)
                {
                    cell.Value = n.TotalCharge.Value;
                    cell.Style.NumberFormat.Format = ExcelTheme.AccountingNumberFormat;
                    cell.Style.Font.Bold = true;
                }
                break;
            case ActionField: cell.Value = ExcelTheme.SanitizeText(StripHtml(n.ActionSolution)); break;
            case 7: cell.Value = ExcelTheme.SanitizeText(StripHtml(n.FeedbackResponse)); break;
            case 8: cell.Value = ExcelTheme.SanitizeText(n.Responsibility ?? ""); break;
            case 9: WriteDate(cell, n.DiscussionDate); break;
            case 10: WriteDate(cell, n.ETA); break;
            case 11: WriteDate(cell, n.ClosedDate); break;
            case StatusField: cell.Value = ExcelTheme.SanitizeText(n.StatusLabel ?? n.StatusCode); break;
        }
    }

    private static void WriteDate(IXLCell cell, DateTime? value)
    {
        if (!value.HasValue) return;
        var dt = value.Value;
        if (dt.Year < 1900 || dt.Year > 9999)
        {
            cell.Value = dt.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
            return;
        }
        cell.Value = dt;
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
        return ExcelTheme.SanitizeText(System.Text.RegularExpressions.Regex.Replace(s, "<[^>]+>", "").Trim());
    }
}
