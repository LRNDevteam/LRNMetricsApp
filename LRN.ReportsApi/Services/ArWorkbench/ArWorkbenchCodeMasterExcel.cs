using ClosedXML.Excel;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Excel for the central Denial Code Master. The import reads columns by HEADER NAME, not position,
/// so both the business workbook (DenialCodes&amp;Categorization_Master.xlsx: "Denial Code",
/// "Denial Code Description", "Denial Categorization" + a "Non-collectible Denials" sheet) and this
/// screen's own export load as they are. A column a sheet does not have is left unchanged.
/// </summary>
internal static class ArWorkbenchCodeMasterExcel
{
    public const string SheetName = "Denial Code Master";
    private const string ListsSheetName = "Lists";
    private const string TitleText = "AR WORKBENCH - DENIAL CODE DESCRIPTIONS (ALL LABS)";
    private const int HeaderRow = 2;
    private const int FirstDataRow = 3;
    private const int ValidationRows = 5000;

    private static readonly (CodeMasterColumn Column, string Header)[] Layout =
    [
        (CodeMasterColumn.Code, "Denial Code"),
        (CodeMasterColumn.Description, "Denial Code Description"),
        (CodeMasterColumn.ActionCategory, "Action Category"),
        (CodeMasterColumn.Classification, "Classification"),
        (CodeMasterColumn.Coverage, "Coverage Status"),
        (CodeMasterColumn.IcdCompliance, "ICD Compliance"),
        (CodeMasterColumn.Validity, "Denial Validity"),
        (CodeMasterColumn.NonCollectible, "Non-Collectible"),
        (CodeMasterColumn.Active, "Active")
    ];

    /// <summary>Accepted header spellings (compared without spaces, hyphens, slashes, case).</summary>
    private static readonly Dictionary<string, CodeMasterColumn> Aliases = BuildAliases();

    private static Dictionary<string, CodeMasterColumn> BuildAliases()
    {
        var map = new Dictionary<string, CodeMasterColumn>();
        void Add(CodeMasterColumn c, params string[] names) { foreach (var n in names) map[Key(n)] = c; }
        Add(CodeMasterColumn.Code, "Denial Code", "Code", "CARC", "Denial Codes");
        Add(CodeMasterColumn.Description, "Denial Code Description", "Description", "Denial Description", "Code Description");
        Add(CodeMasterColumn.ActionCategory, "Action Category", "Denial Categorization", "Denial Categorisation", "Recommended Action Category", "Categorization", "Root Cause");
        Add(CodeMasterColumn.Classification, "Classification", "Denial Classification");
        Add(CodeMasterColumn.Coverage, "Coverage Status", "Coverage");
        Add(CodeMasterColumn.IcdCompliance, "ICD Compliance", "ICD Compliance Status", "ICD Complaince");
        Add(CodeMasterColumn.Validity, "Denial Validity", "Validity");
        Add(CodeMasterColumn.NonCollectible, "Non-Collectible", "Non Collectible", "Is Non-Collectible", "NonCollectible");
        Add(CodeMasterColumn.Active, "Active", "Is Active");
        return map;
    }

    private static string Key(string? text) =>
        new string((text ?? string.Empty).Where(ch => !char.IsWhiteSpace(ch) && ch is not ('-' or '/' or '_' or '&')).ToArray()).ToUpperInvariant();

    private static bool IsNonCollectibleSheet(string name) => Key(name).Contains("NONCOLLECT", StringComparison.Ordinal);

    public static (ArWorkbenchCodeMasterParsed? Parsed, string? Error) Parse(Stream stream)
    {
        XLWorkbook workbook;
        try { workbook = new XLWorkbook(stream); }
        catch (Exception) { return (null, "The file could not be read as an Excel workbook (.xlsx)."); }

        using (workbook)
        {
            var parsed = new ArWorkbenchCodeMasterParsed();
            var foundMain = false;
            foreach (var sheet in workbook.Worksheets)
            {
                var (headerRow, columns) = FindHeader(sheet);
                if (headerRow == 0) continue;     // a lists / notes sheet
                var lastRow = sheet.LastRowUsed()?.RowNumber() ?? 0;
                var codeCol = columns[CodeMasterColumn.Code];

                if (IsNonCollectibleSheet(sheet.Name))
                {
                    if (parsed.NonCollectibleCodes is not null) return (null, "The file has more than one Non-collectible sheet.");
                    parsed.NonCollectibleSheet = sheet.Name;
                    parsed.NonCollectibleCodes = new();
                    columns.TryGetValue(CodeMasterColumn.Description, out var descCol);
                    for (var row = headerRow + 1; row <= lastRow; row++)
                    {
                        var code = Text(sheet.Cell(row, codeCol));
                        if (code is null) continue;
                        parsed.NonCollectibleCodes.Add((row, code, descCol > 0 ? Text(sheet.Cell(row, descCol)) : null));
                    }
                    continue;
                }

                foundMain = true;
                for (var row = headerRow + 1; row <= lastRow; row++)
                {
                    var code = Text(sheet.Cell(row, codeCol));
                    if (code is null) continue;
                    var values = new Dictionary<CodeMasterColumn, string?>();
                    foreach (var (column, index) in columns)
                        if (column != CodeMasterColumn.Code) values[column] = Text(sheet.Cell(row, index));
                    parsed.Rows.Add(new CodeMasterImportLine { Sheet = sheet.Name, Line = row, Code = code, Values = values });
                }
            }

            if (!foundMain && parsed.NonCollectibleCodes is null)
                return (null, "No sheet with a \"Denial Code\" column was found. Use Download Template or Export Excel for the layout.");
            return (parsed, null);
        }
    }

    /// <summary>The first of rows 1-5 holding a "Denial Code" header, and every recognised column on it.</summary>
    private static (int Row, Dictionary<CodeMasterColumn, int> Columns) FindHeader(IXLWorksheet sheet)
    {
        var lastCol = Math.Min(sheet.LastColumnUsed()?.ColumnNumber() ?? 0, 60);
        for (var row = 1; row <= 5; row++)
        {
            var columns = new Dictionary<CodeMasterColumn, int>();
            for (var col = 1; col <= lastCol; col++)
            {
                if (Aliases.TryGetValue(Key(sheet.Cell(row, col).GetFormattedString()), out var column) && !columns.ContainsKey(column))
                    columns[column] = col;
            }
            if (columns.ContainsKey(CodeMasterColumn.Code)) return (row, columns);
        }
        return (0, new());
    }

    public static byte[] Build(IReadOnlyList<ArWorkbenchCodeMasterRow> rows, ArWorkbenchCodeMasterOptions options)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add(SheetName);
        DenialExcelTheme.ApplyDefaults(sheet);
        sheet.TabColor = DenialExcelTheme.TabGreen;

        sheet.Cell(1, 1).Value = TitleText;
        var title = sheet.Range(1, 1, 1, Layout.Length).Merge();
        title.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Font.SetFontSize(DenialExcelTheme.FontSizeTitle);
        title.Style.Fill.SetBackgroundColor(DenialExcelTheme.TitleBg);
        for (var i = 0; i < Layout.Length; i++)
            DenialExcelTheme.StyleHeaderCell(sheet.Cell(HeaderRow, i + 1).SetValue(Layout[i].Header));

        // Codes are text: "016" must not turn into 16.
        sheet.Range(FirstDataRow, 1, FirstDataRow + Math.Max(rows.Count, ValidationRows), 1).Style.NumberFormat.Format = "@";

        var r = FirstDataRow;
        foreach (var row in rows)
        {
            sheet.Cell(r, 1).Value = row.DenialCode;
            sheet.Cell(r, 2).Value = row.DenialDescription;
            sheet.Cell(r, 3).Value = row.ActionCategory;
            sheet.Cell(r, 4).Value = row.DenialClassification;
            sheet.Cell(r, 5).Value = row.CoverageStatus;
            sheet.Cell(r, 6).Value = row.ICDComplianceStatus;
            sheet.Cell(r, 7).Value = row.DenialValidity;
            sheet.Cell(r, 8).Value = row.IsNonCollectible ? "Yes" : "No";
            sheet.Cell(r, 9).Value = row.IsActive ? "Yes" : "No";
            r++;
        }
        if (rows.Count == 0)
        {
            string[] sample = ["4", "Procedure code inconsistent with modifier (sample row - replace or delete)", "Procedure Code, Modifier or Coding Related Issues", "", "", "", "", "No", "Yes"];
            for (var i = 0; i < sample.Length; i++) sheet.Cell(FirstDataRow, i + 1).Value = sample[i];
        }

        AddLists(workbook, sheet, options);
        sheet.SheetView.FreezeRows(HeaderRow);
        sheet.Columns().AdjustToContents(HeaderRow, 200);
        sheet.Column(2).Width = Math.Min(Math.Max(sheet.Column(2).Width, 30), 70);
        sheet.Column(3).Width = Math.Min(Math.Max(sheet.Column(3).Width, 25), 55);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    /// <summary>Dropdown sources on a Lists sheet (no "Denial Code" header, so the import skips it).</summary>
    private static void AddLists(XLWorkbook workbook, IXLWorksheet sheet, ArWorkbenchCodeMasterOptions options)
    {
        var lists = workbook.Worksheets.Add(ListsSheetName);
        DenialExcelTheme.ApplyDefaults(lists);
        lists.TabColor = DenialExcelTheme.TabGold;
        var sources = new (int TargetCol, string Title, IReadOnlyList<string> Values, bool Strict)[]
        {
            (3, "Action Category", options.ActionCategories, false),
            (4, "Classification", options.DenialClassifications, false),
            (5, "Coverage Status", options.CoverageStatuses, false),
            (6, "ICD Compliance", options.ICDComplianceStatuses, false),
            (7, "Denial Validity", options.DenialValidities, false),
            (8, "Yes / No", ["Yes", "No"], true),
            (9, "Yes / No", ["Yes", "No"], true)
        };
        var col = 1;
        foreach (var (target, header, values, strict) in sources)
        {
            DenialExcelTheme.StyleHeaderCell(lists.Cell(1, col).SetValue(header));
            for (var i = 0; i < values.Count; i++) lists.Cell(i + 2, col).Value = values[i];
            if (values.Count > 0)
            {
                var validation = sheet.Range(FirstDataRow, target, FirstDataRow + ValidationRows, target).CreateDataValidation();
                validation.List(lists.Range(2, col, values.Count + 1, col), true);
                // Lists suggest values; only Yes / No is enforced (new categories may be typed).
                validation.ShowErrorMessage = strict;
            }
            col++;
        }
        lists.Columns().AdjustToContents();
    }

    private static string? Text(IXLCell cell)
    {
        var value = cell.GetFormattedString().Trim();
        return value.Length == 0 ? null : value;
    }
}
