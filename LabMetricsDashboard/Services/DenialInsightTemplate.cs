using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// The client's Denial Insight template (Templates/DenialInsights_Template_v1.0.xlsx), as one
/// definition shared by everything that writes it: the Denial Insight tab's Export and the full
/// Denial Summary workbook - including the copy LRN.ReportWorker builds - so the files cannot drift
/// apart from each other or from what the import expects.
/// </summary>
/// <remarks>
/// <para>The template merges several fields across columns (Descriptions C:D, the insurance G:H,
/// Observation L:N, Action Q:T, Feedback / Response U:W). A merged cell keeps its value in the
/// left-most cell, so the column numbers below are where each field's value lives, and the import's
/// header matching lands on the same cells.</para>
/// <para>The template carries "# of Denials" twice: the code's total, then the highest-impact
/// insurance's own count inside the gold impact group. The import tells them apart by position -
/// see DenialClaimReportController.ValidateInsightWorkbook.</para>
/// </remarks>
public static class DenialInsightTemplate
{
    public const string SheetName = "Denial Insight";

    public const int ColIndex = 1;
    public const int ColDenialCode = 2;
    public const int ColDescription = 3;            // C:D
    public const int ColNoOfDenials = 5;
    public const int ColTotalBalance = 6;
    public const int ColPayer = 7;                  // G:H
    public const int ColInsuranceNoOfDenials = 9;
    public const int ColInsuranceBalance = 10;
    public const int ColImpactPercentage = 11;
    public const int ColObservation = 12;           // L:N
    public const int ColData = 15;
    public const int ColCategory = 16;
    public const int ColAction = 17;                // Q:T
    public const int ColFeedback = 21;              // U:W
    public const int ColResponsibility = 24;
    public const int ColDiscussionDate = 25;
    public const int ColEta = 26;
    public const int ColClosedDate = 27;
    public const int ColStatus = 28;

    public const int LastColumn = ColStatus;

    // The template's header groups: green by default, gold for the $ impact group, red for the
    // two columns that say what to DO, and a brighter green for the one that says it is done.
    public static readonly XLColor HeaderGreen = XLColor.FromHtml("#375623");
    public static readonly XLColor HeaderGold = XLColor.FromHtml("#BF8F00");
    public static readonly XLColor HeaderRed = XLColor.FromHtml("#B91C1C");
    public static readonly XLColor HeaderClosed = XLColor.FromHtml("#1F7A3D");

    private const string Money = "$#,##0.00";
    private const string Whole = "#,##0";
    private const string DateFormat = "dd-mmm-yyyy";

    private sealed record Field(int Column, int Span, string Header, XLColor Fill);

    private static readonly Field[] Fields =
    [
        new(ColIndex, 1, "#", HeaderGreen),
        new(ColDenialCode, 1, "Denial Codes", HeaderGreen),
        new(ColDescription, 2, "Descriptions", HeaderGreen),
        new(ColNoOfDenials, 1, "# of Denials", HeaderGreen),
        new(ColTotalBalance, 1, "Total Balance ($)", HeaderGreen),
        new(ColPayer, 2, "Highest Impact - Insurance", HeaderGold),
        new(ColInsuranceNoOfDenials, 1, "# of Denials", HeaderGold),
        new(ColInsuranceBalance, 1, "Ins. Balance ($)", HeaderGold),
        new(ColImpactPercentage, 1, "$ Impact (%)", HeaderGold),
        new(ColObservation, 3, "Observation", HeaderGreen),
        new(ColData, 1, "Data", HeaderGreen),
        new(ColCategory, 1, "Category", HeaderRed),
        new(ColAction, 4, "Action", HeaderRed),
        new(ColFeedback, 3, "Feedback / Response", HeaderGreen),
        new(ColResponsibility, 1, "Responsibility", HeaderGreen),
        new(ColDiscussionDate, 1, "Discussion Date", HeaderGreen),
        new(ColEta, 1, "ETA", HeaderGreen),
        new(ColClosedDate, 1, "Closed Date", HeaderClosed),
        new(ColStatus, 1, "Status", HeaderGreen),
    ];

    /// <summary>The header row: merged where the template merges, filled by group.</summary>
    public static void WriteHeader(IXLWorksheet ws, int row)
    {
        foreach (var field in Fields)
        {
            var range = ws.Range(row, field.Column, row, field.Column + field.Span - 1);
            if (field.Span > 1) range.Merge();

            ws.Cell(row, field.Column).Value = field.Header;
            range.Style.Fill.SetBackgroundColor(field.Fill);
        }

        var header = ws.Range(row, 1, row, LastColumn);
        header.Style.Font.Bold = true;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Alignment.WrapText = true;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        header.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        ws.Row(row).Height = 30;
    }

    /// <summary>One insight row: values, the template's merges, number formats and wrapping.</summary>
    public static void WriteRow(IXLWorksheet ws, int row, int index, DenialInsightRow r)
    {
        foreach (var field in Fields.Where(f => f.Span > 1))
            ws.Range(row, field.Column, row, field.Column + field.Span - 1).Merge();

        ws.Cell(row, ColIndex).Value = index;
        ws.Cell(row, ColDenialCode).Value = r.DenialCode;
        ws.Cell(row, ColDescription).Value = r.DenialDescription;
        ws.Cell(row, ColNoOfDenials).Value = r.NoOfDenials;
        ws.Cell(row, ColTotalBalance).Value = r.TotalBalance;
        ws.Cell(row, ColPayer).Value = r.PayerName;
        ws.Cell(row, ColInsuranceNoOfDenials).Value = r.InsuranceNoOfDenials;
        ws.Cell(row, ColInsuranceBalance).Value = r.InsuranceBalance;
        // Written back as the same text it was imported as ("57%"), so the round trip is exact.
        ws.Cell(row, ColImpactPercentage).Value = r.ImpactPercentage;
        ws.Cell(row, ColObservation).Value = DenialInsightRichText.ToPlainText(r.ObservationHtml);
        ws.Cell(row, ColData).Value = r.Data;
        ws.Cell(row, ColCategory).Value = r.ActionCategory;
        ws.Cell(row, ColAction).Value = DenialInsightRichText.ToPlainText(r.ActionHtml);
        ws.Cell(row, ColFeedback).Value = r.FeedbackResponse;
        ws.Cell(row, ColResponsibility).Value = r.Responsibility;
        if (r.DiscussionDate.HasValue) ws.Cell(row, ColDiscussionDate).Value = r.DiscussionDate.Value;
        if (r.Eta.HasValue) ws.Cell(row, ColEta).Value = r.Eta.Value;
        if (r.ClosedDate.HasValue) ws.Cell(row, ColClosedDate).Value = r.ClosedDate.Value;
        ws.Cell(row, ColStatus).Value = r.Status;

        // Status carries the same colour as on the page (DenialInsightStatus).
        if (DenialInsightStatus.Colours(r.Status) is { } statusColours)
        {
            var status = ws.Cell(row, ColStatus);
            status.Style.Fill.SetBackgroundColor(XLColor.FromHtml(statusColours.Fill));
            status.Style.Font.SetFontColor(XLColor.FromHtml(statusColours.Text)).Font.SetBold();
        }

        ws.Cell(row, ColNoOfDenials).Style.NumberFormat.SetFormat(Whole);
        ws.Cell(row, ColInsuranceNoOfDenials).Style.NumberFormat.SetFormat(Whole);
        ws.Cell(row, ColTotalBalance).Style.NumberFormat.SetFormat(Money);
        ws.Cell(row, ColInsuranceBalance).Style.NumberFormat.SetFormat(Money);
        ws.Cell(row, ColImpactPercentage).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
        ws.Range(row, ColDiscussionDate, row, ColClosedDate).Style.NumberFormat.SetFormat(DateFormat);

        var cells = ws.Range(row, 1, row, LastColumn);
        cells.Style.Alignment.WrapText = true;
        cells.Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
    }

    /// <summary>The template's own column widths (B 13.7, C 21.4, D onward 15.7).</summary>
    public static void SizeColumns(IXLWorksheet ws)
    {
        ws.Column(ColIndex).Width = 5;
        ws.Column(ColDenialCode).Width = 13.66;
        ws.Column(ColDescription).Width = 21.44;
        ws.Columns(ColDescription + 1, LastColumn).Width = 15.66;
    }
}
