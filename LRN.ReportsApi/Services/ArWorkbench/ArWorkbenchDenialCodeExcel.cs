using ClosedXML.Excel;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// The AR Workbench Denial Code Master workbook: the downloadable template, the export, and the
/// import parser share one layout - title in row 1, headers in row 2, data from row 3 - as the
/// Denial Workflow's Denial Code Master workbook does (DenialCodeMasterExcelService). The export is
/// a valid import file, so download - edit - upload round-trips.
/// </summary>
internal static class ArWorkbenchDenialCodeExcel
{
    public const string SheetName = "Denial Code Master";
    private const string CategoriesSheetName = "Denial Categories";
    private const string TitleText = "AR WORKBENCH - DENIAL CODE MASTER";
    private const int FirstDataRow = 3;
    private const int ValidationRows = 5000;

    // Columns 1-4 are imported; anything after them is information only and ignored on import.
    private static readonly string[] ImportHeaders = ["Denial Code", "Denial Category", "Denial Reason", "Active"];
    private static readonly string[] ExportOnlyHeaders = ["Claims (primary denial)", "Denial Workflow Description", "Last Changed (UTC)", "Last Changed By"];

    public static byte[] BuildTemplate(IReadOnlyList<string> categories)
    {
        using var workbook = new XLWorkbook();
        var sheet = AddSheet(workbook, ImportHeaders);

        // One illustrative row so users see the expected shape; ImportDenialCodes reads from row 3.
        string[] sample = ["CO-16", categories.FirstOrDefault() ?? "Other", "Claim lacks information needed for adjudication (sample row - replace or delete)", "Yes"];
        for (var i = 0; i < sample.Length; i++) sheet.Cell(FirstDataRow, i + 1).Value = sample[i];

        AddCategoryList(workbook, sheet, categories);
        Finish(sheet);
        return Save(workbook);
    }

    public static byte[] BuildExport(IReadOnlyList<ArWorkbenchDenialCodeRow> rows, IReadOnlyList<string> categories)
    {
        using var workbook = new XLWorkbook();
        var sheet = AddSheet(workbook, [.. ImportHeaders, .. ExportOnlyHeaders]);

        var row = FirstDataRow;
        foreach (var r in rows)
        {
            sheet.Cell(row, 1).Value = r.DenialCode;
            sheet.Cell(row, 2).Value = r.DenialCategory;
            sheet.Cell(row, 3).Value = r.DenialReason;
            sheet.Cell(row, 4).Value = r.IsActive ? "Yes" : "No";
            sheet.Cell(row, 5).Value = r.ClaimCount;
            sheet.Cell(row, 6).Value = r.WorkflowDescription;
            if ((r.UpdatedOn ?? r.CreatedOn) is { } changed) sheet.Cell(row, 7).Value = changed;
            sheet.Cell(row, 8).Value = r.UpdatedBy ?? r.CreatedBy;
            row++;
        }
        // Codes are text: "016" must not become 16 when the file is edited and re-imported.
        sheet.Range(FirstDataRow, 1, Math.Max(row, FirstDataRow + ValidationRows), 1).Style.NumberFormat.Format = "@";
        sheet.Column(7).Style.DateFormat.Format = "yyyy-mm-dd hh:mm";
        for (var c = ImportHeaders.Length + 1; c <= ImportHeaders.Length + ExportOnlyHeaders.Length; c++)
            sheet.Cell(2, c).Style.Fill.BackgroundColor = DenialExcelTheme.SubHeaderBg;

        AddCategoryList(workbook, sheet, categories);
        Finish(sheet);
        return Save(workbook);
    }

    /// <summary>Reads the workbook's data rows as text. Error is set when the file is not this workbook.</summary>
    public static (List<ArWorkbenchDenialCodeImportRow> Rows, int Skipped, string? Error) Parse(Stream stream)
    {
        XLWorkbook workbook;
        try { workbook = new XLWorkbook(stream); }
        catch (Exception) { return ([], 0, "The file could not be read as an Excel workbook (.xlsx)."); }

        using (workbook)
        {
            if (!workbook.TryGetWorksheet(SheetName, out var sheet))
                return ([], 0, $"Worksheet '{SheetName}' was not found. Start from Download Template or Export Excel.");

            for (var i = 0; i < ImportHeaders.Length; i++)
            {
                if (!string.Equals(Text(sheet.Cell(2, i + 1)), ImportHeaders[i], StringComparison.OrdinalIgnoreCase))
                    return ([], 0, $"Row 2 must hold the headers {string.Join(", ", ImportHeaders)} in that order. Start from Download Template or Export Excel.");
            }

            var rows = new List<ArWorkbenchDenialCodeImportRow>();
            var skipped = 0;
            var lastRow = sheet.LastRowUsed()?.RowNumber() ?? 0;
            for (var row = FirstDataRow; row <= lastRow; row++)
            {
                var code = Text(sheet.Cell(row, 1));
                if (code is null)
                {
                    skipped++;
                    continue;
                }
                rows.Add(new ArWorkbenchDenialCodeImportRow(row, code, Text(sheet.Cell(row, 2)), Text(sheet.Cell(row, 3)), Text(sheet.Cell(row, 4))));
            }
            return (rows, skipped, null);
        }
    }

    private static IXLWorksheet AddSheet(XLWorkbook workbook, IReadOnlyList<string> headers)
    {
        var sheet = workbook.Worksheets.Add(SheetName);
        DenialExcelTheme.ApplyDefaults(sheet);
        sheet.TabColor = DenialExcelTheme.TabGreen;

        sheet.Cell(1, 1).Value = TitleText;
        var title = sheet.Range(1, 1, 1, headers.Count).Merge();
        title.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Font.SetFontSize(DenialExcelTheme.FontSizeTitle);
        title.Style.Fill.SetBackgroundColor(DenialExcelTheme.TitleBg);
        title.Style.Alignment.SetVertical(XLAlignmentVerticalValues.Center);

        for (var i = 0; i < headers.Count; i++)
            DenialExcelTheme.StyleHeaderCell(sheet.Cell(2, i + 1).SetValue(headers[i]));

        sheet.Range(FirstDataRow, 1, FirstDataRow + ValidationRows, 1).Style.NumberFormat.Format = "@";
        return sheet;
    }

    /// <summary>The active Denial Categories on their own sheet, and a dropdown on the category column.</summary>
    private static void AddCategoryList(XLWorkbook workbook, IXLWorksheet sheet, IReadOnlyList<string> categories)
    {
        var list = workbook.Worksheets.Add(CategoriesSheetName);
        DenialExcelTheme.ApplyDefaults(list);
        list.TabColor = DenialExcelTheme.TabGold;
        DenialExcelTheme.StyleHeaderCell(list.Cell(1, 1).SetValue("Active Denial Categories"));
        for (var i = 0; i < categories.Count; i++) list.Cell(i + 2, 1).Value = categories[i];
        DenialExcelTheme.StyleHeaderCell(list.Cell(1, 3).SetValue("Active"));
        list.Cell(2, 3).Value = "Yes";
        list.Cell(3, 3).Value = "No";
        list.Columns().AdjustToContents();

        var yesNo = sheet.Range(FirstDataRow, 4, FirstDataRow + ValidationRows, 4).CreateDataValidation();
        yesNo.List(list.Range(2, 3, 3, 3), true);

        if (categories.Count == 0) return;
        var validation = sheet.Range(FirstDataRow, 2, FirstDataRow + ValidationRows, 2).CreateDataValidation();
        validation.List(list.Range(2, 1, categories.Count + 1, 1), true);
        validation.ErrorTitle = "Denial Category";
        validation.ErrorMessage = "Choose a category from the Denial Categories sheet.";
    }

    private static void Finish(IXLWorksheet sheet)
    {
        sheet.SheetView.FreezeRows(2);
        sheet.Columns().AdjustToContents(2, 200);
        sheet.Column(3).Width = Math.Min(Math.Max(sheet.Column(3).Width, 30), 80);
    }

    private static byte[] Save(XLWorkbook workbook)
    {
        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static string? Text(IXLCell cell)
    {
        var value = cell.GetFormattedString().Trim();
        return value.Length == 0 ? null : value;
    }
}
