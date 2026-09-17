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

    // Insight palette - matches denial_claim_report.css and the client's own workbook.
    private static readonly XLColor InsightHeader = XLColor.FromHtml("#375623");
    private static readonly XLColor InsightGold = XLColor.FromHtml("#BF8F00");
    private static readonly XLColor InsightRed = XLColor.FromHtml("#B91C1C");
    private static readonly XLColor InsightClosed = XLColor.FromHtml("#1F7A3D");
    private static readonly XLColor ImpactTint = XLColor.FromHtml("#FDF8EC");
    private static readonly XLColor ClosedTint = XLColor.FromHtml("#F2F9F4");
    private static readonly XLColor WeekDivider = XLColor.FromHtml("#EEF3F8");

    private static readonly XLColor Rule = XLColor.FromHtml("#D5E1EF");
    private static readonly XLColor Ink = XLColor.FromHtml("#1F2D3D");

    private const string Money = "$#,##0.00";
    private const string Whole = "#,##0";

    public static XLWorkbook Build(DenialClaimReportViewModel model)
    {
        var workbook = new XLWorkbook();

        WritePivot(workbook.Worksheets.Add("Monthly Summary"), model.Monthly, "Monthly Summary", model.CurrentLab);
        WritePivot(workbook.Worksheets.Add("Weekly Summary"), model.Weekly, "Weekly Summary", model.CurrentLab);
        WriteInsight(workbook.Worksheets.Add("Denial Insight"), model.Insight, model.CurrentLab);

        return workbook;
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

    private static readonly string[] InsightHeaders =
    [
        "#", "Denial Codes", "Descriptions", "# of Denial", "Total Balance ($)",
        "Highest $ Impact - Insurance", "Claim Count", "Ins. Balance ($)", "$ Impact (%)", "Observation",
        "Category", "Action", "Feedback / Response", "Responsibility", "Discussion Date", "ETA", "Closed Date"
    ];

    private static void WriteInsight(IXLWorksheet ws, DenialInsightPanelViewModel insight, string lab)
    {
        ws.Cell(1, 1).Value = $"{lab} — Key Observations & Highlights";
        ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(13).Font.SetFontColor(Ink);

        ws.Cell(2, 1).Value = $"{DenialInsightBuckets.Label(insight.Bucket)} — {insight.Rows.Count:N0} row(s)";
        ws.Cell(2, 1).Style.Font.SetFontSize(9).Font.SetFontColor(XLColor.FromHtml("#6B7A8C"));

        const int headerRow = 4;
        var last = InsightHeaders.Length;

        for (var i = 0; i < last; i++)
        {
            var cell = ws.Cell(headerRow, i + 1);
            cell.Value = InsightHeaders[i];

            // The three banded groups, same split as the screen: gold for the $ impact group,
            // red for the two columns that say what to DO, green for the one that says it is done.
            var column = i + 1;
            cell.Style.Fill.SetBackgroundColor(column switch
            {
                >= 6 and <= 9 => InsightGold,
                11 or 12 => InsightRed,
                17 => InsightClosed,
                _ => InsightHeader
            });
        }

        var header = ws.Range(headerRow, 1, headerRow, last);
        header.Style.Font.Bold = true;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Alignment.WrapText = true;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Row(headerRow).Height = 30;

        var row = headerRow + 1;

        if (insight.Rows.Count == 0)
        {
            ws.Cell(row, 1).Value = "No denial insights have been imported for this lab.";
            var emptyBand = ws.Range(row, 1, row, last).Merge();
            emptyBand.Style.Font.Italic = true;
            emptyBand.Style.Font.FontColor = XLColor.FromHtml("#6B7A8C");
            emptyBand.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            SizeInsightColumns(ws);
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
                ws.Cell(row, 1).Value = index++;
                ws.Cell(row, 2).Value = insightRow.DenialCode;
                ws.Cell(row, 3).Value = insightRow.DenialDescription;
                ws.Cell(row, 4).Value = insightRow.NoOfDenials;
                ws.Cell(row, 5).Value = insightRow.TotalBalance;
                ws.Cell(row, 6).Value = insightRow.PayerName;
                ws.Cell(row, 7).Value = insightRow.ClaimCount;
                ws.Cell(row, 8).Value = insightRow.InsuranceBalance;
                ws.Cell(row, 9).Value = insightRow.ImpactPercentage / 100m;
                ws.Cell(row, 10).Value = DenialInsightRichText.ToPlainText(insightRow.ObservationHtml);
                ws.Cell(row, 11).Value = insightRow.ActionCategory;
                ws.Cell(row, 12).Value = DenialInsightRichText.ToPlainText(insightRow.ActionHtml);
                ws.Cell(row, 13).Value = insightRow.FeedbackResponse;
                ws.Cell(row, 14).Value = insightRow.Responsibility;
                if (insightRow.DiscussionDate.HasValue) ws.Cell(row, 15).Value = insightRow.DiscussionDate.Value;
                if (insightRow.Eta.HasValue) ws.Cell(row, 16).Value = insightRow.Eta.Value;
                if (insightRow.ClosedDate.HasValue) ws.Cell(row, 17).Value = insightRow.ClosedDate.Value;

                ws.Cell(row, 4).Style.NumberFormat.SetFormat(Whole);
                ws.Cell(row, 5).Style.NumberFormat.SetFormat(Money);
                ws.Cell(row, 7).Style.NumberFormat.SetFormat(Whole);
                ws.Cell(row, 8).Style.NumberFormat.SetFormat(Money);
                ws.Cell(row, 9).Style.NumberFormat.SetFormat("0.##%");
                ws.Range(row, 15, row, 17).Style.NumberFormat.SetFormat("dd-mmm-yyyy");

                // The two body tints the screen carries, so the banded groups stay readable
                // once the coloured headers have scrolled away.
                ws.Range(row, 6, row, 9).Style.Fill.SetBackgroundColor(ImpactTint);
                ws.Cell(row, 17).Style.Fill.SetBackgroundColor(ClosedTint);

                var (fill, font) = CategoryColours(insightRow.ActionCategory);
                if (fill is not null)
                {
                    ws.Cell(row, 11).Style.Fill.SetBackgroundColor(fill);
                    ws.Cell(row, 11).Style.Font.SetFontColor(font!).Font.SetBold();
                }

                ws.Range(row, 3, row, 3).Style.Alignment.SetWrapText(true);
                ws.Range(row, 10, row, 10).Style.Alignment.SetWrapText(true);
                ws.Range(row, 12, row, 13).Style.Alignment.SetWrapText(true);
                ws.Row(row).Style.Alignment.SetVertical(XLAlignmentVerticalValues.Top);

                row++;
            }
        }

        var lastRow = row - 1;
        ws.Cell(row, 1).Value = "Total";
        ws.Range(row, 1, row, 3).Merge();
        ws.Cell(row, 4).Value = insight.TotalDenials;
        ws.Cell(row, 5).Value = insight.TotalBalance;
        ws.Cell(row, 7).Value = insight.TotalClaimCount;
        ws.Cell(row, 8).Value = insight.TotalInsuranceBalance;
        ws.Cell(row, 4).Style.NumberFormat.SetFormat(Whole);
        ws.Cell(row, 5).Style.NumberFormat.SetFormat(Money);
        ws.Cell(row, 7).Style.NumberFormat.SetFormat(Whole);
        ws.Cell(row, 8).Style.NumberFormat.SetFormat(Money);

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

        SizeInsightColumns(ws);
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

    private static void SizeInsightColumns(IXLWorksheet ws)
    {
        double[] widths = [5, 13, 40, 11, 16, 26, 12, 16, 11, 46, 16, 46, 26, 16, 14, 14, 14];
        for (var i = 0; i < widths.Length; i++) ws.Column(i + 1).Width = widths[i];
    }
}
