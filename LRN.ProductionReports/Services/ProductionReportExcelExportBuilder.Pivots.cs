using System.Globalization;
using ClosedXML.Excel;
using LRN.ProductionReports.Models;

namespace LRN.ProductionReports.Services;

/// <summary>
/// Native Excel PivotTables matching the Cove Production Report client workbook:
/// CPT Breakdown, Payor Breakdown, Payor x Panel, Panel Breakdown, plus a
/// Production Summary pivot (Panel × top insurances × year/month).
/// Source tables are written as compact sheets (Master / Data 1); Excel refreshes
/// the pivot cache on open.
/// </summary>
public static partial class ProductionReportExcelExportBuilder
{
    private const int PivotTitleColumns = 36;
    private const double PivotRowLabelWidth = 42;
    private const double PivotValueColumnWidth = 16;

    /// <summary>
    /// Client asked to drop native PivotTables — formatting/styles were incomplete on open.
    /// Keep false so Build*Sheet paths write the fully formatted ClosedXML grids instead.
    /// </summary>
    private const bool UseNativePivots = false;

    internal static bool TryBuildProductionSummaryPivot(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (!UseNativePivots) return false;
        var rows = FlattenProductionSummary(vm);
        if (rows.Count == 0) return false;

        var source = WritePivotSource(wb, "Prod Summary Source", ExcelTheme.TabBlue, rows,
            "Panel", "Payer", "Year", "Month", "NoOfClaims", "TotalBilled");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Production Summary");
        ws.TabColor = ExcelTheme.TabRed;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.WriteTitleBar(ws, 1, PivotTitleColumns, "Production | Date of Entry", ExcelTheme.InsightsHeaderBg);

        var pt = AddPivot(ws, "ProductionSummaryPivot", ws.Cell(3, 1), source,
            "Panel", "Production Summary");
        pt.RowLabels.Add("Panel");
        pt.RowLabels.Add("Payer");
        pt.ColumnLabels.Add("Year");
        pt.ColumnLabels.Add("Month");
        AddSumValue(pt, "NoOfClaims", "No of Claims");
        AddSumValue(pt, "TotalBilled", "Total Billed", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildCptBreakdownPivot(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (!UseNativePivots) return false;
        var rows = FlattenCpt(vm);
        if (rows.Count == 0) return false;

        var source = WritePivotSource(wb, "Data 1", ExcelTheme.TabBlue, rows,
            "CPT", "Year", "Month", "CountOfCpt", "TotalCharge");

        var ws = wb.AddWorksheet("CPT Breakdown");
        ws.TabColor = ExcelTheme.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.WriteTitleBar(ws, 1, PivotTitleColumns, "CPT Breakdown", ExcelTheme.InsightsHeaderBg);

        var pt = AddPivot(ws, "CptPivot", ws.Cell(3, 1), source,
            "CPTs", "CPT Breakdown");
        pt.RowLabels.Add("CPT");
        pt.ColumnLabels.Add("Year");
        pt.ColumnLabels.Add("Month");
        AddSumValue(pt, "CountOfCpt", "Count of CPT");
        AddSumValue(pt, "TotalCharge", "TotalCharge", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildPayerBreakdownPivot(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (!UseNativePivots) return false;
        var rows = FlattenPayerMonth(vm.PayerBreakdownRows);
        if (rows.Count == 0) return false;

        var source = WritePivotSource(wb, "Payor Source", ExcelTheme.TabBlue, rows,
            "Payer", "Year", "Month", "NoOfClaims", "TotalCharges");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Payer Breakdown");
        ws.TabColor = ExcelTheme.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.WriteTitleBar(ws, 1, PivotTitleColumns, "Payor Breakdown", ExcelTheme.InsightsHeaderBg);

        var pt = AddPivot(ws, "PayorPivot", ws.Cell(3, 1), source,
            "Payer", "Payor Breakdown");
        pt.RowLabels.Add("Payer");
        pt.ColumnLabels.Add("Year");
        pt.ColumnLabels.Add("Month");
        AddSumValue(pt, "NoOfClaims", "No of Claims");
        AddSumValue(pt, "TotalCharges", "TotalCharges", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildPayerPanelPivot(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (!UseNativePivots) return false;
        var rows = FlattenPayerPanel(vm);
        if (rows.Count == 0) return false;

        var source = WritePivotSource(wb, "PayorPanel Source", ExcelTheme.TabBlue, rows,
            "Payer", "Panel", "NoOfClaims", "TotalCharges");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Payor x Panel");
        ws.TabColor = ExcelTheme.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.WriteTitleBar(ws, 1, PivotTitleColumns, "Payor x Panel", ExcelTheme.InsightsHeaderBg);

        var pt = AddPivot(ws, "PayorPanelPivot", ws.Cell(3, 1), source,
            "Payer", "Payor x Panel");
        pt.RowLabels.Add("Payer");
        pt.ColumnLabels.Add("Panel");
        AddSumValue(pt, "NoOfClaims", "No of Claims");
        AddSumValue(pt, "TotalCharges", "TotalCharges", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildPanelBreakdownPivot(XLWorkbook wb, ProductionReportViewModel vm)
    {
        if (!UseNativePivots) return false;
        var rows = FlattenPanelMonth(vm.PanelBreakdownRows);
        if (rows.Count == 0) return false;

        var source = WritePivotSource(wb, "Master", ExcelTheme.TabGold, rows,
            "Panel", "Year", "Month", "NoOfClaims", "TotalCharge");

        var ws = wb.AddWorksheet("Panel Breakdown");
        ws.TabColor = ExcelTheme.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        var panelTitle = vm.SelectedLab.Contains("Cove", StringComparison.OrdinalIgnoreCase)
            ? "Panel Breakdown (First Billed Date)"
            : "Panel Breakdown";
        ExcelTheme.WriteTitleBar(ws, 1, PivotTitleColumns, panelTitle, ExcelTheme.InsightsHeaderBg);

        var pt = AddPivot(ws, "PanelPivot", ws.Cell(3, 1), source,
            "Panel Name", "Panel Breakdown");
        pt.RowLabels.Add("Panel");
        pt.ColumnLabels.Add("Year");
        pt.ColumnLabels.Add("Month");
        AddSumValue(pt, "NoOfClaims", "No of Claims");
        AddSumValue(pt, "TotalCharge", "TotalCharge", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    private static IXLPivotTable AddPivot(
        IXLWorksheet ws, string name, IXLCell target, IXLRange source,
        string rowCaption, string columnCaption)
    {
        var pt = ws.PivotTables.Add(name, target, source);
        // Medium21 + explicit #385624 on row/column headers, Values, and corner.
        pt.Theme = XLPivotTableTheme.PivotStyleMedium21;
        pt.ShowRowStripes = false;
        pt.ShowColumnStripes = false;
        pt.ShowRowHeaders = true;
        pt.ShowColumnHeaders = true;
        pt.ShowValuesRow = false;
        pt.ShowGrandTotalsRows = true;
        pt.ShowGrandTotalsColumns = true;
        pt.Layout = XLPivotLayout.Outline;
        pt.RowLabelIndent = 0;
        pt.AutofitColumns = false;
        pt.DisplayCaptionsAndDropdowns = true;
        pt.RowHeaderCaption = rowCaption;
        pt.ColumnHeaderCaption = columnCaption;
        if (pt.PivotCache is not null)
            pt.PivotCache.RefreshDataOnOpen = true;
        return pt;
    }

    private static void ApplyCovePivotStyle(IXLPivotTable pt)
    {
        ApplyClientHeaderColors(pt);
        FinishPivotLayout(pt);
    }

    private static void ApplyClientHeaderColors(IXLPivotTable pt)
    {
        foreach (var field in pt.RowLabels)
            PaintPivotHeader(field.StyleFormats.Header.Style);

        // Includes the synthetic Values field. That emits field="4294967294",
        // a legal UInt32, which OpenXmlPivotCacheFix then recolours so the
        // Values button is white and the metric captions are mint.
        foreach (var field in pt.ColumnLabels)
        {
            PaintPivotHeader(field.StyleFormats.Header.Style);
            PaintPivotHeader(field.StyleFormats.Label.Style);
        }
    }

    private static void PaintPivotHeader(IXLStyle style)
    {
        style.Font.FontName = ExcelTheme.FontName;
        style.Font.FontSize = ExcelTheme.FontSizeBody;
        style.Font.Bold = true;
        style.Font.FontColor = XLColor.White;
        style.Fill.BackgroundColor = ExcelTheme.InsightsHeaderBg;
        style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
    }

    private static void FinishPivotLayout(IXLPivotTable pt)
    {
        var ws = pt.Worksheet;
        ws.Column(1).Width = PivotRowLabelWidth;
        for (var c = 2; c <= PivotTitleColumns; c++)
            ws.Column(c).Width = PivotValueColumnWidth;
        // Do not materialize empty rows over the pivot target. ClosedXML does not
        // write pivot values into cells; Excel paints them on open. Empty row
        // records at A3:A5 make Excel treat the pivot as having no body.
    }

    private static void AddSumValue(IXLPivotTable pt, string field, string caption, bool currency = false)
    {
        var value = pt.Values.Add(field).SetSummaryFormula(XLPivotSummary.Sum);
        value.CustomName = caption;
        if (currency)
            value.NumberFormat.Format = ExcelTheme.AccountingNumberFormat2;
        else
            value.NumberFormat.Format = ExcelTheme.CountNumberFormat;
    }

    private static IXLRange WritePivotSource(
        XLWorkbook wb, string sheetName, XLColor tab, IReadOnlyList<object?[]> rows, params string[] headers)
    {
        var ws = wb.Worksheets.FirstOrDefault(s => s.Name.Equals(sheetName, StringComparison.OrdinalIgnoreCase))
                 ?? wb.AddWorksheet(sheetName);
        ws.TabColor = tab;
        ExcelTheme.ApplyDefaults(ws);
        for (var c = 0; c < headers.Length; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = headers[c];
            cell.Style.Font.Bold = true;
        }

        for (var r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            for (var c = 0; c < headers.Length && c < row.Length; c++)
                WriteSourceCell(ws.Cell(r + 2, c + 1), row[c]);
        }

        var lastRow = Math.Max(2, rows.Count + 1);
        var range = ws.Range(1, 1, lastRow, headers.Length);
        var tableName = new string(sheetName.Where(char.IsLetterOrDigit).ToArray());
        if (string.IsNullOrWhiteSpace(tableName)) tableName = "PivotSource";
        if (tableName.Length > 0 && char.IsDigit(tableName[0])) tableName = "T" + tableName;
        if (ws.Tables.All(t => !t.Name.Equals(tableName, StringComparison.OrdinalIgnoreCase)))
            range.CreateTable(tableName);
        ws.SheetView.FreezeRows(1);
        return range;
    }

    private static void WriteSourceCell(IXLCell cell, object? value)
    {
        switch (value)
        {
            case null:
                break;
            case int i:
                cell.Value = i;
                break;
            case long l:
                cell.Value = l;
                break;
            case decimal d:
                cell.Value = d;
                break;
            case double db:
                cell.Value = db;
                break;
            default:
                cell.Value = value.ToString();
                break;
        }
    }

    private static List<object?[]> FlattenProductionSummary(ProductionReportViewModel vm)
    {
        var rows = new List<object?[]>();
        foreach (var panel in vm.PanelRows)
        {
            foreach (var payer in panel.TopPayers)
            {
                foreach (var (mk, cell) in payer.ByMonth)
                {
                    if (!TrySplitMonth(mk, out var year, out var month)) continue;
                    rows.Add([panel.PanelName, payer.PayerName, year, MonthName(month), cell.ClaimCount, cell.BilledCharges]);
                }
            }
        }
        return rows;
    }

    private static List<object?[]> FlattenCpt(ProductionReportViewModel vm)
    {
        var rows = new List<object?[]>();
        foreach (var cpt in EnumerateCptLeaves(vm.CptBreakdownRows))
        {
            foreach (var (mk, cell) in cpt.ByMonth)
            {
                if (!TrySplitMonth(mk, out var year, out var month)) continue;
                // Count of CPT only — never SUM(Units). ClaimCount is authoritative.
                var count = cell.ClaimCount > 0 ? cell.ClaimCount : (int)Math.Round(cell.Units, MidpointRounding.AwayFromZero);
                rows.Add([cpt.CptCode, year, MonthName(month), count, cell.BilledCharges]);
            }
        }
        return rows;
    }

    private static IEnumerable<CptBreakdownRow> EnumerateCptLeaves(IEnumerable<CptBreakdownRow> rows)
    {
        foreach (var row in rows)
        {
            if (row.ChildRows.Count > 0)
            {
                foreach (var child in EnumerateCptLeaves(row.ChildRows))
                    yield return child;
            }
            else
            {
                yield return row;
            }
        }
    }

    private static List<object?[]> FlattenPayerMonth(IEnumerable<PayerBreakdownRow> payers)
    {
        var rows = new List<object?[]>();
        foreach (var payer in payers)
        {
            if (payer.ChildRows.Count > 0)
            {
                rows.AddRange(FlattenPayerMonth(payer.ChildRows));
                continue;
            }

            foreach (var (mk, claims) in payer.ByMonth)
            {
                if (!TrySplitMonth(mk, out var year, out var month)) continue;
                var charges = payer.ByMonthCharges.GetValueOrDefault(mk);
                rows.Add([payer.PayerName, year, MonthName(month), claims, charges]);
            }
        }
        return rows;
    }

    private static List<object?[]> FlattenPayerPanel(ProductionReportViewModel vm)
    {
        var rows = new List<object?[]>();
        foreach (var payer in vm.PayerPanelRows)
        {
            foreach (var (panel, cell) in payer.ByPanel)
                rows.Add([payer.PayerName, panel, cell.ClaimCount, cell.BilledCharges]);
        }
        return rows;
    }

    private static List<object?[]> FlattenPanelMonth(IEnumerable<PayerBreakdownRow> panels)
    {
        var rows = new List<object?[]>();
        foreach (var panel in panels)
        {
            foreach (var (mk, claims) in panel.ByMonth)
            {
                if (!TrySplitMonth(mk, out var year, out var month)) continue;
                var charges = panel.ByMonthCharges.GetValueOrDefault(mk);
                rows.Add([panel.PayerName, year, MonthName(month), claims, charges]);
            }
        }
        return rows;
    }

    private static bool TrySplitMonth(string monthKey, out int year, out int month)
    {
        year = 0;
        month = 0;
        if (string.IsNullOrWhiteSpace(monthKey) || monthKey.Length < 7) return false;
        if (!int.TryParse(monthKey.AsSpan(0, 4), out year) || year <= 1900) return false;
        return int.TryParse(monthKey.AsSpan(5, 2), out month) && month is >= 1 and <= 12;
    }

    private static string MonthName(int month) =>
        CultureInfo.InvariantCulture.DateTimeFormat.GetAbbreviatedMonthName(month);
}
