using ClosedXML.Excel;
using LabMetricsDashboard.Services;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Inserts the Key Insights &amp; Highlights worksheet as sheet 1 of a queued
/// Production / Collection / LIS workbook, matching the website Excel export.
/// Also applies +/- grouping for indented subcategory rows on the other sheets.
/// </summary>
internal static class InsightsSheetInjector
{
    public static async Task InsertAsync(
        XLWorkbook workbook,
        INotesRepository notes,
        string connectionString,
        string labName,
        string reportName,
        CancellationToken ct)
    {
        var insights = await InsightsExcelBuilder.LoadAsync(notes, connectionString, reportName, ct);
        InsightsExcelBuilder.InsertAsFirstSheet(workbook, insights, labName, reportName);
    }
}
