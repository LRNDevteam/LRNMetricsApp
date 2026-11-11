using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;
using ClosedXML.Excel;
using LabMetricsDashboard.Models.Notes;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Key Insights &amp; Highlights import for the LIS, Production and Collection reports: the
/// downloadable template (the client's per-report layout, wide columns as merged cells) and the
/// parser that reads a filled-in template, or any sheet with the same headers, into notes.
/// </summary>
public static class KeyInsightsImportWorkbook
{
    private static readonly XLColor HeaderGreen = XLColor.FromHtml("#385624");
    private static readonly XLColor ActionRed = XLColor.FromHtml("#C00000");
    private static readonly XLColor GridLine = XLColor.FromHtml("#BFBFBF");

    private const int TitleRow = 1;
    private const int HeaderRow = 2;
    private const int BlankRows = 25;
    private const string DateFormat = "d-MMM";

    private static readonly string[] RiskOptions = ["High", "Medium", "Low"];
    private static readonly string[] CoreFields = ["#", "Risk", "Insights", "Status"];

    private sealed record Column(string FieldKey, string Header, int Span, double Width);

    private enum ReportKind { Production, Collection, Lis }

    private static ReportKind KindOf(string? reportName)
    {
        var name = reportName ?? "";
        if (name.Contains("Collection", StringComparison.OrdinalIgnoreCase)) return ReportKind.Collection;
        if (Regex.IsMatch(name, @"\bLIS\b", RegexOptions.IgnoreCase)) return ReportKind.Lis;
        return ReportKind.Production;
    }

    private static string Title(ReportKind kind) => kind switch
    {
        ReportKind.Lis => "LIS",
        ReportKind.Collection => "Collection",
        _ => "Production"
    };

    /// <summary>File name for the template download, e.g. "LIS Key Insights Import Template.xlsx".</summary>
    public static string TemplateFileName(string? reportName) => $"{Title(KindOf(reportName))} Key Insights Import Template.xlsx";

    /// <summary>The client's layout per report; spans are the merged widths of the sample sheets.</summary>
    private static Column[] LayoutFor(ReportKind kind) => kind switch
    {
        ReportKind.Lis =>
        [
            new("#", "#", 1, 6), new("Risk", "Risk", 1, 10), new("ResponsibleParty", "Responsible Party", 1, 18),
            new("Insights", "Insights", 2, 22), new("NoOfClaims", "# of Samples", 1, 11),
            new("TotalCharge", "Expected Reimbursement ($)", 1, 16),
            new("ActionSolution", "Action / Solution / Suggestions", 3, 16), new("FeedbackResponse", "Feedback / Response", 4, 12),
            new("Responsibility", "Responsibility", 1, 16), new("DiscussionDate", "Discussion Date", 1, 15),
            new("ETA", "ETA", 1, 10), new("ClosedDate", "Closed Date", 1, 10), new("Status", "Status", 1, 14)
        ],
        ReportKind.Collection =>
        [
            new("#", "#", 1, 6), new("Risk", "Risk", 1, 10), new("ResponsibleParty", "Responsible Party", 1, 14),
            new("Insights", "Insights", 6, 11), new("NoOfClaims", "# of Claims", 1, 10), new("TotalBill", "Total Bill", 1, 12),
            new("ActionSolution", "Action / Solution / Suggestions", 4, 11), new("FeedbackResponse", "Feedback / Response", 3, 11),
            new("Responsibility", "Responsibility", 1, 15), new("DiscussionDate", "Discussion Date", 1, 15),
            new("ETA", "ETA", 1, 10), new("ClosedDate", "Closed Date", 1, 10), new("Status", "Status", 1, 14)
        ],
        _ =>
        [
            new("#", "#", 1, 6), new("Risk", "Risk", 1, 10), new("ResponsibleParty", "Responsible Party", 1, 18),
            new("Insights", "Insights", 4, 12), new("NoOfClaims", "# of Claims", 1, 11), new("TotalBill", "Total Bill", 1, 12),
            new("ActionSolution", "Action / Solution / Suggestions", 5, 10), new("FeedbackResponse", "Feedback / Response", 3, 11),
            new("Responsibility", "Responsibility", 1, 15), new("DiscussionDate", "Discussion Date", 1, 15),
            new("ETA", "ETA", 1, 10), new("ClosedDate", "Closed Date", 1, 10), new("Status", "Status", 1, 14)
        ]
    };

    private static string StoredKey(string layoutKey) => layoutKey == "TotalBill" ? "TotalCharge" : layoutKey;

    /// <summary>
    /// Columns of the report's layout that are on its Key Insights template: everything when the
    /// template has no columns, otherwise #, Risk, Insights and Status plus the template's fields.
    /// </summary>
    private static List<Column> VisibleColumns(ReportKind kind, IReadOnlyList<NotesTemplateColumnDef>? templateColumns)
    {
        var layout = LayoutFor(kind);
        if (templateColumns is not { Count: > 0 }) return layout.ToList();
        var keys = templateColumns
            .Select(c => string.IsNullOrWhiteSpace(c.FieldKey) ? FieldKeyForHeader(c.ColumnName) : c.FieldKey!.Trim())
            .Where(k => k is not null)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        return layout.Where(c => CoreFields.Contains(c.FieldKey) || keys.Contains(StoredKey(c.FieldKey))).ToList();
    }

    // ── Template ────────────────────────────────────────────────────────────

    public static byte[] BuildTemplate(
        string? reportName, IReadOnlyList<NotesTemplateColumnDef>? templateColumns, NotesLookups? lookups)
    {
        var kind = KindOf(reportName);
        var columns = VisibleColumns(kind, templateColumns);
        var statusOptions = StatusLabels(lookups);

        using var wb = new XLWorkbook();
        var ws = wb.AddWorksheet("Key Insights");
        ws.Style.Font.FontName = "Calibri";
        ws.Style.Font.FontSize = 10;

        ws.Cell(TitleRow, 1).Value = Title(kind);
        ws.Cell(TitleRow, 1).Style.Font.Bold = true;
        ws.Cell(TitleRow, 1).Style.Font.FontSize = 11;

        var lastRow = HeaderRow + BlankRows;
        var col = 1;
        foreach (var c in columns)
        {
            var first = col;
            var last = col + c.Span - 1;
            for (var i = first; i <= last; i++) ws.Column(i).Width = c.Width;

            var header = ws.Range(HeaderRow, first, HeaderRow, last);
            if (c.Span > 1) header.Merge();
            ws.Cell(HeaderRow, first).Value = c.Header;
            header.Style.Font.Bold = true;
            header.Style.Font.FontColor = XLColor.White;
            header.Style.Fill.BackgroundColor = c.FieldKey == "ActionSolution" ? ActionRed : HeaderGreen;
            header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            header.Style.Alignment.WrapText = true;

            for (var r = HeaderRow + 1; r <= lastRow; r++)
            {
                var cell = ws.Range(r, first, r, last);
                if (c.Span > 1) cell.Merge();
                cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
                cell.Style.Alignment.WrapText = c.Span > 1;
            }

            var data = ws.Range(HeaderRow + 1, first, lastRow, first);
            switch (c.FieldKey)
            {
                case "Risk":
                    data.CreateDataValidation().List($"\"{string.Join(",", RiskOptions)}\"", true);
                    break;
                case "Status":
                    data.CreateDataValidation().List($"\"{string.Join(",", statusOptions)}\"", true);
                    break;
                case "NoOfClaims":
                    data.Style.NumberFormat.Format = "#,##0";
                    break;
                case "TotalCharge" or "TotalBill":
                    data.Style.NumberFormat.Format = ExcelTheme.AccountingNumberFormat;
                    break;
                case "DiscussionDate" or "ETA" or "ClosedDate":
                    data.Style.DateFormat.Format = DateFormat;
                    data.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
                    break;
            }
            col = last + 1;
        }

        var grid = ws.Range(HeaderRow, 1, lastRow, col - 1);
        grid.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        grid.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        grid.Style.Border.InsideBorderColor = GridLine;
        grid.Style.Border.OutsideBorderColor = GridLine;
        ws.Row(HeaderRow).Height = 30;
        ws.SheetView.FreezeRows(HeaderRow);

        var help = wb.AddWorksheet("Instructions");
        string[] lines =
        [
            $"{Title(kind)} Key Insights import",
            "",
            "Fill one insight per row on the Key Insights sheet, below the green header. Keep the header row as it is.",
            "Insights and Risk are required. Blank rows are skipped. The # column is ignored - numbers are assigned on import.",
            $"Risk: {string.Join(", ", RiskOptions)}.",
            $"Status: {string.Join(", ", statusOptions)}. Blank means Yet to Discuss. Closed needs a Closed Date.",
            "Dates: an Excel date or text such as 15-Nov or 11/15/2026.",
            "Numbers: plain numbers; $ and thousands separators are allowed.",
            "The whole file is checked before anything is saved - if any row has a problem, nothing is imported."
        ];
        for (var i = 0; i < lines.Length; i++) help.Cell(i + 1, 1).Value = lines[i];
        help.Cell(1, 1).Style.Font.Bold = true;
        help.Cell(1, 1).Style.Font.FontSize = 12;
        help.Column(1).Width = 120;

        ws.SetTabActive();
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static string[] StatusLabels(NotesLookups? lookups)
    {
        var labels = (lookups?.Statuses ?? [])
            .Select(s => string.IsNullOrWhiteSpace(s.Label) ? s.Code : s.Label)
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .Select(s => s.Replace(",", " "))
            .ToArray();
        return labels.Length > 0 ? labels : ["Yet to Discuss", "Open", "In Progress", "Deferred", "Closed"];
    }

    // ── Import ──────────────────────────────────────────────────────────────

    public sealed class ImportResult
    {
        public List<NoteSaveRequest> Rows { get; } = [];
        public List<string> Errors { get; } = [];
        public List<string> Warnings { get; } = [];
    }

    private sealed record Field(string Key, int FirstColumn, int LastColumn);
    private sealed record Table(IXLWorksheet Sheet, int HeaderRow, string? TitleText);

    /// <summary>
    /// Reads the report's Key Insights table from the workbook. A sheet may hold several tables
    /// (the client's sample has Production, Collection and LIS one under another); the one titled
    /// for this report is used. Nothing is returned in <see cref="ImportResult.Rows"/> when any row fails.
    /// </summary>
    public static ImportResult Parse(Stream stream, string? reportName, NotesLookups? lookups, DateTime referenceDate)
    {
        var result = new ImportResult();
        var kind = KindOf(reportName);

        using var wb = new XLWorkbook(stream);
        var tables = FindTables(wb);
        if (tables.Count == 0)
        {
            result.Errors.Add("No Key Insights header row was found. The sheet needs a header row with at least Risk and Insights - use Download Template.");
            return result;
        }

        var table = PickTable(tables, kind, out var pickError);
        if (table is null)
        {
            result.Errors.Add(pickError!);
            return result;
        }

        var fields = ReadHeader(table.Sheet, table.HeaderRow, result.Warnings);
        if (!fields.Any(f => f.Key == "Insights") || !fields.Any(f => f.Key == "Risk"))
        {
            result.Errors.Add("The header row must include Risk and Insights columns.");
            return result;
        }

        var nextHeader = tables
            .Where(t => t.Sheet == table.Sheet && t.HeaderRow > table.HeaderRow)
            .Select(t => t.HeaderRow)
            .DefaultIfEmpty(int.MaxValue)
            .Min();
        var lastRow = Math.Min(table.Sheet.LastRowUsed()?.RowNumber() ?? table.HeaderRow, nextHeader - 1);

        var statuses = lookups?.Statuses ?? [];
        var rows = new List<NoteSaveRequest>();
        for (var r = table.HeaderRow + 1; r <= lastRow; r++)
        {
            var row = new RowReader(table.Sheet, table.HeaderRow, r, fields);
            if (row.IsBlank) continue;

            var errors = new List<string>();
            var req = new NoteSaveRequest();

            var insights = row.Text("Insights");
            if (insights is null) errors.Add("Insights is required");
            else req.Insights = ToHtml(insights);

            var risk = row.Text("Risk");
            if (risk is null) errors.Add("Risk is required");
            else if (MapRisk(risk) is { } riskCode) req.RiskCode = riskCode;
            else errors.Add($"Risk '{risk}' is not High, Medium or Low");

            var status = row.Text("Status");
            if (status is null) req.StatusCode = "Discuss";
            else if (MapStatus(status, statuses) is { } statusCode) req.StatusCode = statusCode;
            else errors.Add($"Status '{status}' is not one of {string.Join(", ", StatusLabels(lookups))}");

            req.ResponsibleParty = row.Text("ResponsibleParty");
            req.ActionSolution = row.Text("ActionSolution");
            req.FeedbackResponse = row.Text("FeedbackResponse");
            req.Responsibility = row.Text("Responsibility");
            req.DataLink = row.Text("DataLink");

            if (row.Has("NoOfClaims"))
            {
                if (row.Number("NoOfClaims", out var n, out var raw)) req.NoOfSamples = n is null ? null : (int)Math.Round(n.Value);
                else errors.Add($"{row.Header("NoOfClaims")} '{raw}' is not a number");
            }
            if (row.Has("TotalCharge"))
            {
                if (row.Number("TotalCharge", out var n, out var raw)) req.TotalCharge = n;
                else errors.Add($"{row.Header("TotalCharge")} '{raw}' is not an amount");
            }

            req.DiscussionDate = ReadDate(row, "DiscussionDate", referenceDate, errors);
            req.ETA = ReadDate(row, "ETA", referenceDate, errors);
            req.ClosedDate = ReadDate(row, "ClosedDate", referenceDate, errors);

            if (req.StatusCode == "Closed" && req.ClosedDate is null)
                errors.Add("Closed Date is required when Status is Closed");

            if (errors.Count > 0) result.Errors.Add($"Row {r}: {string.Join("; ", errors)}.");
            else rows.Add(req);
        }

        if (result.Errors.Count == 0)
        {
            if (rows.Count == 0) result.Errors.Add("No insight rows were found below the header row.");
            else result.Rows.AddRange(rows);
        }
        return result;
    }

    private static List<Table> FindTables(XLWorkbook wb)
    {
        var tables = new List<Table>();
        foreach (var sheet in wb.Worksheets)
        {
            foreach (var row in sheet.RowsUsed().Take(2000))
            {
                var keys = row.CellsUsed().Select(c => FieldKeyForHeader(c.GetFormattedString())).ToList();
                if (!keys.Contains("Risk") || !keys.Contains("Insights")) continue;
                tables.Add(new Table(sheet, row.RowNumber(), TitleAbove(sheet, row.RowNumber())));
            }
        }
        return tables;
    }

    /// <summary>The nearest non-empty text in the two rows above a header (its section title).</summary>
    private static string? TitleAbove(IXLWorksheet sheet, int headerRow)
    {
        for (var r = headerRow - 1; r >= Math.Max(1, headerRow - 2); r--)
        {
            var text = string.Join(" ", sheet.Row(r).CellsUsed().Select(c => c.GetFormattedString().Trim()).Where(s => s.Length > 0));
            if (text.Length > 0) return text;
        }
        return null;
    }

    private static ReportKind? KindOfTitle(string? title)
    {
        if (string.IsNullOrWhiteSpace(title)) return null;
        if (title.Contains("Collection", StringComparison.OrdinalIgnoreCase)) return ReportKind.Collection;
        if (title.Contains("Production", StringComparison.OrdinalIgnoreCase)) return ReportKind.Production;
        if (Regex.IsMatch(title, @"\bLIS\b|\bLIMS\b", RegexOptions.IgnoreCase)) return ReportKind.Lis;
        return null;
    }

    private static Table? PickTable(List<Table> tables, ReportKind kind, out string? error)
    {
        error = null;
        var titled = tables.FirstOrDefault(t => KindOfTitle(t.TitleText) == kind);
        if (titled is not null) return titled;

        var untitled = tables.Where(t => KindOfTitle(t.TitleText) is null).ToList();
        if (untitled.Count == 1) return untitled[0];

        error = untitled.Count > 1
            ? $"The workbook has several Key Insights tables. Put \"{Title(kind)}\" in the row above the one to import."
            : $"The workbook has no {Title(kind)} Key Insights table (found: {string.Join(", ", tables.Select(t => t.TitleText).Distinct())}). Use the {Title(kind)} template.";
        return null;
    }

    private static List<Field> ReadHeader(IXLWorksheet sheet, int headerRow, List<string> warnings)
    {
        var fields = new List<Field>();
        foreach (var cell in sheet.Row(headerRow).CellsUsed())
        {
            var text = cell.GetFormattedString().Trim();
            if (text.Length == 0) continue;
            var key = FieldKeyForHeader(text);
            if (key is null)
            {
                warnings.Add($"Column \"{text}\" is not a Key Insights field and was ignored.");
                continue;
            }
            if (key == "#" || fields.Any(f => f.Key == key)) continue;

            var merged = sheet.MergedRanges.FirstOrDefault(m => m.Contains(cell));
            var last = merged?.RangeAddress.LastAddress.ColumnNumber ?? cell.Address.ColumnNumber;
            fields.Add(new Field(key, cell.Address.ColumnNumber, last));
        }
        return fields;
    }

    /// <summary>The note field a header names, matching the template captions and their variants.</summary>
    private static string? FieldKeyForHeader(string? header)
    {
        var n = Regex.Replace((header ?? "").Trim().ToLowerInvariant(), @"\s+", " ");
        if (n.Length == 0) return null;
        if (n is "#" or "no" or "no." or "s.no" or "sl.no") return "#";
        if (n == "risk") return "Risk";
        if (n.Contains("responsible party")) return "ResponsibleParty";
        if (n is "insights" or "insight") return "Insights";
        if (n.Contains("link") || n == "data") return "DataLink";
        if (n.Contains("claim") || n.Contains("sample") || n.Contains("case")) return "NoOfClaims";
        if (n.Contains("bill") || n.Contains("charge") || n.Contains("reimbursement") || n.Contains("balance")) return "TotalCharge";
        if (n.Contains("action")) return "ActionSolution";
        if (n.Contains("feedback")) return "FeedbackResponse";
        if (n.Contains("responsibility") || n.Contains("response by")) return "Responsibility";
        if (n.Contains("discussion")) return "DiscussionDate";
        if (n == "eta") return "ETA";
        if (n.Contains("closed")) return "ClosedDate";
        if (n == "status") return "Status";
        return null;
    }

    private static string? MapRisk(string value)
    {
        var v = value.Trim().ToLowerInvariant();
        if (v.StartsWith("high") || v == "red") return "Red";
        if (v.StartsWith("med") || v == "yellow" || v == "amber") return "Yellow";
        if (v.StartsWith("low") || v == "green") return "Green";
        return null;
    }

    private static string? MapStatus(string value, IReadOnlyList<NotesLookupItem> statuses)
    {
        var v = value.Trim();
        var hit = statuses.FirstOrDefault(s =>
            string.Equals(s.Label, v, StringComparison.OrdinalIgnoreCase) || string.Equals(s.Code, v, StringComparison.OrdinalIgnoreCase));
        if (hit is not null) return hit.Code;

        var l = v.ToLowerInvariant();
        if (l.Contains("discuss")) return "Discuss";
        if (l.Contains("progress") || l == "wip") return "WIP";
        if (l.Contains("defer")) return "Deferred";
        if (l.StartsWith("close")) return "Closed";
        if (l == "open") return "Open";
        return null;
    }

    private static DateTime? ReadDate(RowReader row, string key, DateTime referenceDate, List<string> errors)
    {
        if (!row.Has(key)) return null;
        if (row.Date(key, referenceDate, out var date, out var raw)) return date;
        errors.Add($"{row.Header(key)} '{raw}' is not a date");
        return null;
    }

    /// <summary>Plain cell text as the insight editor's HTML: escaped, line breaks kept.</summary>
    private static string ToHtml(string text) =>
        string.Join("<br>", text.Replace("\r\n", "\n").Split('\n').Select(l => WebUtility.HtmlEncode(l.TrimEnd())));

    private static bool IsDash(string s) => s is "-" or "–" or "—" or "N/A" or "n/a" or "NA";

    /// <summary>One data row, read through the header's columns (a field may span merged cells).</summary>
    private sealed class RowReader(IXLWorksheet sheet, int headerRow, int row, List<Field> fields)
    {
        private Field? Find(string key) => fields.FirstOrDefault(f => f.Key == key);

        public bool Has(string key) => Find(key) is not null;

        public string Header(string key) =>
            Find(key) is { } f ? sheet.Cell(headerRow, f.FirstColumn).GetFormattedString().Trim() : key;

        public bool IsBlank => fields.All(f => Cells(f).All(c => string.IsNullOrWhiteSpace(c.GetFormattedString())));

        private IEnumerable<IXLCell> Cells(Field f) =>
            Enumerable.Range(f.FirstColumn, f.LastColumn - f.FirstColumn + 1).Select(c => sheet.Cell(row, c));

        private IXLCell? FirstValue(string key) =>
            Find(key) is { } f ? Cells(f).FirstOrDefault(c => !c.IsEmpty() && c.GetFormattedString().Trim().Length > 0) : null;

        /// <summary>The field's text (cells of a merged span joined), or null when blank or a dash.</summary>
        public string? Text(string key)
        {
            if (Find(key) is not { } f) return null;
            var parts = Cells(f).Select(c => c.GetString().Trim()).Where(s => s.Length > 0).ToList();
            if (parts.Count == 0) return null;
            var text = string.Join(" ", parts);
            return IsDash(text) ? null : text;
        }

        public bool Number(string key, out decimal? value, out string raw)
        {
            value = null;
            raw = "";
            var cell = FirstValue(key);
            if (cell is null) return true;
            if (cell.DataType == XLDataType.Number)
            {
                value = (decimal)cell.GetDouble();
                return true;
            }
            raw = cell.GetFormattedString().Trim();
            var s = raw.Replace("$", "").Replace(",", "").Replace(" ", "");
            if (s.Length == 0 || IsDash(s)) { value = raw.Contains('$') ? 0m : null; return true; }
            var negative = s.StartsWith('(') && s.EndsWith(')');
            if (negative) s = s[1..^1];
            if (!decimal.TryParse(s, NumberStyles.Number, CultureInfo.InvariantCulture, out var d)) return false;
            value = negative ? -d : d;
            return true;
        }

        private static readonly string[] DateFormats =
        [
            "d-MMM-yyyy", "dd-MMM-yyyy", "d-MMM-yy", "dd-MMM-yy", "M/d/yyyy", "MM/dd/yyyy", "M/d/yy",
            "yyyy-MM-dd", "d MMM yyyy", "MMM d, yyyy", "MMM d yyyy", "MM.dd.yyyy", "M.d.yyyy"
        ];
        private static readonly string[] YearlessFormats = ["d-MMM", "dd-MMM", "d MMM", "MMM d", "M/d", "MM/dd"];

        public bool Date(string key, DateTime referenceDate, out DateTime? value, out string raw)
        {
            value = null;
            raw = "";
            var cell = FirstValue(key);
            if (cell is null) return true;
            if (cell.DataType == XLDataType.DateTime)
            {
                value = cell.GetDateTime().Date;
                return true;
            }
            if (cell.DataType == XLDataType.Number)
            {
                var oa = cell.GetDouble();
                if (oa is > 1 and < 2958466) { value = DateTime.FromOADate(oa).Date; return true; }
                raw = cell.GetFormattedString();
                return false;
            }
            raw = cell.GetFormattedString().Trim();
            if (raw.Length == 0 || IsDash(raw)) return true;
            var inv = CultureInfo.InvariantCulture;
            if (DateTime.TryParseExact(raw, DateFormats, inv, DateTimeStyles.AllowWhiteSpaces, out var dt))
            {
                value = dt.Date;
                return true;
            }
            if (DateTime.TryParseExact(raw, YearlessFormats, inv, DateTimeStyles.AllowWhiteSpaces, out dt))
            {
                // No year: the one that puts the date nearest the report week.
                var d = new DateTime(referenceDate.Year, dt.Month, Math.Min(dt.Day, DateTime.DaysInMonth(referenceDate.Year, dt.Month)));
                if (d > referenceDate.AddMonths(6)) d = d.AddYears(-1);
                else if (d < referenceDate.AddMonths(-6)) d = d.AddYears(1);
                value = d;
                return true;
            }
            return false;
        }
    }
}
