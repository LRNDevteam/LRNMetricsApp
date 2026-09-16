using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Native Excel PivotTables matching the Cove Collection Report client workbook:
/// Insurance Vs Payments, Insurance Vs Payments (%), Panel Vs Payments,
/// No Response Vs Aging, Rep Vs Payment — PivotStyleMedium21 + #385624 headers.
/// </summary>
public static partial class CollectionSummaryExcelExportBuilder
{
    private const string PctNumberFormat = @"#,##0.00""%"";";
    private const int PivotTitleColumns = 36;
    private const double PivotRowLabelWidth = 42;
    private const double PivotValueColumnWidth = 16;

    /// <summary>
    /// Client asked to drop native PivotTables — keep false so Build*Sheet paths
    /// write the fully formatted ClosedXML grids instead.
    /// </summary>
    private const bool UseNativePivots = false;

    internal static bool TryBuildInsurancePaymentPctPivot(
        XLWorkbook wb, List<InsurancePaymentPctRow> rows, string labName)
    {
        if (!UseNativePivots) return false;
        if (rows.Count == 0) return false;

        var withPeriod = rows.Any(r => (r.BillYear ?? 0) > 1900);
        var sourceRows = new List<object?[]>();
        foreach (var r in rows)
        {
            if (withPeriod)
                sourceRows.Add([r.PayerName, r.BillYear ?? 0, MonthLabel(r.BillMonth), r.TotalClaims, r.InsurancePayments, r.PaymentPct]);
            else
                sourceRows.Add([r.PayerName, r.TotalClaims, r.InsurancePayments, r.PaymentPct]);
        }

        var headers = withPeriod
            ? new[] { "Payer", "Year", "Month", "NoOfClaims", "InsurancePayments", "PaymentPct" }
            : new[] { "Payer", "NoOfClaims", "InsurancePayments", "PaymentPct" };

        var source = WritePivotSource(wb, "Ins Pay Pct Source", ExcelTheme.Collection.TabGold, sourceRows, headers);
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Insurance vs Payment %");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.Collection.WriteTitleBar(ws, 1, PivotTitleColumns, $"Insurance vs Payment % — {labName}");

        var pt = AddCovePivot(ws, "InsuranceVsPaymentsPctPivot", ws.Cell(3, 1), source,
            "Payer", "Insurance vs Payment %");
        pt.RowLabels.Add("Payer");
        if (withPeriod)
        {
            pt.ColumnLabels.Add("Year");
            pt.ColumnLabels.Add("Month");
        }
        AddSumValue(pt, "NoOfClaims", "Count of VisitNum");
        AddSumValue(pt, "InsurancePayments", "Sum of CarrierPayment", currency: true);
        AddValue(pt, "PaymentPct", "Average of Payment%", XLPivotSummary.Average, PctNumberFormat);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static void BuildInsuranceVsPaymentSheet(
        XLWorkbook wb, List<InsuranceVsPaymentRow> rows, string labName)
    {
        if (rows.Count == 0) return;

        if (!UseNativePivots)
        {
            BuildInsuranceVsPaymentFlatSheet(wb, rows, labName);
            return;
        }

        var sourceRows = rows.Select(r => new object?[]
        {
            r.PayerName, r.BillYear, MonthLabel(r.BillMonth), r.NoOfPaidClaims, r.InsurancePayment, r.PaymentPct,
        }).ToList();

        var source = WritePivotSource(wb, "Ins Pay Source", ExcelTheme.Collection.TabGold, sourceRows,
            "Payer", "Year", "Month", "NoOfClaims", "InsurancePayments", "PaymentPct");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Insurance Vs Payments");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.Collection.WriteTitleBar(ws, 1, PivotTitleColumns, $"Insurance Vs Payments — {labName}");

        var pt = AddCovePivot(ws, "InsuranceVsPaymentsPivot", ws.Cell(3, 1), source,
            "Payer", "Insurance Vs Payments");
        pt.RowLabels.Add("Payer");
        pt.ColumnLabels.Add("Year");
        pt.ColumnLabels.Add("Month");
        AddSumValue(pt, "NoOfClaims", "Count of VisitNum");
        AddSumValue(pt, "InsurancePayments", "Sum of CarrierPayment", currency: true);
        ApplyCovePivotStyle(pt);
    }

    /// <summary>Formatted payer × year/month grid (no PivotTable) — matches Collection UI.
    /// Cove client report is payer-flat only (no CheckDate month columns).</summary>
    private static void BuildInsuranceVsPaymentFlatSheet(
        XLWorkbook wb, List<InsuranceVsPaymentRow> rows, string labName)
    {
        var isCove = labName.Equals("Cove", StringComparison.OrdinalIgnoreCase)
            || labName.Contains("Cove", StringComparison.OrdinalIgnoreCase);

        var periods = isCove
            ? []
            : rows
                .Where(r => r.BillYear > 1900 && r.BillMonth is >= 1 and <= 12)
                .Select(r => (Year: r.BillYear, Month: r.BillMonth))
                .Distinct()
                .OrderBy(p => p.Year).ThenBy(p => p.Month)
                .ToList();

        if (periods.Count == 0)
        {
            // Cove / flat: Row Labels | Count of ClaimID | Sum of Insurance Payment.
            var wsFlat = wb.AddWorksheet("Insurance Vs Payments");
            wsFlat.TabColor = ExcelTheme.Collection.TabYellow;
            ExcelTheme.ApplyDefaults(wsFlat);
            string[] headers = isCove
                ? ["Row Labels", "Count of ClaimID", "Sum of Insurance Payment"]
                : ["Payer Name", "No. of Paid Claims", "Insurance Payment", "Payment %"];
            int row0 = 1;
            ExcelTheme.Collection.WriteTitleBar(wsFlat, row0, headers.Length, $"Insurance Vs Payments — {labName}");
            row0++;
            ExcelTheme.WriteHeaderRow(wsFlat, row0, 1, headers, ExcelTheme.Collection.HeaderBg);
            row0++;
            var groups = rows.GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
                .Select(g => new
                {
                    Payer = g.Key,
                    Claims = g.Sum(x => x.NoOfPaidClaims),
                    Pay = g.Sum(x => x.InsurancePayment),
                    Pct = g.Average(x => x.PaymentPct),
                })
                .OrderByDescending(g => g.Pay)
                .ToList();
            foreach (var g in groups)
            {
                WriteCell(wsFlat, row0, 1, g.Payer, XLColor.White, isText: true);
                WriteCell(wsFlat, row0, 2, g.Claims, XLColor.White);
                WriteCell(wsFlat, row0, 3, g.Pay, XLColor.White, isCurrency: true);
                if (!isCove)
                    WriteCell(wsFlat, row0, 4, g.Pct, XLColor.White, isPct: true);
                row0++;
            }
            // Grand Total row (matches client report)
            WriteCell(wsFlat, row0, 1, "Grand Total", ExcelTheme.Collection.TotalRowBg, isText: true);
            WriteCell(wsFlat, row0, 2, groups.Sum(g => g.Claims), ExcelTheme.Collection.TotalRowBg);
            WriteCell(wsFlat, row0, 3, groups.Sum(g => g.Pay), ExcelTheme.Collection.TotalRowBg, isCurrency: true);
            if (!isCove)
                WriteCell(wsFlat, row0, 4, "", ExcelTheme.Collection.TotalRowBg, isText: true);
            AutoFitColumns(wsFlat);
            return;
        }

        var years = periods.Select(p => p.Year).Distinct().OrderBy(y => y).ToList();
        var isAugustus = labName.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase)
            || labName.Equals("Augustus", StringComparison.OrdinalIgnoreCase);

        var pivotRows = rows
            .Where(r => r.BillYear > 1900 && r.BillMonth is >= 1 and <= 12)
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .Select(g => new
            {
                PayerName = g.Key,
                Cells = g.GroupBy(r => (Year: r.BillYear, Month: r.BillMonth))
                    .ToDictionary(
                        cg => cg.Key,
                        cg => (Count: cg.Sum(x => x.NoOfPaidClaims), Payment: cg.Sum(x => x.InsurancePayment))),
                TotalClaims = g.Sum(x => x.NoOfPaidClaims),
                TotalPay = g.Sum(x => x.InsurancePayment),
            })
            .OrderByDescending(r => isAugustus ? r.TotalClaims : r.TotalPay)
            .ToList();

        const int metrics = 2;
        int colCount = 1 + periods.Count * metrics + years.Count * metrics + metrics;

        var ws = wb.AddWorksheet("Insurance Vs Payments");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);

        int row = 1;
        ExcelTheme.Collection.WriteTitleBar(ws, row, colCount, $"Insurance Vs Payments — {labName}");
        row++;

        int hRow1 = row;
        WriteMergedHeader(ws, hRow1, hRow1 + 1, 1, 1, "Payer", ExcelTheme.Collection.HeaderBg);
        int hCol = 2;
        foreach (var year in years)
        {
            var mons = periods.Where(p => p.Year == year).ToList();
            int span = mons.Count * metrics + metrics;
            WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + span - 1, year.ToString(), ExcelTheme.Collection.HeaderBg);
            hCol += span;
        }
        WriteMergedHeader(ws, hRow1, hRow1, hCol, hCol + metrics - 1, "Grand Total", ExcelTheme.Collection.HeaderBg);

        int hRow2 = hRow1 + 1;
        hCol = 2;
        foreach (var year in years)
        {
            foreach (var p in periods.Where(x => x.Year == year))
            {
                var mk = new DateTime(p.Year, p.Month, 1).ToString("MMM");
                WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, mk, ExcelTheme.Collection.HeaderBg);
                hCol += 2;
            }
            WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, $"Year {year}", ExcelTheme.Collection.HeaderBg);
            hCol += 2;
        }
        WriteMergedHeader(ws, hRow2, hRow2, hCol, hCol + 1, "", ExcelTheme.Collection.HeaderBg);

        int hRow3 = hRow2 + 1;
        hCol = 2;
        void WriteMetricPair()
        {
            WriteHeaderCell(ws, hRow3, hCol++, "Count of Paid Claims", ExcelTheme.Collection.HeaderBg);
            WriteHeaderCell(ws, hRow3, hCol++, "Sum of Insurance Payment", ExcelTheme.Collection.HeaderBg);
        }
        foreach (var year in years)
        {
            foreach (var _ in periods.Where(x => x.Year == year))
                WriteMetricPair();
            WriteMetricPair();
        }
        WriteMetricPair();

        ws.Range(hRow1, 1, hRow3, 1).Merge();
        ws.Cell(hRow1, 1).Value = "Payer";
        ws.Cell(hRow1, 1).Style.Fill.BackgroundColor = ExcelTheme.Collection.HeaderBg;
        ws.Cell(hRow1, 1).Style.Font.Bold = true;
        ws.Cell(hRow1, 1).Style.Font.FontColor = XLColor.White;

        row = hRow3 + 1;
        foreach (var pr in pivotRows)
        {
            var bg = XLColor.White;
            int col = 1;
            WriteCell(ws, row, col++, pr.PayerName, bg, isText: true);
            foreach (var year in years)
            {
                int yClaims = 0;
                decimal yPay = 0m;
                foreach (var p in periods.Where(x => x.Year == year))
                {
                    pr.Cells.TryGetValue((p.Year, p.Month), out var cell);
                    WriteCell(ws, row, col++, cell.Count, bg);
                    WriteCell(ws, row, col++, cell.Payment, bg, isCurrency: true);
                    yClaims += cell.Count;
                    yPay += cell.Payment;
                }
                WriteCell(ws, row, col++, yClaims, bg);
                WriteCell(ws, row, col++, yPay, bg, isCurrency: true);
            }
            WriteCell(ws, row, col++, pr.TotalClaims, bg);
            WriteCell(ws, row, col, pr.TotalPay, bg, isCurrency: true);
            row++;
        }

        AutoFitColumns(ws);
    }

    internal static bool TryBuildPanelPaymentPivot(
        XLWorkbook wb, List<PanelPaymentRow> rows, string labName)
    {
        if (!UseNativePivots) return false;
        if (rows.Count == 0) return false;

        var withPeriod = rows.Any(r => r.BillYear > 1900);
        var sourceRows = new List<object?[]>();
        foreach (var r in rows)
        {
            if (withPeriod)
                sourceRows.Add([r.PanelName, r.BillYear, MonthLabel(r.BillMonth), r.NoOfClaims, r.InsurancePayments]);
            else
                sourceRows.Add([r.PanelName, r.NoOfClaims, r.InsurancePayments]);
        }

        var headers = withPeriod
            ? new[] { "Panel", "Year", "Month", "NoOfClaims", "InsurancePayments" }
            : new[] { "Panel", "NoOfClaims", "InsurancePayments" };

        var source = WritePivotSource(wb, "Panel Pay Source", ExcelTheme.Collection.TabGold, sourceRows, headers);
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Panel Vs Payments");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.Collection.WriteTitleBar(ws, 1, PivotTitleColumns, $"Panel Vs Payments — {labName}");

        var pt = AddCovePivot(ws, "PanelVsPaymentsPivot", ws.Cell(3, 1), source,
            "Panel", "Panel Vs Payments");
        pt.RowLabels.Add("Panel");
        if (withPeriod)
        {
            pt.ColumnLabels.Add("Year");
            pt.ColumnLabels.Add("Month");
        }
        AddSumValue(pt, "NoOfClaims", "No Of Claims");
        AddSumValue(pt, "InsurancePayments", "Total Carrier Payment", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildInsuranceAgingPivot(
        XLWorkbook wb, List<InsuranceAgingRow> rows, string labName)
    {
        if (!UseNativePivots) return false;
        if (rows.Count == 0) return false;

        var sourceRows = new List<object?[]>();
        foreach (var r in rows)
        {
            AddAgingBucket(sourceRows, r.PayerName, "Current", r.ClaimsCurrent, r.BalanceCurrent);
            AddAgingBucket(sourceRows, r.PayerName, "30+", r.Claims30, r.Balance30);
            AddAgingBucket(sourceRows, r.PayerName, "60+", r.Claims60, r.Balance60);
            AddAgingBucket(sourceRows, r.PayerName, "90+", r.Claims90, r.Balance90);
            AddAgingBucket(sourceRows, r.PayerName, "120+", r.Claims120, r.Balance120);
        }
        if (sourceRows.Count == 0) return false;

        var source = WritePivotSource(wb, "Aging Source", ExcelTheme.Collection.TabGold, sourceRows,
            "Payer", "Aging", "NoOfClaims", "CarrierBalance");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("No Response Vs Aging");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.Collection.WriteTitleBar(ws, 1, PivotTitleColumns, $"No Response Vs Aging — {labName}");

        var pt = AddCovePivot(ws, "NoResponseVsAgingPivot", ws.Cell(3, 1), source,
            "Payer", "No Response Vs Aging");
        pt.RowLabels.Add("Payer");
        pt.ColumnLabels.Add("Aging");
        AddSumValue(pt, "NoOfClaims", "No Of Claims");
        AddSumValue(pt, "CarrierBalance", "Carrier Balance", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildCptPaymentPctPivot(
        XLWorkbook wb, List<CptPaymentPctRow> rows, string labName)
    {
        if (!UseNativePivots) return false;
        if (rows.Count == 0) return false;

        var sourceRows = rows.Select(r => new object?[] { r.CptCode, r.SumServiceUnits, r.PaymentPct }).ToList();
        var source = WritePivotSource(wb, "Cpt Pay Source", ExcelTheme.Collection.TabGold, sourceRows,
            "CPT", "ServiceUnits", "PaymentPct");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("CPT vs Payment %");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.Collection.WriteTitleBar(ws, 1, PivotTitleColumns, $"CPT vs Payment % — {labName}");

        var pt = AddCovePivot(ws, "CptVsPaymentPctPivot", ws.Cell(3, 1), source,
            "CPT", "CPT vs Payment %");
        pt.RowLabels.Add("CPT");
        AddSumValue(pt, "ServiceUnits", "Service Units");
        AddValue(pt, "PaymentPct", "Payment %", XLPivotSummary.Average, PctNumberFormat);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildProviderSummaryPivot(
        XLWorkbook wb, ProviderSummaryResult result, string labName)
    {
        if (!UseNativePivots) return false;
        if (!result.HasData) return false;

        var sourceRows = result.Rows.Select(r => new object?[]
        {
            r.ReferringProvider, r.NoOfClaims, r.InsurancePayments, r.InsuranceBalance, r.PatientBalance,
        }).ToList();

        var source = WritePivotSource(wb, "Prov Pay Source", ExcelTheme.Collection.TabGold, sourceRows,
            "Rep", "NoOfClaims", "InsurancePayments", "InsuranceBalance", "PatientBalance");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Provider Summary");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.Collection.WriteTitleBar(ws, 1, PivotTitleColumns, $"Provider Summary — {labName}");

        var pt = AddCovePivot(ws, "ProviderSummaryPivot", ws.Cell(3, 1), source,
            "Rep", "Provider Summary");
        pt.RowLabels.Add("Rep");
        AddSumValue(pt, "NoOfClaims", "No Of Claims");
        AddSumValue(pt, "InsurancePayments", "Carrier Payment", currency: true);
        AddSumValue(pt, "InsuranceBalance", "Insurance Balance", currency: true);
        AddSumValue(pt, "PatientBalance", "Patient Balance", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    internal static bool TryBuildRepVsPaymentPivot(
        XLWorkbook wb, RepPaymentResult result, string labName)
    {
        if (!UseNativePivots) return false;
        if (result.Rows.Count == 0) return false;

        var sourceRows = result.Rows.Select(r => new object?[]
        {
            r.SalesRepName, r.Year, MonthLabel(r.Month), r.NoOfClaims, r.InsurancePayments,
        }).ToList();

        var source = WritePivotSource(wb, "Rep Pay Source", ExcelTheme.Collection.TabGold, sourceRows,
            "Rep", "Year", "Month", "NoOfClaims", "InsurancePayments");
        source.Worksheet.Visibility = XLWorksheetVisibility.Hidden;

        var ws = wb.AddWorksheet("Rep Vs Payment");
        ws.TabColor = ExcelTheme.Collection.TabYellow;
        ExcelTheme.ApplyDefaults(ws);
        ExcelTheme.Collection.WriteTitleBar(ws, 1, PivotTitleColumns, $"Rep Vs Payment — {labName}");

        var pt = AddCovePivot(ws, "RepVsPaymentPivot", ws.Cell(3, 1), source,
            "Rep", "Rep Vs Payment");
        pt.RowLabels.Add("Rep");
        pt.ColumnLabels.Add("Year");
        pt.ColumnLabels.Add("Month");
        AddSumValue(pt, "NoOfClaims", "No Of Claims");
        AddSumValue(pt, "InsurancePayments", "Carrier Payment", currency: true);
        ApplyCovePivotStyle(pt);
        return true;
    }

    private static void AddAgingBucket(
        List<object?[]> rows, string payer, string aging, int claims, decimal balance)
    {
        if (claims == 0 && balance == 0m) return;
        rows.Add([payer, aging, claims, balance]);
    }

    private static string MonthLabel(int? month)
    {
        if (month is >= 1 and <= 12)
            return new DateTime(2000, month.Value, 1).ToString("MMM");
        return string.Empty;
    }

    private static IXLPivotTable AddCovePivot(
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
        style.Fill.BackgroundColor = ExcelTheme.Collection.HeaderBg;
        style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
    }

    private static void FinishPivotLayout(IXLPivotTable pt)
    {
        var ws = pt.Worksheet;
        ws.Column(1).Width = PivotRowLabelWidth;
        for (var c = 2; c <= PivotTitleColumns; c++)
            ws.Column(c).Width = PivotValueColumnWidth;
        // Do not materialize empty rows over the pivot target — Excel paints the
        // pivot body on open from the cache. Empty A3:A5 rows hide that body.
    }

    private static void AddSumValue(IXLPivotTable pt, string field, string caption, bool currency = false)
    {
        AddValue(pt, field, caption, XLPivotSummary.Sum,
            currency ? ExcelTheme.AccountingNumberFormat2 : ExcelTheme.Collection.CountNumberFormat);
    }

    private static void AddValue(
        IXLPivotTable pt, string field, string caption, XLPivotSummary summary, string format)
    {
        var value = pt.Values.Add(field).SetSummaryFormula(summary);
        value.CustomName = caption;
        value.NumberFormat.Format = format;
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
        if (char.IsDigit(tableName[0])) tableName = "T" + tableName;
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
}
