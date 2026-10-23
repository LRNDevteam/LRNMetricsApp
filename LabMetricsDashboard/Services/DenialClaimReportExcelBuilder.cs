using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds the Denial Claim Report workbook: Monthly Summary, Weekly Summary and Denial Insight,
/// one sheet each.
///
/// <para>The sheets carry the page's own colours rather than a plain export palette - the dark blue
/// pivot bands with the amber Grand Total, and the insight grid's green/gold/red header groups with
/// the workbook's category fills. Someone who works from the screen and someone who works from the
/// file are reading the same document, and a category that is amber on screen has to be amber here
/// or the colour stops carrying meaning.</para>
/// </summary>
public static class DenialClaimReportExcelBuilder
{
    // Pivot palette - matches denial_dashboard.css.
    private static readonly XLColor PivotHeader = XLColor.FromHtml("#123B63");
    private static readonly XLColor PivotPeriod = XLColor.FromHtml("#1C5486");
    private static readonly XLColor PivotGrandTotal = XLColor.FromHtml("#92400E");
    private static readonly XLColor PivotInsuranceRow = XLColor.FromHtml("#EAF3EA");
    private static readonly XLColor PivotFooter = XLColor.FromHtml("#0F2E4C");

    // Insight palette - matches denial_claim_report.css and the client's own workbook. The header
    // group fills live in DenialInsightTemplate, alongside the column layout they colour.
    private static readonly XLColor InsightHeader = DenialInsightTemplate.HeaderGreen;
    private static readonly XLColor ImpactTint = XLColor.FromHtml("#FDF8EC");
    private static readonly XLColor ClosedTint = XLColor.FromHtml("#F2F9F4");
    private static readonly XLColor WeekDivider = XLColor.FromHtml("#EEF3F8");

    private static readonly XLColor Rule = XLColor.FromHtml("#D5E1EF");
    private static readonly XLColor Ink = XLColor.FromHtml("#1F2D3D");

    private const string Money = "$#,##0.00";
    private const string Whole = "#,##0";

    /// <summary>
    /// Periods across each pivot. Monthly shows every month the lab has denials in - with the
    /// Other Periods column gone, capping it at twelve left older claims out of the Grand Total,
    /// which then disagreed with the Denied Claims tile. Weekly is the last four weeks, per the
    /// reporting spec.
    /// </summary>
    public const int MonthlyPeriods = int.MaxValue;
    public const int WeeklyPeriods = 4;

    /// <summary>The sheet holding the denied claims themselves, after the three summary sheets.</summary>
    public const string ClaimLevelSheetName = "Denial Claim Level";

    /// <summary>
    /// Everything the workbook's summary sheets show, read the same way the page reads it. Shared
    /// by the page's direct download and LRN.ReportWorker, so the two files cannot drift apart.
    /// </summary>
    public static async Task<DenialClaimReportViewModel> LoadAsync(
        IDenialClaimReportRepository repo,
        string connectionString,
        string labName,
        string? bucket,
        DayOfWeek weekStartsOn,
        string? dateColumn,
        string? balanceColumn,
        CancellationToken ct)
    {
        var model = await LoadSummaryAsync(repo, connectionString, labName, weekStartsOn, dateColumn, balanceColumn, ct);
        model.Insight.Bucket = DenialInsightBuckets.Normalize(bucket);

        model.Insight.Rows = await repo.GetInsightsAsync(connectionString, model.Insight.Bucket, ct);

        // Same SPs the page's Denial List / Plan Type tabs read.
        if (LabCollectionPrefix.HasDenialSummary(labName))
        {
            var lists = new SqlDenialSummaryRepository();
            var prefix = LabCollectionPrefix.GetPrefix(labName);
            model.HasDenialLists = true;
            model.HasDenialPlanType = LabCollectionPrefix.HasDenialPlanType(labName);
            model.DenialList = await lists.GetDenialListAsync(connectionString, prefix, new DenialSummaryFilters(), ct);
            if (model.HasDenialPlanType)
                model.PlanType = await lists.GetPlanTypeAsync(connectionString, prefix, new DenialSummaryFilters(), ct);

            if (LabCollectionPrefix.HasDenialFacilityTabs(labName))
            {
                model.HasDenialFacilityTabs = true;
                model.PayorVsPayer = await lists.GetPayorVsPayerAsync(connectionString, prefix, new DenialSummaryFilters(), ct);
                model.FacilityDenial = await lists.GetByFacilityAsync(connectionString, prefix, new DenialSummaryFilters(), ct);
                model.FacilityPct = await lists.GetFacilityPctAsync(connectionString, prefix, new DenialSummaryFilters(), ct);
            }
        }

        return model;
    }

    /// <summary>
    /// Tiles, Monthly and Weekly only, read the same way the page reads them: the lab's
    /// usp_Get{prefix}_Denial* SPs when it has them, else the inline ClaimLevelData summary.
    /// </summary>
    public static async Task<DenialClaimReportViewModel> LoadSummaryAsync(
        IDenialClaimReportRepository repo,
        string connectionString,
        string labName,
        DayOfWeek weekStartsOn,
        string? dateColumn,
        string? balanceColumn,
        CancellationToken ct)
    {
        var model = new DenialClaimReportViewModel
        {
            CurrentLab = labName,
            Insight = new DenialInsightPanelViewModel
            {
                CurrentLab = labName,
                Bucket = DenialInsightBuckets.Normalize(null)
            }
        };

        var weekRange = await repo.GetClaimDataWeekRangeAsync(connectionString, ct);
        model.WeekRange = weekRange.WeekFolder;
        model.RunId = weekRange.RunId;

        if (LabCollectionPrefix.HasDenialSummary(labName))
        {
            // Same SPs as the page: tiles, Monthly and Weekly from the ingest aggregate tables.
            await DenialSummarySpPivot.LoadAsync(new SqlDenialSummaryRepository(), connectionString,
                LabCollectionPrefix.GetPrefix(labName), model, ct);
        }
        else
        {
            var groups = await repo.GetDenialSummaryAsync(connectionString, dateColumn, balanceColumn, ct);

            model.TotalClaims = groups.Sum(g => g.ClaimCount);
            model.TotalInsuranceBalance = groups.Sum(g => g.InsuranceBalance);

            // Same clamp as the page, so the file and the screen agree on the columns.
            model.Monthly = DenialClaimPivotBuilder.Build(groups, weekly: false, MonthlyPeriods, loadedThrough: weekRange.LoadedThrough);
            model.Weekly = DenialClaimPivotBuilder.Build(groups, weekly: true, WeeklyPeriods, loadedThrough: weekRange.LoadedThrough, weekStartsOn: weekStartsOn);
        }

        return model;
    }

    /// <summary>Monthly Summary and Weekly Summary sheets only.</summary>
    public static XLWorkbook BuildSummary(DenialClaimReportViewModel model)
    {
        var workbook = new XLWorkbook();
        WritePivot(workbook.Worksheets.Add("Monthly Summary"), model.Monthly, "Monthly Summary", model.CurrentLab);
        WritePivot(workbook.Worksheets.Add("Weekly Summary"), model.Weekly, "Weekly Summary", model.CurrentLab);
        return workbook;
    }

    public static XLWorkbook Build(DenialClaimReportViewModel model)
    {
        var workbook = new XLWorkbook();

        WritePivot(workbook.Worksheets.Add("Monthly Summary"), model.Monthly, "Monthly Summary", model.CurrentLab);
        WritePivot(workbook.Worksheets.Add("Weekly Summary"), model.Weekly, "Weekly Summary", model.CurrentLab);
        if (model.HasDenialLists)
        {
            WriteDenialList(workbook.Worksheets.Add("Denial List"), model.DenialList, model.CurrentLab, model.HasDenialFacilityTabs);
            if (model.HasDenialPlanType)
                WritePlanType(workbook.Worksheets.Add(model.HasDenialFacilityTabs ? "Plan Type" : "Denial List - Plan Type"),
                    model.PlanType, model.CurrentLab, model.HasDenialFacilityTabs);
        }
        if (model.HasDenialFacilityTabs)
        {
            WritePanelVsPayer(workbook.Worksheets.Add("Panel vs Payer"), model.PayorVsPayer, model.CurrentLab);
            WriteFacility(workbook.Worksheets.Add("Facility wise Denial"), model.FacilityDenial, model.CurrentLab);
            WriteFacilityPct(workbook.Worksheets.Add("Denial vs Facility %"), model.FacilityPct, model.CurrentLab);
        }
        WriteInsight(workbook.Worksheets.Add("Denial Insight"), model.Insight, model.CurrentLab);

        return workbook;
    }

    // ── Denial List / Plan Type ───────────────────────────────────────────────

    // NorthWest (the labs with the facility tabs) reports DenialCodeNormalized, sorted by Claim Count.
    private static string DenialFilterCaption(bool normalized) => normalized
        ? "DenialCodeNormalized not blank and InsuranceBalance > 0"
        : "Total Insurance Balance > 0 and Denial Code not blank";

    private static void WriteDenialList(IXLWorksheet ws, IReadOnlyList<DenialListRow> rows, string lab, bool normalized)
    {
        var data = rows.Where(r => r.RowType != "T")
            .Select(r => (Label: r.RowType == "D" ? r.DenialCode : r.PayerName, IsParent: r.RowType == "D", r.ClaimCount, r.TotalInsuranceBalance))
            .ToList();
        var total = rows.FirstOrDefault(r => r.RowType == "T");
        WriteSimpleList(ws, $"{lab} — Denial List",
            normalized
                ? $"{DenialFilterCaption(true)} | DenialCodeNormalized, drill down to Insurance | Sorted by Claim Count DESC"
                : $"{DenialFilterCaption(false)} | Denial Code, drill down to Insurance | Sorted by Total Insurance Balance DESC",
            "Denial Code / Insurance", data, total?.ClaimCount ?? 0, total?.TotalInsuranceBalance ?? 0m);
    }

    private static void WritePlanType(IXLWorksheet ws, IReadOnlyList<DenialPlanTypeRow> rows, string lab, bool normalized)
    {
        var data = rows.Where(r => r.RowType != "T")
            .Select(r => (Label: r.PayerType, IsParent: true, r.ClaimCount, r.TotalInsuranceBalance))
            .ToList();
        var total = rows.FirstOrDefault(r => r.RowType == "T");
        WriteSimpleList(ws, $"{lab} — {(normalized ? "Plan Type" : "Denial List - Plan Type")}",
            $"{DenialFilterCaption(normalized)} | Sorted by {(normalized ? "Claim Count" : "Total Insurance Balance")} DESC",
            "Payer Type", data, total?.ClaimCount ?? 0, total?.TotalInsuranceBalance ?? 0m);
    }

    // ── NorthWest: Facility wise Denial / Denial vs Facility % / Panel vs Payer ──

    private static void WriteFacility(IXLWorksheet ws, IReadOnlyList<DenialFacilityRow> rows, string lab)
    {
        var data = rows.Where(r => r.RowType != "T")
            .Select(r => (Label: r.RowType == "F" ? r.ClinicName : r.DenialCode, IsParent: r.RowType == "F", r.ClaimCount, r.TotalInsuranceBalance))
            .ToList();
        var total = rows.FirstOrDefault(r => r.RowType == "T");
        WriteSimpleList(ws, $"{lab} — Facility wise Denial Breakdown",
            $"{DenialFilterCaption(true)} | ClinicName, drill down to DenialCodeNormalized | Sorted by Claim Count DESC",
            "Clinic Name / Denial Code", data, total?.ClaimCount ?? 0, total?.TotalInsuranceBalance ?? 0m);
    }

    private static void WriteFacilityPct(IXLWorksheet ws, IReadOnlyList<DenialFacilityPctRow> rows, string lab)
    {
        WriteTitle(ws, $"{lab} — Denial vs Facility %",
            "BilledUnbilled = Billed | ClinicName | Denied % = Denied Claims / Adjudicated Claims | Sorted by No. of Claims Billed DESC");

        var data = rows.Where(r => r.RowType != "T").OrderBy(r => r.SortOrder).ToList();
        if (data.Count == 0)
        {
            WriteEmpty(ws);
            return;
        }

        const int headerRow = 4;
        string[] headers = ["Clinic Name", "No. of Claims Billed", "No. of Adjudicated Claims", "No. of Denied Claims", "Denied %"];
        for (var c = 0; c < headers.Length; c++)
            ws.Cell(headerRow, c + 1).Value = headers[c];
        StyleHeader(ws.Range(headerRow, 1, headerRow, headers.Length));

        var row = headerRow + 1;
        void Write(string clinic, DenialFacilityPctRow r)
        {
            ws.Cell(row, 1).Value = clinic;
            ws.Cell(row, 2).Value = r.ClaimsBilled;
            ws.Cell(row, 3).Value = r.AdjudicatedClaims;
            ws.Cell(row, 4).Value = r.DeniedClaims;
            ws.Cell(row, 5).Value = r.DeniedPct;
        }
        foreach (var r in data)
        {
            Write(r.ClinicName, r);
            row++;
        }
        if (rows.FirstOrDefault(r => r.RowType == "T") is { } total)
        {
            Write("Grand Total", total);
            StyleFooter(ws.Range(row, 1, row, headers.Length));
        }
        else row--;

        ws.Range(headerRow + 1, 2, row, 4).Style.NumberFormat.SetFormat(Whole);
        ws.Range(headerRow + 1, 5, row, 5).Style.NumberFormat.SetFormat("0.00%");
        StyleBody(ws.Range(headerRow, 1, row, headers.Length));

        ws.Column(1).Width = 52;
        for (var c = 2; c <= headers.Length; c++) ws.Column(c).Width = 18;
        ws.SheetView.Freeze(headerRow, 1);
    }

    /// <summary>
    /// Panel vs Payer: payer rows, their denial codes grouped under them (Excel +/- on the payer
    /// row), and No. of Claims / Insurance Balance per PanelType plus a Grand Total pair.
    /// </summary>
    private static void WritePanelVsPayer(IXLWorksheet ws, IReadOnlyList<DenialPayorVsPayerRow> rows, string lab)
    {
        WriteTitle(ws, $"{lab} — Panel vs Payer",
            $"{DenialFilterCaption(true)} | Payer Name_Raw, drill down to DenialCodeNormalized | Columns: PanelType | Sorted by Claim Count DESC");

        var panels = rows
            .Where(r => r.RowType == "T" && r.PanelType != "")
            .OrderByDescending(r => r.ClaimCount)
            .ThenBy(r => r.PanelType, StringComparer.OrdinalIgnoreCase)
            .Select(r => r.PanelType)
            .ToList();
        var lines = rows
            .GroupBy(r => r.SortOrder)
            .OrderBy(g => g.Key)
            .Select(g => (Total: g.FirstOrDefault(r => r.PanelType == "") ?? g.First(),
                          Cells: g.Where(r => r.PanelType != "").ToDictionary(r => r.PanelType, StringComparer.OrdinalIgnoreCase)))
            .ToList();
        if (lines.Count == 0)
        {
            WriteEmpty(ws);
            return;
        }

        const int bandRow = 4, headerRow = 5;
        var lastCol = 1 + (panels.Count + 1) * 2;
        ws.Range(bandRow, 1, headerRow, 1).Merge().Value = "Payer Name / Denial Code";
        for (var i = 0; i <= panels.Count; i++)
        {
            var col = 2 + i * 2;
            ws.Range(bandRow, col, bandRow, col + 1).Merge().Value = i < panels.Count ? panels[i] : "Grand Total";
            ws.Cell(headerRow, col).Value = "No. of Claims";
            ws.Cell(headerRow, col + 1).Value = "Insurance Balance";
        }
        StyleHeader(ws.Range(bandRow, 1, headerRow, lastCol));
        ws.Range(bandRow, lastCol - 1, headerRow, lastCol).Style.Fill.BackgroundColor = PivotGrandTotal;
        ws.Range(bandRow, 1, headerRow, lastCol).Style.Alignment.WrapText = true;

        var row = headerRow + 1;
        void WriteCells(DenialPayorVsPayerRow total, IReadOnlyDictionary<string, DenialPayorVsPayerRow> cells)
        {
            for (var i = 0; i < panels.Count; i++)
            {
                var cell = cells.GetValueOrDefault(panels[i]);
                ws.Cell(row, 2 + i * 2).Value = cell?.ClaimCount ?? 0;
                ws.Cell(row, 3 + i * 2).Value = cell?.TotalInsuranceBalance ?? 0m;
            }
            ws.Cell(row, lastCol - 1).Value = total.ClaimCount;
            ws.Cell(row, lastCol).Value = total.TotalInsuranceBalance;
        }

        foreach (var (total, cells) in lines.Where(l => l.Total.RowType != "T"))
        {
            var isPayer = total.RowType == "P";
            ws.Cell(row, 1).Value = isPayer ? total.PayerName : total.DenialCode;
            WriteCells(total, cells);
            if (isPayer)
            {
                ws.Range(row, 1, row, lastCol).Style.Font.SetBold().Fill.SetBackgroundColor(PivotInsuranceRow);
            }
            else
            {
                ws.Cell(row, 1).Style.Alignment.SetIndent(2);
                ws.Row(row).OutlineLevel = 1;
            }
            row++;
        }
        var grand = lines.FirstOrDefault(l => l.Total.RowType == "T");
        if (grand.Total is not null)
        {
            ws.Cell(row, 1).Value = "Grand Total";
            WriteCells(grand.Total, grand.Cells);
            StyleFooter(ws.Range(row, 1, row, lastCol));
        }
        else row--;

        for (var i = 0; i <= panels.Count; i++)
        {
            ws.Range(headerRow + 1, 2 + i * 2, row, 2 + i * 2).Style.NumberFormat.SetFormat("#,##0;-#,##0;\"-\"");
            ws.Range(headerRow + 1, 3 + i * 2, row, 3 + i * 2).Style.NumberFormat.SetFormat("$#,##0.00;($#,##0.00);\"-\"");
        }
        StyleBody(ws.Range(bandRow, 1, row, lastCol));

        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;
        ws.Column(1).Width = 46;
        for (var i = 0; i <= panels.Count; i++)
        {
            ws.Column(2 + i * 2).Width = 12;
            ws.Column(3 + i * 2).Width = 18;
        }
        ws.SheetView.Freeze(headerRow, 1);
    }

    private static void WriteTitle(IXLWorksheet ws, string title, string caption)
    {
        ws.Cell(1, 1).Value = title;
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(13).Font.SetFontColor(Ink);
        ws.Cell(2, 1).Value = caption;
        ws.Cell(2, 1).Style.Font.SetFontSize(9).Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));
    }

    private static void WriteEmpty(IXLWorksheet ws)
    {
        ws.Cell(4, 1).Value = "No denial data for this lab.";
        ws.Cell(4, 1).Style.Font.SetItalic().Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));
        ws.Column(1).Width = 60;
    }

    private static void StyleHeader(IXLRange header)
    {
        header.Style.Font.Bold = true;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Fill.BackgroundColor = PivotHeader;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
    }

    private static void StyleFooter(IXLRange footer)
    {
        footer.Style.Font.Bold = true;
        footer.Style.Font.FontColor = XLColor.White;
        footer.Style.Fill.BackgroundColor = PivotFooter;
    }

    private static void StyleBody(IXLRange body)
    {
        body.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.OutsideBorderColor = Rule;
        body.Style.Border.InsideBorderColor = Rule;
    }

    private static void WriteSimpleList(
        IXLWorksheet ws, string title, string caption, string labelHeader,
        IReadOnlyList<(string Label, bool IsParent, int ClaimCount, decimal TotalInsuranceBalance)> data,
        int totalClaims, decimal totalBalance)
    {
        ws.Cell(1, 1).Value = title;
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(13).Font.SetFontColor(Ink);
        ws.Cell(2, 1).Value = caption;
        ws.Cell(2, 1).Style.Font.SetFontSize(9).Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));

        if (data.Count == 0)
        {
            ws.Cell(4, 1).Value = "No denial data for this lab.";
            ws.Cell(4, 1).Style.Font.SetItalic().Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));
            ws.Column(1).Width = 60;
            return;
        }

        const int headerRow = 4;
        ws.Cell(headerRow, 1).Value = labelHeader;
        ws.Cell(headerRow, 2).Value = "No. of Claims";
        ws.Cell(headerRow, 3).Value = "Total Insurance Balance";
        var header = ws.Range(headerRow, 1, headerRow, 3);
        header.Style.Font.Bold = true;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Fill.BackgroundColor = PivotHeader;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Cell(headerRow, 3).Style.Fill.BackgroundColor = PivotGrandTotal;

        var row = headerRow + 1;
        foreach (var d in data)
        {
            ws.Cell(row, 1).Value = d.Label;
            ws.Cell(row, 2).Value = d.ClaimCount;
            ws.Cell(row, 3).Value = d.TotalInsuranceBalance;
            if (d.IsParent)
            {
                ws.Range(row, 1, row, 3).Style.Font.SetBold().Fill.SetBackgroundColor(PivotInsuranceRow);
            }
            else
            {
                ws.Cell(row, 1).Style.Alignment.SetIndent(2);
                ws.Row(row).OutlineLevel = 1;
            }
            row++;
        }

        ws.Cell(row, 1).Value = "Grand Total";
        ws.Cell(row, 2).Value = totalClaims;
        ws.Cell(row, 3).Value = totalBalance;
        var footer = ws.Range(row, 1, row, 3);
        footer.Style.Font.Bold = true;
        footer.Style.Font.FontColor = XLColor.White;
        footer.Style.Fill.BackgroundColor = PivotFooter;

        ws.Range(headerRow + 1, 2, row, 2).Style.NumberFormat.SetFormat(Whole);
        ws.Range(headerRow + 1, 3, row, 3).Style.NumberFormat.SetFormat(Money);

        var body = ws.Range(headerRow, 1, row, 3);
        body.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.OutsideBorderColor = Rule;
        body.Style.Border.InsideBorderColor = Rule;

        // Group +/- sits on the parent row, which is above its children.
        ws.Outline.SummaryVLocation = XLOutlineSummaryVLocation.Top;
        ws.Column(1).Width = 52;
        ws.Column(2).Width = 15;
        ws.Column(3).Width = 24;
        ws.SheetView.Freeze(headerRow, 1);
    }

    /// <summary>
    /// Adds the Denial Claim Level sheet from rows already read. Used by the page's direct
    /// download only; LRN.ReportWorker streams this sheet instead, because ClosedXML holds a whole
    /// sheet in memory and a large lab's denied claims would not fit comfortably.
    /// </summary>
    public static void AddClaimLevelSheet(XLWorkbook workbook, System.Data.DataTable? claims)
    {
        var ws = workbook.Worksheets.Add(ClaimLevelSheetName);

        if (claims is null || claims.Columns.Count == 0)
        {
            ws.Cell(1, 1).Value = "This lab has no claim-level denial data.";
            ws.Cell(1, 1).Style.Font.SetItalic().Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));
            ws.Column(1).Width = 60;
            return;
        }

        var table = ws.Cell(1, 1).InsertTable(claims, ClaimLevelSheetName.Replace(" ", string.Empty), createTable: true);
        table.Theme = XLTableTheme.TableStyleLight9;

        for (var c = 1; c <= claims.Columns.Count; c++)
        {
            if (LabClaimLineColumnCatalog.IsMoneyColumn(claims.Columns[c - 1].ColumnName))
                ws.Column(c).Style.NumberFormat.SetFormat(Money);
        }

        ws.Columns(1, claims.Columns.Count).AdjustToContents(1, Math.Min(claims.Rows.Count + 1, 500));
        foreach (var column in ws.Columns(1, claims.Columns.Count))
            column.Width = Math.Clamp(column.Width, 10, 45);

        ws.SheetView.FreezeRows(1);
    }

    // ── Monthly / Weekly ──────────────────────────────────────────────────────

    private static void WritePivot(IXLWorksheet ws, BreakdownPivotViewModel pivot, string title, string lab)
    {
        ws.Cell(1, 1).Value = $"{lab} — {title}";
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(13).Font.SetFontColor(Ink);

        if (!pivot.HasData)
        {
            ws.Cell(3, 1).Value = "No denial data for this lab.";
            ws.Cell(3, 1).Style.Font.SetItalic().Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));
            ws.Column(1).Width = 60;
            return;
        }

        ws.Cell(2, 1).Value = pivot.HeaderTitle;
        ws.Cell(2, 1).Style.Font.SetFontSize(9).Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));

        // Two header bands, the same shape the screen shows: the period across a merged pair, then
        // the two metric names underneath it.
        const int headerRow = 4;
        var metricRow = headerRow + 1;

        ws.Cell(headerRow, 1).Value = "#";
        ws.Cell(headerRow, 2).Value = "Insurance & Top Denials";
        ws.Range(headerRow, 1, metricRow, 1).Merge();
        ws.Range(headerRow, 2, metricRow, 2).Merge();

        var column = 3;
        foreach (var period in pivot.Periods)
        {
            ws.Cell(headerRow, column).Value = period.Label;
            ws.Range(headerRow, column, headerRow, column + 1).Merge()
              .Style.Fill.SetBackgroundColor(PivotPeriod);

            ws.Cell(metricRow, column).Value = "No. of Claims";
            ws.Cell(metricRow, column + 1).Value = "Insurance Balance";
            column += 2;
        }

        ws.Cell(headerRow, column).Value = pivot.GrandTotalTitle;
        ws.Range(headerRow, column, headerRow, column + 1).Merge()
          .Style.Fill.SetBackgroundColor(PivotGrandTotal);

        ws.Cell(metricRow, column).Value = "No. of Claims";
        ws.Cell(metricRow, column + 1).Value = "Insurance Balance";

        var lastColumn = column + 1;

        var header = ws.Range(headerRow, 1, metricRow, lastColumn);
        header.Style.Font.Bold = true;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        header.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        header.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        header.Style.Border.OutsideBorderColor = XLColor.White;
        header.Style.Border.InsideBorderColor = XLColor.White;

        // Painted after the merges so the period and grand-total fills above survive.
        ws.Range(headerRow, 1, metricRow, 2).Style.Fill.SetBackgroundColor(PivotHeader);
        foreach (var cell in ws.Range(metricRow, 3, metricRow, lastColumn).Cells())
            cell.Style.Fill.SetBackgroundColor(cell.Address.ColumnNumber >= column ? PivotGrandTotal : PivotPeriod);

        var row = metricRow + 1;
        foreach (var pivotRow in pivot.Rows)
        {
            ws.Cell(row, 1).Value = pivotRow.IndexLabel;
            ws.Cell(row, 2).Value = pivotRow.Label;

            var c = 3;
            foreach (var cell in pivotRow.Cells)
            {
                // A zero reads as a dash on screen; an empty cell says the same thing in Excel
                // without it being mistaken for a real zero in a sum.
                if (cell.ClaimCount > 0) ws.Cell(row, c).Value = cell.ClaimCount;
                if (cell.DenialBalance != 0m) ws.Cell(row, c + 1).Value = cell.DenialBalance;
                c += 2;
            }

            ws.Cell(row, c).Value = pivotRow.TotalClaimCount;
            ws.Cell(row, c + 1).Value = pivotRow.TotalBalance;

            var line = ws.Range(row, 1, row, lastColumn);

            if (pivotRow.IsInsuranceRow)
            {
                line.Style.Font.SetBold();
                line.Style.Fill.SetBackgroundColor(PivotInsuranceRow);
            }
            else
            {
                // Child denial rows are indented, as they are on screen.
                ws.Cell(row, 2).Style.Alignment.SetIndent(2);
            }

            row++;
        }

        var footer = row;
        ws.Cell(footer, 1).Value = string.Empty;
        ws.Cell(footer, 2).Value = "Total";

        var fc = 3;
        foreach (var total in pivot.TotalsByPeriod)
        {
            ws.Cell(footer, fc).Value = total.ClaimCount;
            ws.Cell(footer, fc + 1).Value = total.DenialBalance;
            fc += 2;
        }

        ws.Cell(footer, fc).Value = pivot.GrandTotalClaimCount;
        ws.Cell(footer, fc + 1).Value = pivot.GrandTotalBalance;

        var footerRange = ws.Range(footer, 1, footer, lastColumn);
        footerRange.Style.Font.Bold = true;
        footerRange.Style.Font.FontColor = XLColor.White;
        footerRange.Style.Fill.BackgroundColor = PivotFooter;

        // Number formats: claims whole, balances accounting, alternating across the period pairs.
        for (var c = 3; c <= lastColumn; c += 2)
        {
            ws.Range(metricRow + 1, c, footer, c).Style.NumberFormat.SetFormat(Whole);
            ws.Range(metricRow + 1, c + 1, footer, c + 1).Style.NumberFormat.SetFormat(Money);
        }

        var body = ws.Range(metricRow + 1, 1, footer, lastColumn);
        body.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.OutsideBorderColor = Rule;
        body.Style.Border.InsideBorderColor = Rule;

        ws.Column(1).Width = 5;
        ws.Column(2).Width = 46;
        for (var c = 3; c <= lastColumn; c++) ws.Column(c).Width = c % 2 == 1 ? 13 : 18;

        // The first two columns and the header stay put while scrolling, exactly as on screen.
        ws.SheetView.Freeze(metricRow, 2);
    }

    // ── Denial Insight ────────────────────────────────────────────────────────

    /// <summary>
    /// The Denial Insight sheet, laid out as the client's template (v1.0) - same columns, same merges -
    /// with a title above it. The import finds the header row by its text, so this file round-trips.
    /// </summary>
    private static void WriteInsight(IXLWorksheet ws, DenialInsightPanelViewModel insight, string lab)
    {
        ws.Cell(1, 1).Value = $"{lab} — Key Observations & Highlights";
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(13).Font.SetFontColor(Ink);

        ws.Cell(2, 1).Value = $"{DenialInsightBuckets.Label(insight.Bucket)} — {insight.Rows.Count:N0} row(s)";
        ws.Cell(2, 1).Style.Font.SetFontSize(9).Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));

        const int headerRow = 4;
        const int last = DenialInsightTemplate.LastColumn;

        DenialInsightTemplate.WriteHeader(ws, headerRow);

        var row = headerRow + 1;

        if (insight.Rows.Count == 0)
        {
            ws.Cell(row, 1).Value = "No denial insights have been imported for this lab.";
            var emptyBand = ws.Range(row, 1, row, last).Merge();
            emptyBand.Style.Font.Italic = true;
            emptyBand.Style.Font.FontColor = XLColor.FromHtml("#6B7A8C");
            emptyBand.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            DenialInsightTemplate.SizeColumns(ws);
            return;
        }

        foreach (var week in insight.WeekGroups)
        {
            // Previous Week holds several weeks. The separator the screen draws is carried into the
            // sheet, or the weeks would run together as one list.
            if (insight.HasMultipleWeeks)
            {
                ws.Cell(row, 1).Value = $"{week.RangeLabel}   ·   {week.Rows.Count:N0} denial code(s)"
                                      + $"   ·   {week.TotalDenials:N0} denial(s)";
                var band = ws.Range(row, 1, row, last);
                band.Merge();
                band.Style.Fill.BackgroundColor = WeekDivider;
                band.Style.Font.Bold = true;
                band.Style.Font.FontColor = InsightHeader;
                band.Style.Border.TopBorder = XLBorderStyleValues.Medium;
                band.Style.Border.TopBorderColor = InsightHeader;
                row++;
            }

            var index = 1;
            foreach (var insightRow in week.Rows)
            {
                DenialInsightTemplate.WriteRow(ws, row, index++, insightRow);

                // The two body tints the screen carries, so the banded groups stay readable
                // once the coloured headers have scrolled away.
                ws.Range(row, DenialInsightTemplate.ColPayer, row, DenialInsightTemplate.ColImpactPercentage)
                    .Style.Fill.SetBackgroundColor(ImpactTint);
                ws.Cell(row, DenialInsightTemplate.ColClosedDate).Style.Fill.SetBackgroundColor(ClosedTint);

                var (fill, font) = CategoryColours(insightRow.ActionCategory);
                if (fill is not null)
                {
                    var category = ws.Cell(row, DenialInsightTemplate.ColCategory);
                    category.Style.Fill.SetBackgroundColor(fill);
                    category.Style.Font.SetFontColor(font!).Font.SetBold();
                }

                row++;
            }
        }

        var lastRow = row - 1;
        ws.Cell(row, 1).Value = "Total";
        ws.Range(row, 1, row, DenialInsightTemplate.ColDescription + 1).Merge();
        ws.Cell(row, DenialInsightTemplate.ColNoOfDenials).Value = insight.TotalDenials;
        ws.Cell(row, DenialInsightTemplate.ColTotalBalance).Value = insight.TotalBalance;
        ws.Cell(row, DenialInsightTemplate.ColInsuranceNoOfDenials).Value = insight.TotalInsuranceDenials;
        ws.Cell(row, DenialInsightTemplate.ColInsuranceBalance).Value = insight.TotalInsuranceBalance;
        ws.Cell(row, DenialInsightTemplate.ColNoOfDenials).Style.NumberFormat.SetFormat(Whole);
        ws.Cell(row, DenialInsightTemplate.ColInsuranceNoOfDenials).Style.NumberFormat.SetFormat(Whole);
        ws.Cell(row, DenialInsightTemplate.ColTotalBalance).Style.NumberFormat.SetFormat(Money);
        ws.Cell(row, DenialInsightTemplate.ColInsuranceBalance).Style.NumberFormat.SetFormat(Money);

        var totalRange = ws.Range(row, 1, row, last);
        totalRange.Style.Font.Bold = true;
        totalRange.Style.Fill.BackgroundColor = XLColor.FromHtml("#EEF2F7");
        totalRange.Style.Border.TopBorder = XLBorderStyleValues.Medium;
        totalRange.Style.Border.TopBorderColor = Rule;

        var body = ws.Range(headerRow, 1, row, last);
        body.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        body.Style.Border.OutsideBorderColor = Rule;
        body.Style.Border.InsideBorderColor = Rule;

        DenialInsightTemplate.SizeColumns(ws);
        ws.SheetView.Freeze(headerRow, 2);

        // Filter across the data rows only - a header filter that swallowed the total row would
        // hide it the moment anyone filtered.
        if (lastRow >= headerRow + 1) ws.Range(headerRow, 1, lastRow, last).SetAutoFilter();
    }

    /// <summary>The workbook's own category fills, matched the same way the page matches them.</summary>
    private static (XLColor? Fill, XLColor? Font) CategoryColours(string? category)
    {
        var text = (category ?? string.Empty).Trim().ToLowerInvariant();
        if (text.Length == 0) return (null, null);

        var appeal = text.Contains("appeal");

        if (appeal && (text.Contains("mr") || text.Contains("medical record")))
            return (XLColor.FromHtml("#DDEBF7"), XLColor.FromHtml("#1F4E79"));

        if (appeal)
            return (XLColor.FromHtml("#FFF2CC"), XLColor.FromHtml("#7F5F00"));

        if (text.Contains("rebill") || text.Contains("reprocess"))
            return (XLColor.FromHtml("#E2EFDA"), XLColor.FromHtml("#375623"));

        if (text.Contains("review") || text.Contains("write off") || text.Contains("write-off"))
            return (XLColor.FromHtml("#FCE4D6"), XLColor.FromHtml("#843C0C"));

        return (XLColor.FromHtml("#EEF1F5"), XLColor.FromHtml("#5A6A7A"));
    }
}
