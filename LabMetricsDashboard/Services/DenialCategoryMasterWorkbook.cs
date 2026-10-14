using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads docs/Denial_Codes_And_Categorization_Master.xlsx:
///   "Denial Category Clasification" - Denial Code, Denial Code Description, Denial Categorization
///   "Non-collectible Denials"       - Denial Code, Denial Code Description
/// Sheets are found by name (the categorization sheet by "categor", the other by "collectible"),
/// columns by header text, so a reordered or renamed-but-recognisable workbook still imports.
/// Codes are trimmed ("B7 " and "B7" are one code); a code seen again further down keeps its
/// first row and is reported as a duplicate.
/// </summary>
public static class DenialCategoryMasterWorkbook
{
    private static readonly string[] CodeHeaders = ["Denial Code", "DenialCode", "Code"];
    private static readonly string[] DescriptionHeaders = ["Denial Code Description", "Description", "Denial Description"];
    private static readonly string[] CategoryHeaders = ["Denial Categorization", "Denial Category", "Action Category", "Category"];

    public static DenialCategoryWorkbookImport Read(Stream stream)
    {
        using var workbook = new XLWorkbook(stream);

        var nonCollectibleSheet = workbook.Worksheets.FirstOrDefault(s => Key(s.Name).Contains("COLLECTIBLE"));
        var categorySheet = workbook.Worksheets.FirstOrDefault(s => s != nonCollectibleSheet && Key(s.Name).Contains("CATEGOR"));

        var categories = categorySheet is null ? new DenialSheetImport() : ReadSheet(categorySheet, withCategory: true);
        var nonCollectible = nonCollectibleSheet is null ? new DenialSheetImport() : ReadSheet(nonCollectibleSheet, withCategory: false);

        string? error = null;
        if (categorySheet is null && nonCollectibleSheet is null)
            error = "The workbook has neither a denial categorization sheet nor a 'Non-collectible Denials' sheet.";
        else if (categories.Rows is null && nonCollectible.Rows is null)
            error = "No 'Denial Code' column was found on the denial sheets.";

        return new DenialCategoryWorkbookImport { Categories = categories, NonCollectible = nonCollectible, Error = error };
    }

    private static DenialSheetImport ReadSheet(IXLWorksheet sheet, bool withCategory)
    {
        var used = sheet.RangeUsed();
        if (used is null) return new DenialSheetImport { SheetName = sheet.Name, Rows = new() };

        // Header: the first of the top ten rows that names a Denial Code column.
        IXLRangeRow? header = null;
        int codeCol = 0, descCol = 0, catCol = 0;
        foreach (var row in used.Rows().Take(10))
        {
            codeCol = FindColumn(row, CodeHeaders);
            if (codeCol == 0) continue;
            header = row;
            descCol = FindColumn(row, DescriptionHeaders);
            catCol = withCategory ? FindColumn(row, CategoryHeaders) : 0;
            break;
        }

        if (header is null) return new DenialSheetImport { SheetName = sheet.Name };

        var rows = new List<DenialCodeImportRow>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var duplicates = new List<string>();
        var blank = 0;
        var headerRow = header.RowNumber();

        foreach (var row in used.Rows().Where(r => r.RowNumber() > headerRow))
        {
            var code = Text(row, codeCol);
            var description = Text(row, descCol);
            var category = Text(row, catCol);

            if (code is null)
            {
                if (description is not null || category is not null) blank++;
                continue;
            }

            if (!seen.Add(code))
            {
                duplicates.Add(code);
                continue;
            }

            rows.Add(new DenialCodeImportRow(code, description, category));
        }

        return new DenialSheetImport { SheetName = sheet.Name, Rows = rows, Duplicates = duplicates, BlankCodeRows = blank };
    }

    private static int FindColumn(IXLRangeRow row, string[] names)
    {
        foreach (var name in names)
        {
            var cell = row.Cells().FirstOrDefault(c => Key(c.GetString()) == Key(name));
            if (cell is not null) return cell.Address.ColumnNumber - row.RangeAddress.FirstAddress.ColumnNumber + 1;
        }
        return 0;
    }

    private static string? Text(IXLRangeRow row, int column)
    {
        if (column <= 0) return null;
        var value = row.Cell(column).GetFormattedString()?.Trim();
        return string.IsNullOrEmpty(value) ? null : value;
    }

    private static string Key(string value)
        => new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
}
