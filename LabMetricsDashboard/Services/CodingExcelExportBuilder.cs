using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds a formatted Excel workbook from Coding Summary data
/// using the client's green-themed branding via <see cref="ExcelTheme"/>.
/// Produces sheets: Financial Dashboard, YTD Insights, YTD Summary,
/// WTD Insights, WTD Summary, and Validation Detail.
/// </summary>
public static class CodingExcelExportBuilder
{
    /// <summary>Creates the workbook from the Coding Summary view model.</summary>
    public static XLWorkbook CreateWorkbook(CodingSummaryViewModel vm, string labName)
    {
        var wb = new XLWorkbook();

        var fin = vm.LatestFinancial;
        if (fin is not null)
            BuildKpiDashboardSheet(wb, fin, labName);

        if (vm.FinancialRows.Count > 0)
            BuildFinancialSheet(wb, vm.FinancialRows, labName);

        if (vm.SummaryRows.Count > 0)
            BuildYtdSummarySheet(wb, vm.SummaryRows);

        if (vm.InsightRows.Count > 0)
            BuildYtdInsightsSheet(wb, vm.InsightRows);

        if (vm.WtdSummaryRows.Count > 0)
            BuildWtdSummarySheet(wb, vm.WtdSummaryRows);

        if (vm.WtdInsightRows.Count > 0)
            BuildWtdInsightsSheet(wb, vm.WtdInsightRows);

        if (vm.DetailRows.Count > 0)
            BuildValidationDetailSheet(wb, vm.DetailRows);

        return wb;
    }

    // ── Colour constants for the KPI dashboard cards ─────────────────────

    private static readonly XLColor NavyBg       = XLColor.FromHtml("#0D1B2A");
    private static readonly XLColor NavyMedium    = XLColor.FromHtml("#1B3A5C");
    private static readonly XLColor BluePrimary   = XLColor.FromHtml("#1565C0");
    private static readonly XLColor CardBorder    = XLColor.FromHtml("#E0E6ED");
    private static readonly XLColor LabelGray     = XLColor.FromHtml("#5A6A8A");
    private static readonly XLColor ValueNavy     = XLColor.FromHtml("#1A2744");
    private static readonly XLColor DangerRed     = XLColor.FromHtml("#C62828");
    private static readonly XLColor SuccessGreen  = XLColor.FromHtml("#2E7D32");
    private static readonly XLColor WarningOrange = XLColor.FromHtml("#E65100");
    private static readonly XLColor CardBg        = XLColor.FromHtml("#F8FAFC");
    private static readonly XLColor TagBg         = XLColor.FromHtml("#EEF2F7");

    // ── KPI Dashboard sheet ─────────────────────────────────────────────

    /// <summary>
    /// Creates a styled "KPI Dashboard" sheet that visually reproduces the
    /// four metric cards shown on the web page (Totals, Revenue Loss,
    /// Revenue At Risk, Compliance Rate).
    /// </summary>
    private static void BuildKpiDashboardSheet(XLWorkbook wb,
        CodingFinancialSummaryRow fin, string labName)
    {
        var ws = wb.AddWorksheet("KPI Dashboard");
        ws.TabColor = ExcelTheme.TabBlue;
        ExcelTheme.ApplyDefaults(ws);

        // Set column widths for a clean card layout:
        //  A=tag(4)  B=label(32)  C=value(22)  D=spacer(3)
        //  E=tag(4)  F=label(32)  G=value(22)
        ws.Column(1).Width = 4;
        ws.Column(2).Width = 32;
        ws.Column(3).Width = 22;
        ws.Column(4).Width = 3;
        ws.Column(5).Width = 4;
        ws.Column(6).Width = 32;
        ws.Column(7).Width = 22;

        const int totalCols = 7;
        int row = 1;

        // ── Header bar (dark navy, spans all columns) ────────────────────
        var headerRange = ws.Range(row, 1, row, totalCols);
        headerRange.Merge();
        var headerCell = ws.Cell(row, 1);
        headerCell.Value = $"Coding Summary KPI Dashboard  |  {labName}";
        headerCell.Style.Font.Bold = true;
        headerCell.Style.Font.FontSize = 14;
        headerCell.Style.Font.FontColor = XLColor.White;
        headerCell.Style.Fill.BackgroundColor = NavyBg;
        headerCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        headerCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(row).Height = 32;
        row++;

        // ── Week + Report Date sub-header ────────────────────────────────
        var subRange = ws.Range(row, 1, row, totalCols);
        subRange.Merge();
        var subCell = ws.Cell(row, 1);
        var reportLine = fin.WeekFolder;
        if (!string.IsNullOrWhiteSpace(fin.ReportDate))
            reportLine += $"     Report Date: {fin.ReportDate}";
        subCell.Value = reportLine;
        subCell.Style.Font.Bold = true;
        subCell.Style.Font.FontSize = 11;
        subCell.Style.Font.FontColor = XLColor.White;
        subCell.Style.Fill.BackgroundColor = NavyMedium;
        subCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        subCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(row).Height = 26;
        row++;

        // blank spacer row
        row++;

        // ── Row 1: TOTALS (left) + REVENUE LOSS (right) ─────────────────
        row = WriteCardTitle(ws, row, 1, 3, "TOTALS", "Overall billing volume & expected value");
        WriteCardTitle(ws, row - 2, 5, 7, "REVENUE LOSS", "Claims with issues producing leakage");

        row = WriteKpiRow(ws, row, 1, "#", "Total No. of Claims",
            fin.TotalClaims.ToString("N0"), ValueNavy);
        WriteKpiRow(ws, row - 1, 5, "#", "Total No. of Claims",
            fin.RevenueLoss_Claims?.ToString("N0") ?? "—", ValueNavy);

        row = WriteKpiRow(ws, row, 1, "$", "Total Billed Charges",
            $"${fin.TotalBilledCharges:N2}", ValueNavy);
        WriteKpiRow(ws, row - 1, 5, "$", "Total Actual Billed Charges",
            $"${fin.RevenueLoss_ActualBilled:N2}", ValueNavy);

        row = WriteKpiRow(ws, row, 1, "≈", "Expected Billed Charges",
            $"${fin.ExpectedBilledCharges:N2}", BluePrimary);
        WriteKpiRow(ws, row - 1, 5, "!", "Potential Loss in Revenue",
            $"${fin.RevenueLoss_PotentialLoss:N2}", DangerRed);

        // card bottom border
        WriteCardBottomBorder(ws, row, 1, 3, BluePrimary);
        WriteCardBottomBorder(ws, row, 5, 7, DangerRed);
        row++;

        // blank spacer row
        row++;

        // ── Row 2: REVENUE AT RISK (left) + COMPLIANCE RATE (right) ─────
        row = WriteCardTitle(ws, row, 1, 3, "REVENUE AT RISK", "Recoverable value pending resolution");
        WriteCardTitle(ws, row - 2, 5, 7, "COMPLIANCE RATE", "Issue-free claims ratio for the selected period");

        row = WriteKpiRow(ws, row, 1, "#", "Total No. of Claims",
            fin.RevenueAtRisk_Claims?.ToString("N0") ?? "—", ValueNavy);
        WriteKpiRow(ws, row - 1, 5, "#", "Total No. of Claims",
            fin.Compliance_TotalClaims?.ToString("N0") ?? "—", ValueNavy);

        row = WriteKpiRow(ws, row, 1, "$", "Total Actual Billed Charges",
            $"${fin.RevenueAtRisk_ActualBilled:N2}", ValueNavy);
        WriteKpiRow(ws, row - 1, 5, "!", "Claims with Issues",
            fin.Compliance_ClaimsWithIssues?.ToString("N0") ?? "—", DangerRed);

        row = WriteKpiRow(ws, row, 1, "✓", "Potential Recoupment",
            $"${fin.RevenueAtRisk_PotentialRecoup:N2}", SuccessGreen);
        WriteKpiRow(ws, row - 1, 5, "%", "Compliance Rate",
            fin.ComplianceRatePct, GetComplianceColor(fin.ComplianceRatePct));

        // card bottom border
        WriteCardBottomBorder(ws, row, 1, 3, WarningOrange);
        WriteCardBottomBorder(ws, row, 5, 7, BluePrimary);
        row++;

        // blank spacer row
        row++;

        // ── Detail Breakdown section ─────────────────────────────────────
        var detailRange = ws.Range(row, 1, row, totalCols);
        detailRange.Merge();
        var detailCell = ws.Cell(row, 1);
        detailCell.Value = "Detail Breakdown";
        detailCell.Style.Font.Bold = true;
        detailCell.Style.Font.FontSize = 11;
        detailCell.Style.Font.FontColor = XLColor.White;
        detailCell.Style.Fill.BackgroundColor = NavyMedium;
        detailCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(row).Height = 24;
        row++;

        string[] detLabels =
        [
            "Total Claims",
            "Claims with Missing CPTs",
            "Claims with Additional CPTs",
            "Claims with Missing & Additional CPTs",
            "Total Error Claims",
            "Compliance Rate %"
        ];
        string[] detValues =
        [
            fin.TotalClaims.ToString("N0"),
            fin.ClaimsWithMissingCPTs?.ToString("N0") ?? "—",
            fin.ClaimsWithAdditionalCPTs?.ToString("N0") ?? "—",
            fin.ClaimsWithBothMissingAndAdditional?.ToString("N0") ?? "—",
            fin.TotalErrorClaims?.ToString("N0") ?? "—",
            fin.ComplianceRatePct
        ];
        XLColor[] detColors =
        [
            ValueNavy, ValueNavy, ValueNavy, ValueNavy, DangerRed,
            GetComplianceColor(fin.ComplianceRatePct)
        ];

        for (int i = 0; i < detLabels.Length; i++)
        {
            var bg = i % 2 == 0 ? XLColor.White : CardBg;
            var labelMerge = ws.Range(row, 1, row, 3);
            labelMerge.Merge();
            var lc = ws.Cell(row, 1);
            lc.Value = detLabels[i];
            lc.Style.Font.Bold = true;
            lc.Style.Font.FontSize = 10;
            lc.Style.Font.FontColor = LabelGray;
            lc.Style.Fill.BackgroundColor = bg;
            lc.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            lc.Style.Border.OutsideBorderColor = CardBorder;

            var valMerge = ws.Range(row, 4, row, totalCols);
            valMerge.Merge();
            var vc = ws.Cell(row, 4);
            vc.Value = detValues[i];
            vc.Style.Font.Bold = true;
            vc.Style.Font.FontSize = 11;
            vc.Style.Font.FontColor = detColors[i];
            vc.Style.Fill.BackgroundColor = bg;
            vc.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
            vc.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            vc.Style.Border.OutsideBorderColor = CardBorder;
            row++;
        }

        // Print / view settings
        ws.PageSetup.PageOrientation = XLPageOrientation.Landscape;
        ws.PageSetup.FitToPages(1, 1);
        ws.SheetView.ZoomScale = 120;
    }

    /// <summary>Writes a card title row (bold heading + subtitle) and returns the next row.</summary>
    private static int WriteCardTitle(IXLWorksheet ws, int row,
        int startCol, int endCol, string title, string subtitle)
    {
        // Title row
        var titleRange = ws.Range(row, startCol, row, endCol);
        titleRange.Merge();
        var tc = ws.Cell(row, startCol);
        tc.Value = title;
        tc.Style.Font.Bold = true;
        tc.Style.Font.FontSize = 12;
        tc.Style.Font.FontColor = ValueNavy;
        tc.Style.Fill.BackgroundColor = XLColor.White;
        tc.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        tc.Style.Border.OutsideBorderColor = CardBorder;
        tc.Style.Border.BottomBorder = XLBorderStyleValues.None;
        tc.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(row).Height = 22;
        row++;

        // Subtitle row
        var subRange = ws.Range(row, startCol, row, endCol);
        subRange.Merge();
        var sc = ws.Cell(row, startCol);
        sc.Value = subtitle;
        sc.Style.Font.Italic = true;
        sc.Style.Font.FontSize = 9;
        sc.Style.Font.FontColor = LabelGray;
        sc.Style.Fill.BackgroundColor = XLColor.White;
        sc.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        sc.Style.Border.OutsideBorderColor = CardBorder;
        sc.Style.Border.TopBorder = XLBorderStyleValues.None;
        sc.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(row).Height = 18;
        row++;

        return row;
    }

    /// <summary>Writes a single KPI metric row (tag | label | value) and returns the next row.</summary>
    private static int WriteKpiRow(IXLWorksheet ws, int row,
        int startCol, string tag, string label, string value, XLColor valueColor)
    {
        int tagCol   = startCol;
        int labelCol = startCol + 1;
        int valCol   = startCol + 2;

        // Tag cell (small icon/symbol)
        var tagCell = ws.Cell(row, tagCol);
        tagCell.Value = tag;
        tagCell.Style.Font.Bold = true;
        tagCell.Style.Font.FontSize = 10;
        tagCell.Style.Font.FontColor = LabelGray;
        tagCell.Style.Fill.BackgroundColor = TagBg;
        tagCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        tagCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        tagCell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        tagCell.Style.Border.OutsideBorderColor = CardBorder;

        // Label cell
        var labelCell = ws.Cell(row, labelCol);
        labelCell.Value = label;
        labelCell.Style.Font.FontSize = 10;
        labelCell.Style.Font.FontColor = ValueNavy;
        labelCell.Style.Fill.BackgroundColor = XLColor.White;
        labelCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        labelCell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        labelCell.Style.Border.OutsideBorderColor = CardBorder;

        // Value cell
        var valCell = ws.Cell(row, valCol);
        valCell.Value = value;
        valCell.Style.Font.Bold = true;
        valCell.Style.Font.FontSize = 13;
        valCell.Style.Font.FontColor = valueColor;
        valCell.Style.Fill.BackgroundColor = XLColor.White;
        valCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        valCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        valCell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        valCell.Style.Border.OutsideBorderColor = CardBorder;

        ws.Row(row).Height = 24;
        return row + 1;
    }

    /// <summary>Writes a thin coloured accent bar at the bottom of a KPI card.</summary>
    private static void WriteCardBottomBorder(IXLWorksheet ws, int row,
        int startCol, int endCol, XLColor accentColor)
    {
        for (int c = startCol; c <= endCol; c++)
        {
            var cell = ws.Cell(row, c);
            cell.Style.Fill.BackgroundColor = accentColor;
            cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.OutsideBorderColor = accentColor;
        }
        ws.Row(row).Height = 4;
    }

    /// <summary>Returns the appropriate colour for a compliance percentage string.</summary>
    private static XLColor GetComplianceColor(string compliancePct)
    {
        var trimmed = compliancePct.TrimEnd('%');
        if (decimal.TryParse(trimmed, System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out var pct))
        {
            return pct >= 90m ? SuccessGreen : WarningOrange;
        }
        return ValueNavy;
    }

    // ── Shared helpers for data sheets ───────────────────────────────────
    // All data sheets (Financial Dashboard, YTD/WTD Insights & Summary,
    // Validation Detail) use the same blue/amber palette and helpers as the
    // Production Report so all reports share a single visual language.

    /// <summary>Writes the dark-green title bar (Accent 6 darker 50 %).</summary>
    private static void WriteUiTitleBar(IXLWorksheet ws, int row, int colCount, string text)
        => ExcelTheme.WriteTitleBar(ws, row, colCount, text);

    /// <summary>Writes a single-row column header band (Accent 6 darker 25 % green).</summary>
    private static void WriteUiHeaderRow(IXLWorksheet ws, int row, string[] headers)
    {
        ExcelTheme.WriteHeaderRow(ws, row, 1, headers, ExcelTheme.HeaderBg);
        ws.Row(row).Height = 28;
    }

    /// <summary>
    /// Writes a year/week section title bar between data sets, using the
    /// lighter green (Accent 6 base, <c>#70AD47</c>) so it sits visibly
    /// between the dark-green column header and the light banded data rows.
    /// </summary>
    private static void WriteUiGroupRow(IXLWorksheet ws, int row, int colCount, string label)
    {
        ExcelTheme.WriteSectionTitle(ws, row, 1, colCount, label, ExcelTheme.SubHeaderBg);
        ws.Row(row).Height = 22;
    }

    /// <summary>
    /// Applies the standard banded data-cell styling. <paramref name="isAlt"/>
    /// alternates between white and the Accent 6 lighter-80 % band.
    /// </summary>
    private static void StyleUiDataCell(IXLCell cell, bool isAlt)
    {
        var bg = isAlt ? ExcelTheme.BandedRowBg : XLColor.White;
        ExcelTheme.StyleDataCell(cell, bg);
    }

    /// <summary>Bold panel-name cell (no chip background to match Production Report).</summary>
    private static void StylePanelChip(IXLCell cell)
    {
        cell.Style.Font.Bold = true;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
    }

    /// <summary>Monospace font for CPT-code cells; background inherited from band.</summary>
    private static void StyleCptCell(IXLCell cell)
    {
        cell.Style.Font.FontName = "Consolas";
        cell.Style.Font.FontSize = 9;
        cell.Style.Alignment.WrapText = true;
    }

    /// <summary>Right-aligned currency. Negative values shown red; non-zero bold.</summary>
    private static void StyleMoneyCell(IXLCell cell, decimal value)
    {
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        cell.Style.Font.Bold = value != 0;
        if (value < 0)
            cell.Style.Font.FontColor = ExcelTheme.BadFg;
    }

    /// <summary>Net-impact cell with semantic colour coding using ExcelTheme palette.</summary>
    private static void StyleImpactCell(IXLCell cell, decimal value)
    {
        cell.Style.Font.Bold = true;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        if (value < 0)
        {
            cell.Style.Font.FontColor = ExcelTheme.BadFg;
            cell.Style.Fill.BackgroundColor = ExcelTheme.BadBg;
        }
        else if (value > 0)
        {
            cell.Style.Font.FontColor = ExcelTheme.GoodFg;
            cell.Style.Fill.BackgroundColor = ExcelTheme.GoodBg;
        }
        else
        {
            cell.Style.Font.FontColor = ExcelTheme.NeutralFg;
            cell.Style.Fill.BackgroundColor = ExcelTheme.NeutralBg;
        }
    }

    /// <summary>Validation status cell using ExcelTheme good / neutral / bad colours.</summary>
    private static void StyleStatusCell(IXLCell cell, string status)
    {
        cell.Style.Font.Bold = true;
        cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        if (status.Contains("Match", StringComparison.OrdinalIgnoreCase))
        {
            cell.Style.Font.FontColor = ExcelTheme.GoodFg;
            cell.Style.Fill.BackgroundColor = ExcelTheme.GoodBg;
        }
        else if (status.Contains("Missing", StringComparison.OrdinalIgnoreCase))
        {
            cell.Style.Font.FontColor = ExcelTheme.BadFg;
            cell.Style.Fill.BackgroundColor = ExcelTheme.BadBg;
        }
        else if (status.Contains("Additional", StringComparison.OrdinalIgnoreCase))
        {
            cell.Style.Font.FontColor = ExcelTheme.NeutralFg;
            cell.Style.Fill.BackgroundColor = ExcelTheme.NeutralBg;
        }
    }

    // ── Financial Dashboard sheet ────────────────────────────────────────

    private static void BuildFinancialSheet(XLWorkbook wb,
        List<CodingFinancialSummaryRow> rows, string labName)
    {
        var ws = wb.AddWorksheet("Financial Dashboard");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Week", "Report Date",
            "Total Claims", "Total Billed", "Expected Billed",
            "Rev Impact Claims", "Rev Impact Actual Billed", "Rev Impact Loss", "Rev Impact Recoup",
            "Rev Loss Claims", "Rev Loss Actual Billed", "Rev Loss Potential",
            "Rev at Risk Claims", "Rev at Risk Actual Billed", "Rev at Risk Recoup",
            "Compliance Claims", "Claims w/ Issues", "Compliance Rate",
            "Missing CPTs", "Additional CPTs", "Both Missing & Additional",
            "Total Error Claims", "Compliance Rate %"
        ];
        int colCount = headers.Length;

        WriteUiTitleBar(ws, 1, colCount, $"Coding Financial Dashboard  |  {labName}");
        WriteUiHeaderRow(ws, 2, headers);

        var moneyCols = new HashSet<int> { 4, 5, 7, 8, 9, 11, 12, 14, 15 };

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            bool isAlt = r % 2 != 0;
            var f = rows[r];

            ws.Cell(rowNum, 1).Value = f.WeekFolder;
            ws.Cell(rowNum, 2).Value = f.ReportDate;
            ws.Cell(rowNum, 3).Value = f.TotalClaims;
            ws.Cell(rowNum, 4).Value = f.TotalBilledCharges;
            ws.Cell(rowNum, 5).Value = f.ExpectedBilledCharges;
            if (f.RevenueImpact_Claims.HasValue) ws.Cell(rowNum, 6).Value = f.RevenueImpact_Claims.Value;
            ws.Cell(rowNum, 7).Value = f.RevenueImpact_ActualBilled;
            ws.Cell(rowNum, 8).Value = f.RevenueImpact_PotentialLoss;
            ws.Cell(rowNum, 9).Value = f.RevenueImpact_ExpectedRecoup;
            if (f.RevenueLoss_Claims.HasValue) ws.Cell(rowNum, 10).Value = f.RevenueLoss_Claims.Value;
            ws.Cell(rowNum, 11).Value = f.RevenueLoss_ActualBilled;
            ws.Cell(rowNum, 12).Value = f.RevenueLoss_PotentialLoss;
            if (f.RevenueAtRisk_Claims.HasValue) ws.Cell(rowNum, 13).Value = f.RevenueAtRisk_Claims.Value;
            ws.Cell(rowNum, 14).Value = f.RevenueAtRisk_ActualBilled;
            ws.Cell(rowNum, 15).Value = f.RevenueAtRisk_PotentialRecoup;
            if (f.Compliance_TotalClaims.HasValue) ws.Cell(rowNum, 16).Value = f.Compliance_TotalClaims.Value;
            if (f.Compliance_ClaimsWithIssues.HasValue) ws.Cell(rowNum, 17).Value = f.Compliance_ClaimsWithIssues.Value;
            ws.Cell(rowNum, 18).Value = f.ComplianceRate;
            if (f.ClaimsWithMissingCPTs.HasValue) ws.Cell(rowNum, 19).Value = f.ClaimsWithMissingCPTs.Value;
            if (f.ClaimsWithAdditionalCPTs.HasValue) ws.Cell(rowNum, 20).Value = f.ClaimsWithAdditionalCPTs.Value;
            if (f.ClaimsWithBothMissingAndAdditional.HasValue) ws.Cell(rowNum, 21).Value = f.ClaimsWithBothMissingAndAdditional.Value;
            if (f.TotalErrorClaims.HasValue) ws.Cell(rowNum, 22).Value = f.TotalErrorClaims.Value;
            ws.Cell(rowNum, 23).Value = f.ComplianceRatePct;

            for (int c = 1; c <= colCount; c++)
            {
                var cell = ws.Cell(rowNum, c);
                StyleUiDataCell(cell, isAlt);
                if (moneyCols.Contains(c))
                    StyleMoneyCell(cell, (decimal)(cell.Value.IsNumber ? cell.Value.GetNumber() : 0));
            }

            // Colour the loss column red, recoup green
            StyleMoneyCell(ws.Cell(rowNum, 12), -1); // always red
            if (f.RevenueAtRisk_PotentialRecoup > 0)
                StyleMoneyCell(ws.Cell(rowNum, 15), 1); // always blue/positive
        }

        // Number formats
        var countCols = new[] { 3, 6, 10, 13, 16, 17, 19, 20, 21, 22 };
        foreach (int c in countCols) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        foreach (int c in moneyCols) ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 16);
    }

    // ── YTD Insights sheet ──────────────────────────────────────────────

    private static void BuildYtdInsightsSheet(XLWorkbook wb, List<CodingInsightRow> rows)
    {
        var ws = wb.AddWorksheet("YTD Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Year", "Panel Name", "Billable CPT Combo", "Total Claims",
            "Billed Charges/Claim", "Billed CPT Combo", "Missing CPTs",
            "Billed Charges (Missing)", "Lost Revenue",
            "Additional CPTs", "Billed Charges (Additional)", "Revenue at Risk", "Net Impact"
        ];
        int colCount = headers.Length;

        WriteUiTitleBar(ws, 1, colCount, "YTD Coding Insights");

        // Group by year (matching the web UI year-pill sections)
        var years = rows.Select(r => r.Year).Distinct().OrderByDescending(y => y).ToList();
        int rowNum = 2;

        foreach (var year in years)
        {
            var yearRows = rows.Where(r => r.Year == year).ToList();

            // Year group header (blue pill)
            WriteUiGroupRow(ws, rowNum, colCount, $"{year}   ({yearRows.Count} panel{(yearRows.Count != 1 ? "s" : "")})");
            rowNum++;

            // Column headers
            WriteUiHeaderRow(ws, rowNum, headers);
            rowNum++;

            for (int r = 0; r < yearRows.Count; r++)
            {
                bool isAlt = r % 2 != 0;
                var i = yearRows[r];

                ws.Cell(rowNum, 1).Value = i.Year;
                ws.Cell(rowNum, 2).Value = i.PanelName;
                ws.Cell(rowNum, 3).Value = i.BillableCptCombo;
                ws.Cell(rowNum, 4).Value = i.TotalClaims;
                ws.Cell(rowNum, 5).Value = i.BilledChargesPerClaim;
                ws.Cell(rowNum, 6).Value = i.BilledCptCombo;
                ws.Cell(rowNum, 7).Value = i.MissingCpts;
                ws.Cell(rowNum, 8).Value = i.TotalBilledChargesForMissingCpts;
                ws.Cell(rowNum, 9).Value = i.LostRevenue;
                ws.Cell(rowNum, 10).Value = i.AdditionalCpts;
                ws.Cell(rowNum, 11).Value = i.TotalBilledChargesForAdditionalCpts;
                ws.Cell(rowNum, 12).Value = i.RevenueAtRisk;
                ws.Cell(rowNum, 13).Value = i.NetImpact;

                for (int c = 1; c <= colCount; c++)
                    StyleUiDataCell(ws.Cell(rowNum, c), isAlt);

                // Panel chip
                StylePanelChip(ws.Cell(rowNum, 2));
                // CPT columns
                StyleCptCell(ws.Cell(rowNum, 3));
                StyleCptCell(ws.Cell(rowNum, 6));
                StyleCptCell(ws.Cell(rowNum, 7));
                StyleCptCell(ws.Cell(rowNum, 10));
                // Money columns with colour coding
                StyleMoneyCell(ws.Cell(rowNum, 5), i.BilledChargesPerClaim);
                StyleMoneyCell(ws.Cell(rowNum, 8), i.TotalBilledChargesForMissingCpts);
                StyleMoneyCell(ws.Cell(rowNum, 9), i.LostRevenue != 0 ? -1 : 0); // lost = always red
                StyleMoneyCell(ws.Cell(rowNum, 11), i.TotalBilledChargesForAdditionalCpts);
                StyleMoneyCell(ws.Cell(rowNum, 12), i.RevenueAtRisk);
                // Net Impact chip
                StyleImpactCell(ws.Cell(rowNum, 13), i.NetImpact);
                // Count column
                ws.Cell(rowNum, 4).Style.Font.Bold = true;

                rowNum++;
            }
        }

        // Number formats
        ws.Column(4).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 5, 8, 9, 11, 12, 13 })
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(1);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 12);
    }

    // ── YTD Summary sheet ───────────────────────────────────────────────

    private static void BuildYtdSummarySheet(XLWorkbook wb, List<CodingSummaryRow> rows)
    {
        var ws = wb.AddWorksheet("YTD Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        // CPT-combination columns are intentionally omitted - they are surfaced
        // in the YTD Insights sheet (per-combination breakdown).
        string[] headers =
        [
            "Year", "Panel",
            "Total No. of Claims", "Total Billed Charges",
            "Distinct claims with Missing CPTs", "Total Billed Charges for Missing CPTs",
            "Distinct claims with Additional CPTs", "Total Billed Charges for Additional CPTs",
            "Lost Revenue", "Revenue at Risk", "Net Impact"
        ];
        int colCount = headers.Length;

        WriteUiTitleBar(ws, 1, colCount, "YTD Coding Summary");

        var years = rows.Select(r => r.Year).Distinct().OrderByDescending(y => y).ToList();
        int rowNum = 2;

        foreach (var year in years)
        {
            // Blank spacer row between groups (except the first)
            if (rowNum > 2) rowNum++;

            // Repeat header row per year section
            WriteUiHeaderRow(ws, rowNum, headers);
            rowNum++;

            var yearRows = rows.Where(r => r.Year == year).ToList();
            for (int r = 0; r < yearRows.Count; r++)
            {
                bool isAlt = r % 2 != 0;
                var s = yearRows[r];

                ws.Cell(rowNum, 1).Value = s.Year;
                ws.Cell(rowNum, 2).Value = s.PanelName;
                ws.Cell(rowNum, 3).Value = s.TotalClaims;
                ws.Cell(rowNum, 4).Value = s.TotalBilledCharges;
                ws.Cell(rowNum, 5).Value = s.DistinctClaimsWithMissingCpts;
                ws.Cell(rowNum, 6).Value = s.TotalBilledChargesForMissingCpts;
                ws.Cell(rowNum, 7).Value = s.DistinctClaimsWithAdditionalCpts;
                ws.Cell(rowNum, 8).Value = s.TotalBilledChargesForAdditionalCpts;
                ws.Cell(rowNum, 9).Value = s.LostRevenue;
                ws.Cell(rowNum, 10).Value = s.RevenueAtRisk;
                ws.Cell(rowNum, 11).Value = s.NetImpact;

                for (int c = 1; c <= colCount; c++)
                    StyleUiDataCell(ws.Cell(rowNum, c), isAlt);

                StylePanelChip(ws.Cell(rowNum, 2));
                ws.Cell(rowNum, 3).Style.Font.Bold = true;
                StyleMoneyCell(ws.Cell(rowNum, 4), s.TotalBilledCharges);
                StyleMoneyCell(ws.Cell(rowNum, 6), s.TotalBilledChargesForMissingCpts);
                StyleMoneyCell(ws.Cell(rowNum, 8), s.TotalBilledChargesForAdditionalCpts);
                StyleMoneyCell(ws.Cell(rowNum, 9), s.LostRevenue != 0 ? -1 : 0);
                StyleMoneyCell(ws.Cell(rowNum, 10), s.RevenueAtRisk);
                StyleImpactCell(ws.Cell(rowNum, 11), s.NetImpact);

                rowNum++;
            }
        }

        foreach (int c in new[] { 3, 5, 7 }) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 4, 6, 8, 9, 10, 11 }) ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(1);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 8);
    }

    // ── WTD Insights sheet ──────────────────────────────────────────────

    private static void BuildWtdInsightsSheet(XLWorkbook wb, List<CodingWtdInsightRow> rows)
    {
        var ws = wb.AddWorksheet("WTD Insights");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Week", "Panel Name", "Billable CPT Combo", "Total Claims",
            "Total Billed Charges", "Billed CPT Combo", "Missing CPTs",
            "Billed Charges (Missing)", "Revenue Loss",
            "Additional CPTs", "Billed Charges (Additional)", "Potential Recoupment", "Net Impact"
        ];
        int colCount = headers.Length;

        WriteUiTitleBar(ws, 1, colCount, "WTD Coding Insights");

        var weeks = rows.Select(r => r.WeekFolder).Distinct().OrderByDescending(w => w).ToList();
        int rowNum = 2;

        foreach (var week in weeks)
        {
            var weekRows = rows.Where(r => r.WeekFolder == week).ToList();

            WriteUiGroupRow(ws, rowNum, colCount, $"{week}   ({weekRows.Count} panel{(weekRows.Count != 1 ? "s" : "")})");
            rowNum++;
            WriteUiHeaderRow(ws, rowNum, headers);
            rowNum++;

            for (int r = 0; r < weekRows.Count; r++)
            {
                bool isAlt = r % 2 != 0;
                var i = weekRows[r];

                ws.Cell(rowNum, 1).Value = i.WeekFolder;
                ws.Cell(rowNum, 2).Value = i.PanelName;
                ws.Cell(rowNum, 3).Value = i.BillableCptCombo;
                ws.Cell(rowNum, 4).Value = i.TotalClaims;
                ws.Cell(rowNum, 5).Value = i.TotalBilledCharges;
                ws.Cell(rowNum, 6).Value = i.BilledCptCombo;
                ws.Cell(rowNum, 7).Value = i.MissingCpts;
                ws.Cell(rowNum, 8).Value = i.BilledChargesForMissingCpts;
                ws.Cell(rowNum, 9).Value = i.RevenueLoss;
                ws.Cell(rowNum, 10).Value = i.AdditionalCpts;
                ws.Cell(rowNum, 11).Value = i.BilledChargesForAdditionalCpts;
                ws.Cell(rowNum, 12).Value = i.PotentialRecoupment;
                ws.Cell(rowNum, 13).Value = i.NetImpact;

                for (int c = 1; c <= colCount; c++)
                    StyleUiDataCell(ws.Cell(rowNum, c), isAlt);

                StylePanelChip(ws.Cell(rowNum, 2));
                StyleCptCell(ws.Cell(rowNum, 3));
                StyleCptCell(ws.Cell(rowNum, 6));
                StyleCptCell(ws.Cell(rowNum, 7));
                StyleCptCell(ws.Cell(rowNum, 10));
                ws.Cell(rowNum, 4).Style.Font.Bold = true;
                StyleMoneyCell(ws.Cell(rowNum, 5), i.TotalBilledCharges);
                StyleMoneyCell(ws.Cell(rowNum, 8), i.BilledChargesForMissingCpts);
                StyleMoneyCell(ws.Cell(rowNum, 9), i.RevenueLoss != 0 ? -1 : 0);
                StyleMoneyCell(ws.Cell(rowNum, 11), i.BilledChargesForAdditionalCpts);
                StyleMoneyCell(ws.Cell(rowNum, 12), i.PotentialRecoupment);
                StyleImpactCell(ws.Cell(rowNum, 13), i.NetImpact);

                rowNum++;
            }
        }

        ws.Column(4).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 5, 8, 9, 11, 12, 13 })
            ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(1);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 16);
    }

    // ── WTD Summary sheet ───────────────────────────────────────────────

    private static void BuildWtdSummarySheet(XLWorkbook wb, List<CodingWtdSummaryRow> rows)
    {
        var ws = wb.AddWorksheet("WTD Summary");
        ws.TabColor = ExcelTheme.TabGreen;
        ExcelTheme.ApplyDefaults(ws);

        // CPT-combination columns are intentionally omitted - they are surfaced
        // in the WTD Insights sheet (per-combination breakdown).
        string[] headers =
        [
            "Week", "Panel",
            "Total No. of Claims", "Distinct claims with Missing CPTs",
            "Total Billed Charges for Missing CPTs", "Avg Allowed Amount for Missing CPTs"
        ];
        int colCount = headers.Length;

        WriteUiTitleBar(ws, 1, colCount, "WTD Coding Summary");

        var weeks = rows.Select(r => r.WeekFolder).Distinct().OrderByDescending(w => w).ToList();
        int rowNum = 2;

        foreach (var week in weeks)
        {
            // Blank spacer row between groups (except the first)
            if (rowNum > 2) rowNum++;

            // Repeat header row per week section
            WriteUiHeaderRow(ws, rowNum, headers);
            rowNum++;

            var weekRows = rows.Where(r => r.WeekFolder == week).ToList();
            for (int r = 0; r < weekRows.Count; r++)
            {
                bool isAlt = r % 2 != 0;
                var s = weekRows[r];

                ws.Cell(rowNum, 1).Value = s.WeekFolder;
                ws.Cell(rowNum, 2).Value = s.PanelName;
                ws.Cell(rowNum, 3).Value = s.TotalClaims;
                ws.Cell(rowNum, 4).Value = s.DistinctClaimsWithMissingCpts;
                ws.Cell(rowNum, 5).Value = s.TotalBilledChargesForMissingCpts;
                ws.Cell(rowNum, 6).Value = s.AvgAllowedAmountForMissingCpts;

                for (int c = 1; c <= colCount; c++)
                    StyleUiDataCell(ws.Cell(rowNum, c), isAlt);

                StylePanelChip(ws.Cell(rowNum, 2));
                ws.Cell(rowNum, 3).Style.Font.Bold = true;
                StyleMoneyCell(ws.Cell(rowNum, 5), s.TotalBilledChargesForMissingCpts);
                StyleMoneyCell(ws.Cell(rowNum, 6), s.AvgAllowedAmountForMissingCpts);

                rowNum++;
            }
        }

        foreach (int c in new[] { 3, 4 }) ws.Column(c).Style.NumberFormat.Format = "#,##0";
        foreach (int c in new[] { 5, 6 }) ws.Column(c).Style.NumberFormat.Format = "$#,##0.00";

        ws.SheetView.FreezeRows(1);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 22);
    }

    // ── Validation Detail sheet ─────────────────────────────────────────

    private static void BuildValidationDetailSheet(XLWorkbook wb, List<CodingValidationDetailRow> rows)
    {
        var ws = wb.AddWorksheet("Validation Detail");
        ws.TabColor = ExcelTheme.TabGold;
        ExcelTheme.ApplyDefaults(ws);

        string[] headers =
        [
            "Week", "Accession No", "Panel Name", "Date of Service",
            "Actual CPT", "Expected CPT", "Missing CPTs", "Additional CPTs",
            "Status", "Total Charge", "Missing CPT Charges", "Additional CPT Charges", "Remarks"
        ];
        int colCount = headers.Length;

        WriteUiTitleBar(ws, 1, colCount, "Coding Validation Detail");
        WriteUiHeaderRow(ws, 2, headers);

        for (int r = 0; r < rows.Count; r++)
        {
            int rowNum = r + 3;
            bool isAlt = r % 2 != 0;
            var d = rows[r];

            ws.Cell(rowNum, 1).Value = d.WeekFolder;
            ws.Cell(rowNum, 2).Value = d.AccessionNo;
            ws.Cell(rowNum, 3).Value = d.PanelName;
            ws.Cell(rowNum, 4).Value = d.DateofService;
            ws.Cell(rowNum, 5).Value = d.ActualCPTCode;
            ws.Cell(rowNum, 6).Value = d.ExpectedCPTCode;
            ws.Cell(rowNum, 7).Value = d.MissingCPTCodes;
            ws.Cell(rowNum, 8).Value = d.AdditionalCPTCodes;
            ws.Cell(rowNum, 9).Value = d.ValidationStatus;
            ws.Cell(rowNum, 10).Value = d.TotalCharge;
            ws.Cell(rowNum, 11).Value = d.MissingCPT_Charges;
            ws.Cell(rowNum, 12).Value = d.AdditionalCPT_Charges;
            ws.Cell(rowNum, 13).Value = d.Remarks;

            for (int c = 1; c <= colCount; c++)
                StyleUiDataCell(ws.Cell(rowNum, c), isAlt);

            StylePanelChip(ws.Cell(rowNum, 3));
            StyleCptCell(ws.Cell(rowNum, 5));
            StyleCptCell(ws.Cell(rowNum, 6));
            StyleCptCell(ws.Cell(rowNum, 7));
            StyleCptCell(ws.Cell(rowNum, 8));
            StyleStatusCell(ws.Cell(rowNum, 9), d.ValidationStatus);
        }

        ws.SheetView.FreezeRows(2);
        ExcelTheme.AutoFitColumns(ws, colCount, minWidth: 14, firstColMinWidth: 14);
    }
}
