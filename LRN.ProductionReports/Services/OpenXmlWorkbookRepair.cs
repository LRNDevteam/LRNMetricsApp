using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Spreadsheet;

namespace LRN.ProductionReports.Services;

/// <summary>
/// Excel "We found a problem with some content" after we splice OpenXML raw sheets
/// into a ClosedXML workbook. Typical leftovers: calcChain pointing at deleted sheets,
/// duplicate sheet ids, and defined names for tabs that no longer exist.
/// </summary>
public static class OpenXmlWorkbookRepair
{
    public static uint NextSheetId(Sheets sheets)
    {
        uint max = 0;
        foreach (var sheet in sheets.Elements<Sheet>())
        {
            var id = sheet.SheetId?.Value ?? 0;
            if (id > max) max = id;
        }
        return max + 1;
    }

    public static void StripRepairTriggers(string filePath)
    {
        using var doc = SpreadsheetDocument.Open(filePath, isEditable: true, new OpenSettings { AutoSave = false });
        StripRepairTriggers(doc);
        doc.WorkbookPart?.Workbook.Save();
    }

    public static void StripRepairTriggers(SpreadsheetDocument doc)
    {
        var workbookPart = doc.WorkbookPart;
        if (workbookPart is null) return;

        if (workbookPart.CalculationChainPart is not null)
            workbookPart.DeletePart(workbookPart.CalculationChainPart);

        var names = workbookPart.Workbook.DefinedNames;
        if (names is null) return;

        var sheetNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var sheets = workbookPart.Workbook.GetFirstChild<Sheets>();
        if (sheets is not null)
        {
            foreach (var sheet in sheets.Elements<Sheet>())
            {
                if (sheet.Name?.Value is { Length: > 0 } n)
                    sheetNames.Add(n);
            }
        }

        foreach (var defined in names.Elements<DefinedName>().ToList())
        {
            var formula = defined.Text ?? defined.InnerText ?? "";
            var bang = formula.IndexOf('!');
            if (bang <= 0) continue;
            var sheetRef = formula[..bang].Trim().Trim('\'');
            if (sheetRef.Length > 0 && !sheetNames.Contains(sheetRef))
                defined.Remove();
        }

        if (!names.Elements<DefinedName>().Any())
            names.Remove();
    }
}
