using System.Data;
using System.Globalization;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Spreadsheet;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Excel download of the Executive Summary value popup: the report details (lab, generated time,
/// week range, filters), the calculation rules, then every source row behind the clicked value.
/// Rows are streamed from the data reader with <see cref="OpenXmlWriter"/>, so a Grand Total cell
/// with hundreds of thousands of rows keeps memory flat.
/// </summary>
public static class ExecSummaryCellRowsExcelBuilder
{
    private static readonly HashSet<string> AmountColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "Amount", "ChargeAmount", "InsurancePayment", "PatientPayment", "PatientBalance",
        "TotalAdjustments", "TotalInsuranceBalance", "InsuranceBalance", "ActualPayment", "DuplicatePayment",
        "InsuranceAdjustments", "PatientAdjustments",
    };

    // Cell style indexes of the stylesheet below.
    private const uint StyleBold = 1, StyleHeader = 2, StyleMoney = 3, StyleMoneyBold = 4, StyleCount = 5, StyleCountBold = 6,
        StyleTitle = 7;

    // Zero-based columns of the "How this value is calculated" block (E = rule group, F = rule text).
    private const int RuleLabelCol = 4, RuleTextCol = 5;

    /// <param name="output">Seekable, writable stream (the .xlsx package).</param>
    /// <param name="head">Rules and summary of the cell (Columns / Rows are not used).</param>
    /// <param name="rows">Result set 3 of usp_Get{prefix}_ExecutiveSummaryCellRows, positioned before its first row.</param>
    /// <param name="reportInfo">Label / value lines written under the title (lab, generated time, week range, filters).</param>
    public static void Write(Stream output, ExecSummaryCellRowsResult head, IDataReader rows,
        string labName, string title, string periodLabel, string valueText,
        IReadOnlyList<(string Label, string Value)> reportInfo)
    {
        var moneyIdx = Ordinal(rows, "IsMoney");
        var totalIdx = Ordinal(rows, "IsTotal");
        var cols = Enumerable.Range(0, rows.FieldCount).Where(c => c != moneyIdx && c != totalIdx).ToList();
        var lastCol = Math.Max(cols.Count, RuleTextCol + 1);

        // Top block: title (A1:B1) over the report details in A:B, and the rules beside them in E:F.
        var titleText = $"{labName} - Executive Summary - {title} - {periodLabel}";
        var blockRows = 1 + Math.Max(reportInfo.Count, head.Rules.Count);
        var gridLine = head.IsFormula
            ? $"Grid value: {valueText}    Result: {head.TotalAmount:N2}"
            : $"Grid value: {valueText}    Rows found: {head.TotalRows:N0}"
              + (head.AmountColumn is null ? string.Empty : $"    {head.Measure}: {head.TotalAmount:N2}");
        var gridRow = (uint)blockRows + 2;
        var headerRow = gridRow + 2;

        // The merged title has to fit in A:B.
        var colAWidth = Math.Max(18d, reportInfo.Select(i => i.Label.Length + 2d).DefaultIfEmpty(0).Max());
        var colBWidth = Math.Max(18d, titleText.Length * 1.15 - colAWidth + 2);

        using var doc = SpreadsheetDocument.Create(output, SpreadsheetDocumentType.Workbook);
        var wbPart = doc.AddWorkbookPart();
        wbPart.Workbook = new Workbook();
        var styles = wbPart.AddNewPart<WorkbookStylesPart>();
        styles.Stylesheet = BuildStylesheet();
        styles.Stylesheet.Save();
        var wsPart = wbPart.AddNewPart<WorksheetPart>();

        uint lastRow = headerRow;
        using (var w = OpenXmlWriter.Create(wsPart))
        {
            w.WriteStartElement(new Worksheet());

            w.WriteStartElement(new SheetViews());
            w.WriteStartElement(new SheetView { WorkbookViewId = 0 });
            if (!head.IsFormula)
                w.WriteElement(new Pane
                {
                    VerticalSplit = headerRow, TopLeftCell = $"A{headerRow + 1}",
                    ActivePane = PaneValues.BottomLeft, State = PaneStateValues.Frozen,
                });
            w.WriteEndElement();
            w.WriteEndElement();

            w.WriteStartElement(new Columns());
            for (var c = 1; c <= lastCol; c++)
            {
                var width = c switch { 1 => colAWidth, 2 => colBWidth, RuleLabelCol + 1 => 16, _ => 18 };
                w.WriteElement(new Column { Min = (uint)c, Max = (uint)c, Width = width, CustomWidth = true });
            }
            w.WriteEndElement();

            w.WriteStartElement(new SheetData());
            for (var i = 0; i < blockRows; i++)
            {
                var r = (uint)i + 1;
                w.WriteStartElement(new Row { RowIndex = r });
                if (i == 0)
                {
                    WriteText(w, $"A{r}", titleText, StyleTitle);
                    WriteText(w, $"B{r}", string.Empty, StyleTitle);
                    WriteText(w, Ref(RuleLabelCol, r), "How this value is calculated", StyleBold);
                }
                else
                {
                    if (i - 1 < reportInfo.Count)
                    {
                        WriteText(w, $"A{r}", reportInfo[i - 1].Label, StyleBold);
                        WriteText(w, $"B{r}", reportInfo[i - 1].Value, 0);
                    }
                    if (i - 1 < head.Rules.Count)
                    {
                        WriteText(w, Ref(RuleLabelCol, r), head.Rules[i - 1].Group, StyleBold);
                        WriteText(w, Ref(RuleTextCol, r), head.Rules[i - 1].Text, 0);
                    }
                }
                w.WriteEndElement();
            }

            w.WriteStartElement(new Row { RowIndex = gridRow });
            WriteText(w, $"A{gridRow}", gridLine, 0);
            w.WriteEndElement();

            w.WriteStartElement(new Row { RowIndex = headerRow });
            for (var k = 0; k < cols.Count; k++)
                WriteText(w, Ref(k, headerRow), rows.GetName(cols[k]), StyleHeader);
            w.WriteEndElement();

            var dataRow = headerRow + 1;
            while (rows.Read())
            {
                var rowIsMoney = moneyIdx >= 0 && !rows.IsDBNull(moneyIdx) && Convert.ToBoolean(rows.GetValue(moneyIdx));
                var rowIsTotal = totalIdx >= 0 && !rows.IsDBNull(totalIdx) && Convert.ToBoolean(rows.GetValue(totalIdx));
                w.WriteStartElement(new Row { RowIndex = dataRow });
                for (var k = 0; k < cols.Count; k++)
                {
                    var c = cols[k];
                    if (rows.IsDBNull(c)) continue;
                    var v = rows.GetValue(c);
                    var cellRef = Ref(k, dataRow);
                    switch (v)
                    {
                        case decimal or double or float or int or long or short or byte:
                            var money = AmountColumns.Contains(rows.GetName(c)) || rowIsMoney;
                            var style = money
                                ? (rowIsTotal ? StyleMoneyBold : StyleMoney)
                                : head.IsFormula ? (rowIsTotal ? StyleCountBold : StyleCount)
                                : rowIsTotal ? StyleBold : 0u;
                            WriteNumber(w, cellRef, Convert.ToDecimal(v, CultureInfo.InvariantCulture), style);
                            break;
                        case DateTime d:
                            WriteText(w, cellRef, d.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture), rowIsTotal ? StyleBold : 0);
                            break;
                        default:
                            WriteText(w, cellRef, Convert.ToString(v, CultureInfo.InvariantCulture) ?? string.Empty, rowIsTotal ? StyleBold : 0);
                            break;
                    }
                }
                w.WriteEndElement();
                dataRow++;
            }
            lastRow = dataRow - 1;
            w.WriteEndElement(); // SheetData

            if (!head.IsFormula && cols.Count > 0)
                w.WriteElement(new AutoFilter { Reference = $"A{headerRow}:{Ref(cols.Count - 1, Math.Max(headerRow, lastRow))}" });

            w.WriteElement(new MergeCells(new MergeCell { Reference = "A1:B1" }) { Count = 1 });

            // IDs such as VisitNumber / Accession are text on purpose (leading zeros); hide Excel's green triangles.
            if (cols.Count > 0 && lastRow > headerRow)
                w.WriteElement(new IgnoredErrors(new IgnoredError
                {
                    SequenceOfReferences = new ListValue<StringValue> { InnerText = $"A{headerRow + 1}:{Ref(cols.Count - 1, lastRow)}" },
                    NumberStoredAsText = true,
                }));

            w.WriteEndElement(); // Worksheet
        }

        var sheets = wbPart.Workbook.AppendChild(new Sheets());
        sheets.Append(new Sheet { Id = wbPart.GetIdOfPart(wsPart), SheetId = 1, Name = "Rows" });
        if (!head.IsFormula && cols.Count > 0)
            wbPart.Workbook.Append(new DefinedNames(new DefinedName($"'Rows'!$A${headerRow}:${ColName(cols.Count - 1)}${Math.Max(headerRow, lastRow)}")
            {
                Name = "_xlnm._FilterDatabase", LocalSheetId = 0, Hidden = true,
            }));
        wbPart.Workbook.Save();
    }

    private static int Ordinal(IDataReader r, string name)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }

    private static string ColName(int index)
    {
        var s = string.Empty;
        for (var n = index + 1; n > 0; n = (n - 1) / 26)
            s = (char)('A' + (n - 1) % 26) + s;
        return s;
    }

    private static string Ref(int colIndex, uint row) => ColName(colIndex) + row.ToString(CultureInfo.InvariantCulture);

    private static void WriteText(OpenXmlWriter w, string cellRef, string text, uint style)
    {
        var cell = new Cell { CellReference = cellRef, DataType = CellValues.InlineString };
        if (style != 0) cell.StyleIndex = style;
        w.WriteStartElement(cell);
        w.WriteStartElement(new InlineString());
        w.WriteElement(new Text(text) { Space = SpaceProcessingModeValues.Preserve });
        w.WriteEndElement();
        w.WriteEndElement();
    }

    private static void WriteNumber(OpenXmlWriter w, string cellRef, decimal value, uint style)
    {
        var cell = new Cell { CellReference = cellRef };
        if (style != 0) cell.StyleIndex = style;
        w.WriteStartElement(cell);
        w.WriteElement(new CellValue(value.ToString(CultureInfo.InvariantCulture)));
        w.WriteEndElement();
    }

    private static Stylesheet BuildStylesheet() => new(
        new NumberingFormats(
            new NumberingFormat { NumberFormatId = 164, FormatCode = @"_(""$""* #,##0.00_);_(""$""* \(#,##0.00\);_(""$""* ""-""??_);_(@_)" },
            new NumberingFormat { NumberFormatId = 165, FormatCode = @"#,##0;-#,##0;""-"";@" })
        { Count = 2 },
        new Fonts(
            new Font(new FontSize { Val = 11 }, new FontName { Val = "Calibri" }),
            new Font(new Bold(), new FontSize { Val = 11 }, new FontName { Val = "Calibri" }),
            new Font(new Bold(), new FontSize { Val = 11 }, new Color { Rgb = "FFFFFFFF" }, new FontName { Val = "Calibri" }))
        { Count = 3 },
        new Fills(
            new Fill(new PatternFill { PatternType = PatternValues.None }),
            new Fill(new PatternFill { PatternType = PatternValues.Gray125 }),
            new Fill(new PatternFill(new ForegroundColor { Rgb = "FF385624" }) { PatternType = PatternValues.Solid }))
        { Count = 3 },
        new Borders(new Border()) { Count = 1 },
        new CellStyleFormats(new CellFormat()) { Count = 1 },
        new CellFormats(
            new CellFormat(),                                                                   // 0 default
            new CellFormat { FontId = 1, ApplyFont = true },                                    // 1 bold
            new CellFormat { FontId = 2, FillId = 2, ApplyFont = true, ApplyFill = true },      // 2 header
            new CellFormat { NumberFormatId = 164, ApplyNumberFormat = true },                  // 3 money
            new CellFormat { NumberFormatId = 164, FontId = 1, ApplyNumberFormat = true, ApplyFont = true }, // 4 money bold
            new CellFormat { NumberFormatId = 165, ApplyNumberFormat = true },                  // 5 count
            new CellFormat { NumberFormatId = 165, FontId = 1, ApplyNumberFormat = true, ApplyFont = true }, // 6 count bold
            new CellFormat(new Alignment { Horizontal = HorizontalAlignmentValues.Center })
                { FontId = 2, FillId = 2, ApplyFont = true, ApplyFill = true, ApplyAlignment = true }) // 7 title
        { Count = 8 },
        new CellStyles(new CellStyle { Name = "Normal", FormatId = 0, BuiltinId = 0 }) { Count = 1 });
}
