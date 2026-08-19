using ClosedXML.Excel;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Coding Summary "Calculation Logic" sheet template.
///
/// Every Excel download copies this template into the workbook.
/// Physical file (preferred, editable without a rebuild):
///   Templates/CodingSummary_CalculationLogic.xlsx
/// If that file is missing, the embedded layout below is used and the xlsx
/// is written so later downloads reuse the file.
/// </summary>
public static class CodingCalculationLogicTemplate
{
    public const string SheetName = "Calculation Logic";
    public const string TemplateFileName = "CodingSummary_CalculationLogic.xlsx";

    /// <summary>
    /// Adds / replaces the Calculation Logic sheet on every download.
    /// The sheet is always written in-process. An external xlsx is only used
    /// when its first sheet is actually a Calculation Logic template (A1 title).
    /// Copying a full Coding Summary workbook as the "template" is ignored.
    /// </summary>
    public static void AddToWorkbook(XLWorkbook wb, string? configuredPath = null)
    {
        if (wb.Worksheets.Contains(SheetName))
            wb.Worksheet(SheetName).Delete();

        BuildEmbeddedSheet(wb);

        var templatePath = ResolveTemplatePath(configuredPath);
        if (!string.IsNullOrWhiteSpace(templatePath) && File.Exists(templatePath))
            TryOverlayFromTemplate(wb, templatePath);

        if (wb.Worksheets.Contains(SheetName))
            wb.Worksheet(SheetName).Position = 2;
    }

    /// <summary>
    /// Replaces the embedded sheet only when the file looks like the logic
    /// template (title contains "Calculation Logic"). A KPI Dashboard / full
    /// export saved as the template path must not become this tab.
    /// </summary>
    private static void TryOverlayFromTemplate(XLWorkbook wb, string templatePath)
    {
        try
        {
            using var templateWb = new XLWorkbook(templatePath);
            var src = templateWb.Worksheets.First();
            var title = src.Cell(1, 1).GetString();
            if (string.IsNullOrWhiteSpace(title)
                || title.IndexOf("Calculation Logic", StringComparison.OrdinalIgnoreCase) < 0)
                return;

            if (wb.Worksheets.Contains(SheetName))
                wb.Worksheet(SheetName).Delete();
            src.CopyTo(wb, SheetName);
        }
        catch
        {
            if (!wb.Worksheets.Contains(SheetName))
                BuildEmbeddedSheet(wb);
        }
    }

    /// <summary>Writes the default template xlsx (used to seed Templates/).</summary>
    public static void WriteTemplateFile(string path)
    {
        using var wb = new XLWorkbook();
        BuildEmbeddedSheet(wb);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        wb.SaveAs(path);
    }

    private static string? ResolveTemplatePath(string? configuredPath)
    {
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(configuredPath))
            candidates.Add(configuredPath.Trim());

        candidates.Add(Path.Combine(AppContext.BaseDirectory, "Templates", TemplateFileName));
        candidates.Add(Path.Combine(AppContext.BaseDirectory, TemplateFileName));
        candidates.Add(Path.Combine(Directory.GetCurrentDirectory(), "Templates", TemplateFileName));

        return candidates.FirstOrDefault(File.Exists);
    }

    private static void BuildEmbeddedSheet(XLWorkbook wb)
    {
        var ws = wb.Worksheets.Contains(SheetName)
            ? wb.Worksheet(SheetName)
            : wb.AddWorksheet(SheetName);

        ws.TabColor = ExcelTheme.TabGold;
        ExcelTheme.ApplyDefaults(ws);
        ws.ShowGridLines = false;

        ws.Column(1).Width = 38;
        ws.Column(2).Width = 72;
        ws.Column(3).Width = 42;
        ws.Column(4).Width = 28;

        int row = 1;
        ExcelTheme.WriteTitleBar(ws, row, 4, "Coding Summary — Calculation Logic");
        ws.Row(row).Height = 28;
        row++;

        ws.Range(row, 1, row, 4).Merge();
        ws.Cell(row, 1).Value =
            "Source table: dbo.CodingValidation. Claim buckets use Validation Status (CPT codes present), not Missing/Additional CPT charge > 0.";
        ws.Cell(row, 1).Style.Font.Italic = true;
        ws.Cell(row, 1).Style.Font.FontColor = XLColor.FromHtml("#44546A");
        ws.Row(row).Height = 22;
        row += 2;

        row = WriteSection(ws, row, "1. Validation Status (claim classification)");
        row = WriteHeader(ws, row, "Status", "When it applies", "Used in");
        row = WriteData(ws, row, "Missing CPTs",
            "Missing CPT codes present AND no additional CPT codes",
            "Revenue Loss, Detail: Missing only, Total Error");
        row = WriteData(ws, row, "Additional CPTs coded",
            "Additional CPT codes present AND no missing CPT codes",
            "Revenue at Risk, Detail: Additional only");
        row = WriteData(ws, row, "Both Missing and Additional CPTs identified",
            "Missing CPT codes AND additional CPT codes present",
            "Revenue Loss AND Revenue at Risk, Detail: Both, Total Error");
        row = WriteData(ws, row, "No Deviation found",
            "No missing and no additional CPT codes",
            "Excluded from Loss / At Risk / Error");
        row += 2;

        row = WriteSection(ws, row, "2. REVENUE LOSS  (claims with issues producing leakage)");
        row = WriteHeader(ws, row, "Metric", "Formula", "SQL");
        row = WriteData(ws, row, "Total No. of Claims",
            "COUNT of rows where Status IN (Missing CPTs, Both…)",
            "COUNT(*) WHERE ValidationStatus IN ('Missing CPTs','Both Missing and Additional CPTs identified')");
        row = WriteData(ws, row, "Total Actual Billed Charges",
            "SUM(TotalCharge) on those same rows",
            "SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2))) — same WHERE");
        row = WriteData(ws, row, "Potential Loss in Revenue",
            "SUM(MissingCPT_AvgPaidAmount) on those same rows  [Paid basis]",
            "SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2))) — same WHERE");
        row += 2;

        row = WriteSection(ws, row, "3. REVENUE AT RISK  (recoverable value pending resolution)");
        row = WriteHeader(ws, row, "Metric", "Formula", "SQL");
        row = WriteData(ws, row, "Total No. of Claims",
            "COUNT of rows where Status IN (Additional CPTs coded, Both…)",
            "COUNT(*) WHERE ValidationStatus IN ('Additional CPTs coded','Both Missing and Additional CPTs identified')");
        row = WriteData(ws, row, "Total Actual Billed Charges",
            "SUM(TotalCharge) on those same rows",
            "SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2))) — same WHERE");
        row = WriteData(ws, row, "Potential Recoupment",
            "SUM(AdditionalCPT_AvgPaidAmount) on those same rows  [Paid basis]",
            "SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2))) — same WHERE");
        row += 2;

        row = WriteSection(ws, row, "4. Detail Breakdown");
        row = WriteHeader(ws, row, "Metric", "Formula", "SQL");
        row = WriteData(ws, row, "Total Claims",
            "All CodingValidation rows (skip blank Accession / TOTAL row)",
            "COUNT(*) WHERE ISNULL(AccessionNo,'') <> ''");
        row = WriteData(ws, row, "Claims with Missing CPTs",
            "Status = Missing CPTs  (missing-only, not Both)",
            "COUNT(*) WHERE ValidationStatus = 'Missing CPTs'");
        row = WriteData(ws, row, "Claims with Additional CPTs",
            "Status = Additional CPTs coded  (additional-only, not Both)",
            "COUNT(*) WHERE ValidationStatus = 'Additional CPTs coded'");
        row = WriteData(ws, row, "Claims with Missing & Additional CPTs",
            "Status = Both Missing and Additional CPTs identified",
            "COUNT(*) WHERE ValidationStatus = 'Both Missing and Additional CPTs identified'");
        row = WriteData(ws, row, "Total Error Claims",
            "Missing only + Both  (same set as Revenue Loss claims)",
            "COUNT(*) WHERE ValidationStatus IN ('Missing CPTs','Both Missing and Additional CPTs identified')");
        row = WriteData(ws, row, "Compliance Rate %",
            "(Total Claims − Claims with Issues) / Total Claims × 100. Issues = Missing + Additional + Both",
            "ROUND( (TotalClaims - IssueClaims) * 100.0 / NULLIF(TotalClaims,0) , 2)");
        row += 2;

        row = WriteSection(ws, row, "5. YTD / WTD Insights & Summary (KPI tables — Allowed basis)");
        row = WriteHeader(ws, row, "Metric", "Formula", "SQL / notes");
        row = WriteData(ws, row, "Lost Revenue / Revenue Loss",
            "SUM(MissingCPT_AvgAllowedAmount)  [Allowed basis, template v1.4]",
            "Stored in CodingAgg_* via usp_RefreshCodingAggregates");
        row = WriteData(ws, row, "Revenue at Risk / Potential Recoupment",
            "SUM(AdditionalCPT_AvgAllowedAmount)  [Allowed basis, template v1.4]",
            "Stored in CodingAgg_* via usp_RefreshCodingAggregates");
        row = WriteData(ws, row, "Net Impact",
            "Revenue at Risk − Lost Revenue",
            "Same sign on YTD and WTD");
        row = WriteData(ws, row, "Claim count in aggregates",
            "COUNT(DISTINCT VisitNumber)",
            "YTD = billed dates before WTD window; WTD = latest 2 Fri→Thu weeks on FirstBillDate");
        row += 2;

        row = WriteSection(ws, row, "6. Average Paid amount (missing / additional CPT pricing)");
        row = WriteHeader(ws, row, "Step", "Rule", "Notes");
        row = WriteData(ws, row, "1", "Use Rolling90 Avg Paid if the value is not 0", "Preferred window");
        row = WriteData(ws, row, "2", "Else use Rolling120 Avg Paid if the value is not 0", "91–120 day bucket on new files");
        row = WriteData(ws, row, "3", "Else use Rolling180 Avg Paid if the value is not 0", "Existing files still tag 91–180 as Rolling180");
        row = WriteData(ws, row, "4", "Else use YTD Avg Paid", "Last fallback");
        row += 2;

        row = WriteSection(ws, row, "7. What this is NOT");
        row = WriteHeader(ws, row, "Do not use", "Why", "");
        row = WriteData(ws, row, "Missing CPT (Charge) > 0 / Additional CPT (Charges) > 0",
            "That old split produced 25,404 At-Risk claims instead of client 26,482",
            "Charge can be 0 while Validation Status is still Additional / Both");
        row = WriteData(ws, row, "COUNT(DISTINCT VisitNumber) on the Financial Dashboard card",
            "KPI card / Excel Financial Dashboard uses row COUNT(*) to match the client sheet",
            "YTD/WTD aggregate tables still use DISTINCT VisitNumber");

        ws.Range(1, 1, row, 4).Style.Alignment.WrapText = true;
        ws.SheetView.FreezeRows(1);
        ws.PageSetup.PagesWide = 1;
        ws.PageSetup.PageOrientation = XLPageOrientation.Landscape;
        ws.PageSetup.FitToPages(1, 0);
    }

    private static int WriteSection(IXLWorksheet ws, int row, string title)
    {
        ws.Range(row, 1, row, 4).Merge();
        var cell = ws.Cell(row, 1);
        cell.Value = title;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = 12;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(row).Height = 22;
        return row + 1;
    }

    private static int WriteHeader(IXLWorksheet ws, int row, string c1, string c2, string c3)
    {
        ws.Cell(row, 1).Value = c1;
        ws.Cell(row, 2).Value = c2;
        ws.Cell(row, 3).Value = c3;
        ws.Range(row, 1, row, 4).Style.Font.Bold = true;
        ws.Range(row, 1, row, 4).Style.Fill.BackgroundColor = ExcelTheme.GroupRowBg;
        ws.Range(row, 1, row, 4).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        ws.Range(row, 1, row, 4).Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        return row + 1;
    }

    private static int WriteData(IXLWorksheet ws, int row, string c1, string c2, string c3)
    {
        ws.Cell(row, 1).Value = c1;
        ws.Cell(row, 2).Value = c2;
        ws.Cell(row, 3).Value = c3;
        var bg = row % 2 == 0 ? ExcelTheme.BandedRowBg : XLColor.White;
        ws.Range(row, 1, row, 4).Style.Fill.BackgroundColor = bg;
        ws.Range(row, 1, row, 4).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        ws.Range(row, 1, row, 4).Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        ws.Range(row, 1, row, 4).Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
        ws.Row(row).Height = 36;
        return row + 1;
    }
}
