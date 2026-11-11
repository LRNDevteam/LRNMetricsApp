using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using ClosedXML.Excel;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Data Processing > Upload Master File: the standard master file template (one workbook, sheets
/// "Claim Level" and "Line Level") and the check an uploaded workbook passes before it is queued for
/// the Master File Processor.
/// <para>
/// The columns come from LRN.MasterFileProcessorWorker/Schemas/StandardUpload/*.schema.json, linked
/// into this project (ArWorkbench/MasterFileTemplate). The worker reads the same two files to
/// validate and standardize the upload, so the template a user downloads, the check here and the
/// check the worker repeats can never disagree. Header names are the worker's common column names.
/// </para>
/// <para>
/// No cell value is ever echoed back: problems are reported by sheet, column and row number only
/// (the workbook is PHI).
/// </para>
/// </summary>
internal static class ArWorkbenchMasterFileTemplate
{
    private const string SchemaFolder = "ArWorkbench/MasterFileTemplate";
    private const string ClaimSchemaFile = "StandardUpload_ClaimLevel.schema.json";
    private const string LineSchemaFile = "StandardUpload_LineLevel.schema.json";
    private const string GuideSheetName = "Instructions";
    private const int TextFormatRows = 5000;
    private const int MaxIssuesPerKind = 5;

    private static readonly Lazy<(TemplateSchema Claim, TemplateSchema Line)> Schemas = new(LoadSchemas);

    public static TemplateSchema ClaimSchema => Schemas.Value.Claim;
    public static TemplateSchema LineSchema => Schemas.Value.Line;
    public static string Version => ClaimSchema.TemplateVersion ?? "1.0";

    private static (TemplateSchema, TemplateSchema) LoadSchemas()
    {
        static TemplateSchema Load(string file)
        {
            var path = Path.Combine(AppContext.BaseDirectory, SchemaFolder, file);
            if (!File.Exists(path))
                throw new FileNotFoundException($"The master file template schema is missing from the API's output folder ({SchemaFolder}/{file}).", path);
            return JsonSerializer.Deserialize<TemplateSchema>(File.ReadAllText(path), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new InvalidOperationException($"The master file template schema {file} could not be read.");
        }
        return (Load(ClaimSchemaFile), Load(LineSchemaFile));
    }

    // ------------------------------------------------------------------------------------------
    // Template
    // ------------------------------------------------------------------------------------------

    public static byte[] Build()
    {
        using var workbook = new XLWorkbook();
        AddGuide(workbook);
        AddDataSheet(workbook, ClaimSchema, DenialExcelTheme.TabGreen);
        AddDataSheet(workbook, LineSchema, DenialExcelTheme.TabGold);
        workbook.Worksheet(ClaimSchema.SheetName).SetTabActive();

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    /// <summary>
    /// A data sheet: the header on row 1 (where the worker reads it) and nothing else, so no sample
    /// row can be loaded by mistake. Required headers are marked by colour and a cell note, never in
    /// the header text, which has to stay the exact column name.
    /// </summary>
    private static void AddDataSheet(XLWorkbook workbook, TemplateSchema schema, XLColor tab)
    {
        var sheet = workbook.Worksheets.Add(schema.SheetName);
        DenialExcelTheme.ApplyDefaults(sheet);
        sheet.TabColor = tab;

        for (var i = 0; i < schema.Columns.Count; i++)
        {
            var column = schema.Columns[i];
            var cell = sheet.Cell(1, i + 1).SetValue(column.Name);
            DenialExcelTheme.StyleHeaderCell(cell, column.Required ? XLColor.FromHtml("#C00000") : null);
            cell.CreateComment().AddText($"{(column.Required ? "Required. " : "")}{TypeLabel(column.DataType)}. {column.Description}");

            // Identifiers and codes are text: "016" must not become 16, "87798" not a number.
            if (column.DataType is "string")
                sheet.Range(2, i + 1, TextFormatRows, i + 1).Style.NumberFormat.Format = "@";
            else if (column.DataType is "date")
                sheet.Range(2, i + 1, TextFormatRows, i + 1).Style.NumberFormat.Format = "mm/dd/yyyy";
        }

        sheet.SheetView.FreezeRows(1);
        sheet.Columns(1, schema.Columns.Count).AdjustToContents(1, 1);
        foreach (var column in sheet.Columns(1, schema.Columns.Count)) column.Width = Math.Max(column.Width + 2, 14);
    }

    private static void AddGuide(XLWorkbook workbook)
    {
        var sheet = workbook.Worksheets.Add(GuideSheetName);
        DenialExcelTheme.ApplyDefaults(sheet);
        sheet.TabColor = DenialExcelTheme.TitleBg;

        sheet.Cell(1, 1).Value = $"AR WORKBENCH - STANDARD MASTER FILE TEMPLATE (v{Version})";
        var title = sheet.Range(1, 1, 1, 5).Merge();
        title.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Font.SetFontSize(DenialExcelTheme.FontSizeTitle);
        title.Style.Fill.SetBackgroundColor(DenialExcelTheme.TitleBg);

        string[] steps =
        [
            $"1. Put one row per claim on the \"{ClaimSchema.SheetName}\" sheet and one row per CPT line on the \"{LineSchema.SheetName}\" sheet.",
            "2. Map your billing system's columns to the columns below. Keep the header row exactly as it is: do not rename, merge or move headers.",
            "3. Required columns (red headers) must have a value on every row. Leave optional columns empty when you have no value; you may delete optional columns you never use.",
            $"4. ClaimID links the two sheets: every line's ClaimID must be a ClaimID on the \"{ClaimSchema.SheetName}\" sheet.",
            "5. Dates as MM/DD/YYYY, amounts as plain numbers (no currency text). Do not add totals, blank separator rows or notes below the data.",
            "6. Upload the workbook on AR Workbench > Data Processing > Upload Master File and choose the week the data belongs to. It replaces the lab's current claim-level and line-level data, exactly like the weekly master file."
        ];
        for (var i = 0; i < steps.Length; i++)
        {
            sheet.Cell(3 + i, 1).Value = steps[i];
            sheet.Range(3 + i, 1, 3 + i, 5).Merge().Style.Alignment.SetWrapText(true);
            sheet.Row(3 + i).Height = 30;
        }

        var headerRow = 3 + steps.Length + 1;
        string[] headers = ["Sheet", "Column (header)", "Required", "Type", "What goes in it"];
        for (var i = 0; i < headers.Length; i++)
            DenialExcelTheme.StyleHeaderCell(sheet.Cell(headerRow, i + 1).SetValue(headers[i]));

        var row = headerRow + 1;
        foreach (var schema in new[] { ClaimSchema, LineSchema })
        {
            foreach (var column in schema.Columns)
            {
                sheet.Cell(row, 1).Value = schema.SheetName;
                sheet.Cell(row, 2).Value = column.Name;
                sheet.Cell(row, 3).Value = column.Required ? "Yes" : "No";
                sheet.Cell(row, 4).Value = TypeLabel(column.DataType);
                sheet.Cell(row, 5).Value = column.Description;
                if (column.Required) sheet.Range(row, 2, row, 3).Style.Font.SetBold().Font.SetFontColor(XLColor.FromHtml("#C00000"));
                row++;
            }
        }

        sheet.Column(1).Width = 14;
        sheet.Column(2).Width = 36;
        sheet.Column(3).Width = 10;
        sheet.Column(4).Width = 12;
        sheet.Column(5).Width = 90;
        sheet.Range(headerRow + 1, 5, row, 5).Style.Alignment.SetWrapText(true);
        sheet.SheetView.FreezeRows(headerRow);
    }

    private static string TypeLabel(string? dataType) => dataType switch
    {
        "date" => "Date",
        "decimal" => "Amount",
        "integer" => "Whole number",
        _ => "Text"
    };

    // ------------------------------------------------------------------------------------------
    // Validation
    // ------------------------------------------------------------------------------------------

    public static MasterFileValidationResult Validate(Stream stream)
    {
        var result = new MasterFileValidationResult { TemplateVersion = Version };

        XLWorkbook workbook;
        try { workbook = new XLWorkbook(stream); }
        catch (Exception)
        {
            result.Errors.Add("The file could not be read as an Excel workbook (.xlsx). Save it as .xlsx from Excel and try again.");
            return result;
        }

        using (workbook)
        {
            var claim = ValidateSheet(workbook, ClaimSchema, result);
            var line = ValidateSheet(workbook, LineSchema, result);
            result.ClaimRows = claim?.Rows ?? 0;
            result.LineRows = line?.Rows ?? 0;

            if (claim is not null && line is not null && claim.ClaimIds.Count > 0 && line.ClaimIds.Count > 0)
            {
                var orphanLines = line.ClaimIds.Count(id => !claim.ClaimIds.Contains(id));
                if (orphanLines > 0)
                    result.Warnings.Add($"{orphanLines:N0} distinct ClaimID(s) on \"{LineSchema.SheetName}\" have no row on \"{ClaimSchema.SheetName}\". Their lines load, but the AR Workbench works claims from the Claim Level sheet.");

                var claimsWithoutLines = claim.ClaimIds.Count(id => !line.ClaimIds.Contains(id));
                if (claimsWithoutLines > 0)
                    result.Warnings.Add($"{claimsWithoutLines:N0} claim(s) on \"{ClaimSchema.SheetName}\" have no line on \"{LineSchema.SheetName}\" (no CPT detail for them).");
            }
        }

        return result;
    }

    private sealed class SheetSummary
    {
        public int Rows { get; set; }
        public HashSet<string> ClaimIds { get; } = new(StringComparer.OrdinalIgnoreCase);
    }

    private static SheetSummary? ValidateSheet(XLWorkbook workbook, TemplateSchema schema, MasterFileValidationResult result)
    {
        // The worker matches the sheet name exactly (case aside), so this does too.
        var sheet = workbook.Worksheets.FirstOrDefault(s => string.Equals(s.Name.Trim(), schema.SheetName, StringComparison.OrdinalIgnoreCase));
        if (sheet is null)
        {
            result.Errors.Add($"The workbook has no \"{schema.SheetName}\" sheet. Start from Download Template and keep its sheet names.");
            return null;
        }

        // Header on row 1, as the worker reads it.
        var lastCol = sheet.LastColumnUsed()?.ColumnNumber() ?? 0;
        var byKey = schema.Columns.ToDictionary(c => Key(c.Name), c => c);
        var found = new Dictionary<string, int>();      // template column name -> sheet column number
        var unknown = new List<string>();
        for (var col = 1; col <= lastCol; col++)
        {
            var header = sheet.Cell(1, col).GetFormattedString().Trim();
            if (header.Length == 0) continue;
            if (byKey.TryGetValue(Key(header), out var column))
            {
                if (!found.TryAdd(column.Name, col))
                    result.Errors.Add($"\"{schema.SheetName}\": column \"{column.Name}\" appears more than once.");
            }
            else
            {
                unknown.Add(header);
            }
        }

        var missing = schema.Columns.Where(c => c.Required && !found.ContainsKey(c.Name)).Select(c => c.Name).ToList();
        if (missing.Count > 0)
            result.Errors.Add($"\"{schema.SheetName}\": required column(s) missing: {string.Join(", ", missing)}.");
        if (unknown.Count > 0)
            result.Warnings.Add($"\"{schema.SheetName}\": {unknown.Count} column(s) are not in the template and are carried as extra columns only: {string.Join(", ", unknown.Take(10))}{(unknown.Count > 10 ? ", ..." : "")}.");

        var summary = new SheetSummary();
        var lastRow = sheet.LastRowUsed()?.RowNumber() ?? 1;
        var blanks = new Dictionary<string, List<int>>();
        var badValues = new Dictionary<string, List<int>>();
        var duplicateClaimRows = new List<int>();
        found.TryGetValue("ClaimID", out var claimIdCol);

        for (var row = 2; row <= lastRow; row++)
        {
            var xlRow = sheet.Row(row);
            if (xlRow.IsEmpty()) continue;   // the worker skips blank rows too
            var anyValue = false;
            foreach (var (_, col) in found)
            {
                if (!sheet.Cell(row, col).IsEmpty()) { anyValue = true; break; }
            }
            if (!anyValue) continue;
            summary.Rows++;

            foreach (var column in schema.Columns)
            {
                if (!found.TryGetValue(column.Name, out var col)) continue;
                var cell = sheet.Cell(row, col);
                if (cell.IsEmpty() || cell.GetFormattedString().Trim().Length == 0)
                {
                    if (column.Required) Note(blanks, column.Name, row);
                    continue;
                }
                if (!ValueFits(cell, column.DataType)) Note(badValues, column.Name, row);
            }

            if (claimIdCol > 0)
            {
                var id = sheet.Cell(row, claimIdCol).GetFormattedString().Trim();
                if (id.Length > 0 && !summary.ClaimIds.Add(id) && schema == ClaimSchema)
                    duplicateClaimRows.Add(row);
            }
        }

        if (summary.Rows == 0)
            result.Errors.Add($"\"{schema.SheetName}\" has no data rows.");

        foreach (var (name, rows) in blanks)
            result.Errors.Add($"\"{schema.SheetName}\": required column \"{name}\" is empty on {rows.Count:N0} row(s) ({RowList(rows)}).");
        foreach (var (name, rows) in badValues)
        {
            var type = schema.Columns.First(c => c.Name == name).DataType;
            result.Errors.Add($"\"{schema.SheetName}\": \"{name}\" is not a valid {TypeLabel(type).ToLowerInvariant()} on {rows.Count:N0} row(s) ({RowList(rows)}).");
        }
        if (duplicateClaimRows.Count > 0)
            result.Warnings.Add($"\"{schema.SheetName}\": {duplicateClaimRows.Count:N0} row(s) repeat a ClaimID already on the sheet ({RowList(duplicateClaimRows)}). The Claim Level sheet should have one row per claim.");

        return summary;
    }

    private static void Note(Dictionary<string, List<int>> map, string column, int row)
    {
        if (!map.TryGetValue(column, out var rows)) map[column] = rows = new();
        rows.Add(row);
    }

    private static string RowList(List<int> rows) =>
        (rows.Count == 1 ? "row " : "rows ") + string.Join(", ", rows.Take(MaxIssuesPerKind)) + (rows.Count > MaxIssuesPerKind ? ", ..." : "");

    private static readonly string[] DateFormats =
        ["M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "yyyy-MM-dd", "M-d-yyyy", "MM-dd-yyyy", "yyyyMMdd", "M/d/yyyy H:mm", "M/d/yyyy h:mm:ss tt", "yyyy-MM-ddTHH:mm:ss"];

    private static bool ValueFits(IXLCell cell, string? dataType)
    {
        switch (dataType)
        {
            case "date":
                if (cell.DataType == XLDataType.DateTime) return true;
                if (cell.DataType == XLDataType.Number) return cell.GetDouble() is > 1 and < 2958465;   // an Excel serial date
                return DateTime.TryParseExact(cell.GetFormattedString().Trim(), DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out _);
            case "decimal":
            case "integer":
                if (cell.DataType == XLDataType.Number) return dataType == "decimal" || Math.Abs(cell.GetDouble() % 1) < 1e-9;
                var text = Regex.Replace(cell.GetFormattedString().Trim(), @"[\$,\s]", "");
                if (text.StartsWith('(') && text.EndsWith(')')) text = "-" + text[1..^1];   // accounting negative
                return dataType == "decimal"
                    ? decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out _)
                    : long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out _);
            default:
                return true;
        }
    }

    /// <summary>Same comparison as the worker's schema validator: letters and digits, case-insensitive.</summary>
    private static string Key(string? text) =>
        new string((text ?? string.Empty).Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();
}

internal sealed class TemplateSchema
{
    public string SchemaName { get; set; } = string.Empty;
    public string? TemplateVersion { get; set; }
    public string SheetName { get; set; } = string.Empty;
    public List<TemplateColumn> Columns { get; set; } = [];
}

internal sealed class TemplateColumn
{
    public string Name { get; set; } = string.Empty;
    public bool Required { get; set; }
    public string DataType { get; set; } = "string";
    public string? Description { get; set; }
}

public sealed class MasterFileValidationResult
{
    public bool Valid => Errors.Count == 0;
    public string? TemplateVersion { get; set; }
    public int ClaimRows { get; set; }
    public int LineRows { get; set; }
    public List<string> Errors { get; } = [];
    public List<string> Warnings { get; } = [];
}
