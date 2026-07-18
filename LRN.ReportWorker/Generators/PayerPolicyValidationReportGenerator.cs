using System.Data;
using ClosedXML.Excel;
using LRN.ReportQueue.Shared;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Streams dbo.usp_GetPayerValidationReportPaged (@PageSize = NULL → all filtered rows)
/// through a SqlDataReader straight into a ClosedXML workbook.
///
/// Large-file strategy (100K–700K+ rows):
///  • rows are never materialized into an entity list — one object[] per row,
///    buffered in 10K-row batches for InsertData;
///  • sheets split every 300K rows (matches the existing web export behaviour,
///    keeps per-sheet memory and Excel usability sane);
///  • the workbook is saved to "{path}.tmp" and atomically moved to the final
///    name, so a crash never leaves a half-written .xlsx registered in the DB.
/// </summary>
public sealed class PayerPolicyValidationReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.PayerPolicyValidation;

    private const int SheetSplitThreshold = 300_000;
    private const int InsertBatchSize     = 10_000;

    /// <summary>Columns emitted by paging plumbing — never exported.</summary>
    private static readonly HashSet<string> ExcludedColumns =
        new(StringComparer.OrdinalIgnoreCase) { "RowNum", "RowNumber", "TotalFiltered", "TotalAll" };

    /// <summary>Money columns (mirrors PayerPolicyValidationColumns.IsMoney in the dashboard).</summary>
    private static readonly HashSet<string> MoneyColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "BilledAmount", "AllowedAmount", "InsurancePayment", "InsuranceAdjustment",
        "PatientPaidAmount", "PatientAdjustment", "InsuranceBalance", "PatientBalance",
        "TotalBalance", "MedicareFee",
        "ExpectedAverageAllowedAmount", "ExpectedAverageInsurancePayment",
        "ExpectedAllowedAmountSameLab", "ExpectedInsurancePaymentSameLab",
        "ModeAllowedAmountSameLab", "ModeInsurancePaidSameLab",
        "ModeAllowedAmountPeer", "ModeInsurancePaidPeer",
        "MedianAllowedAmountSameLab", "MedianInsurancePaidSameLab",
        "MedianAllowedAmountPeer", "MedianInsurancePaidPeer",
        "ModeAllowedAmountDifference", "ModeInsurancePaidDifference",
        "MedianAllowedAmountDifference", "MedianInsurancePaidDifference",
        "Variance_AllowedAmount", "Variance_PaidAmount",
    };

    private readonly ReportWorkerOptions _options;
    private readonly ILogger<PayerPolicyValidationReportGenerator> _logger;

    public PayerPolicyValidationReportGenerator(
        IOptions<ReportWorkerOptions> options,
        ILogger<PayerPolicyValidationReportGenerator> logger)
    {
        _options = options.Value;
        _logger  = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        var filters = PayerPolicyValidationFilters.FromJson(job.FilterDetailsJson);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";

        int totalRows;
        try
        {
            totalRows = await WriteWorkbookAsync(lab, job, filters, tempPath, reportProgressAsync, ct);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            TryDelete(tempPath);
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "Report {ReportId} [{Lab}]: {Rows:N0} rows, {Size:N0} bytes → {Path}",
            job.ReportId, lab.LabName, totalRows, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, totalRows);
    }

    private async Task<int> WriteWorkbookAsync(
        LabDbConfig lab, ClaimedReport job, PayerPolicyValidationFilters filters,
        string tempPath, Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        await using var conn = new SqlConnection(lab.DbConnectionString);
        await conn.OpenAsync(ct);

        await using var cmd = new SqlCommand("dbo.usp_GetPayerValidationReportPaged", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = _options.QueryTimeoutSeconds,
        };
        cmd.Parameters.AddWithValue("@RunId",                                DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayerName",                      (object?)filters.PayerName                      ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPanelName",                      (object?)filters.PanelName                      ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterFinalCoverageStatus",            (object?)filters.FinalCoverageStatus            ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterCPTCode",                        (object?)filters.CPTCode                        ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterForecastingPayabilitySubstatus", (object?)filters.ForecastingPayabilitySubstatus ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPredictionStatus",               (object?)filters.PredictionStatus               ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayStatus",                      (object?)filters.PayStatus                      ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PageNumber",                           1);
        cmd.Parameters.AddWithValue("@PageSize",                             DBNull.Value); // NULL → ALL filtered rows

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        // Result set 1: counts (TotalFiltered, TotalAll) — informational only.
        int totalFiltered = 0;
        if (await reader.ReadAsync(ct) && !reader.IsDBNull(0))
            totalFiltered = Convert.ToInt32(reader.GetValue(0));

        if (!await reader.NextResultAsync(ct))
            throw new InvalidOperationException(
                "usp_GetPayerValidationReportPaged did not return a data result set.");

        // Export column map from the reader schema — auto-adapts when a lab DB
        // gains/loses columns, no code change required.
        var columns = new List<(int Ordinal, string Name)>();
        for (var i = 0; i < reader.FieldCount; i++)
        {
            var name = reader.GetName(i);
            if (!ExcludedColumns.Contains(name))
                columns.Add((i, name));
        }
        if (columns.Count == 0)
            throw new InvalidOperationException("Report query returned no exportable columns.");

        var headers = columns.Select(c => c.Name).ToArray();
        var moneyColumnNumbers = columns
            .Select((c, idx) => (c.Name, Col: idx + 1))
            .Where(x => MoneyColumns.Contains(x.Name))
            .Select(x => x.Col)
            .ToArray();

        using var wb = new XLWorkbook();
        var totalRows = 0;
        var sheetIndex = 0;
        IXLWorksheet? ws = null;
        var nextRow = 3;
        var sheetRowCount = 0;
        var batch = new List<object?[]>(InsertBatchSize);
        var expectedParts = Math.Max(1, (int)Math.Ceiling(totalFiltered / (double)SheetSplitThreshold));

        while (await reader.ReadAsync(ct))
        {
            ct.ThrowIfCancellationRequested();

            if (ws is null || sheetRowCount >= SheetSplitThreshold)
            {
                FlushBatch(ws, ref nextRow, batch);
                sheetIndex++;
                ws = NewSheet(wb, job.LabName, headers, sheetIndex, expectedParts);
                nextRow = 3;
                sheetRowCount = 0;
            }

            var values = new object?[columns.Count];
            for (var c = 0; c < columns.Count; c++)
            {
                var v = reader.GetValue(columns[c].Ordinal);
                values[c] = v is DBNull ? string.Empty : v;
            }
            batch.Add(values);
            totalRows++;
            sheetRowCount++;

            if (batch.Count >= InsertBatchSize)
            {
                FlushBatch(ws, ref nextRow, batch);

                // Rows read / total filtered → capped at 90%: the remaining 10%
                // is the (slow) workbook save, so the badge never shows 100%
                // while the file isn't downloadable yet.
                if (reportProgressAsync is not null && totalFiltered > 0)
                {
                    var pct = (byte)Math.Min(90, totalRows * 90L / totalFiltered);
                    await reportProgressAsync(pct);
                }
            }
        }
        FlushBatch(ws, ref nextRow, batch);

        if (reportProgressAsync is not null)
            await reportProgressAsync(90); // saving the workbook…

        if (ws is null) // zero rows
        {
            ws = wb.AddWorksheet("Data");
            ws.Cell(1, 1).Value = "No data matched the selected filters.";
        }
        else
        {
            foreach (var sheet in wb.Worksheets)
            {
                foreach (var c in moneyColumnNumbers)
                    sheet.Column(c).Style.NumberFormat.Format = "$#,##0.00";
                for (var c = 1; c <= headers.Length; c++)
                    sheet.Column(c).Width = 16;
                sheet.SheetView.FreezeRows(2);
            }

            // Filter summary goes on the LAST sheet — nextRow tracks that sheet's write position.
            var active = filters.ToActiveFilterList();
            if (active.Count > 0)
                WriteFilterSummary(ws, nextRow + 1, active);
        }

        // SaveAs(string) rejects non-.xlsx extensions — stream keeps the .tmp staging name valid.
        using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            wb.SaveAs(fs);
        return totalRows;
    }

    // Same green family as LabMetricsDashboard.Services.ExcelTheme (Office Accent 6).
    private static readonly XLColor TitleBg  = XLColor.FromHtml("#385723");
    private static readonly XLColor HeaderBg = XLColor.FromHtml("#548235");
    private static readonly XLColor TabGreen = XLColor.FromHtml("#70AD47");

    private static IXLWorksheet NewSheet(
        XLWorkbook wb, string labName, string[] headers, int partIndex, int expectedParts)
    {
        // partIndex guard: if the count estimate was off and a second sheet is
        // needed anyway, never reuse the name "Data" (duplicate sheet = exception).
        var name = (expectedParts > 1 || partIndex > 1) ? $"Data_P{partIndex}" : "Data";
        var ws = wb.AddWorksheet(name.Length <= 31 ? name : name[..31]);
        ws.TabColor = TabGreen;
        ws.Style.Font.FontName = "Calibri";
        ws.Style.Font.FontSize = 10;

        var title = expectedParts > 1
            ? $"{labName} — Payer Policy Validation (sheet {partIndex} of {expectedParts})"
            : $"{labName} — Payer Policy Validation";

        ws.Range(1, 1, 1, headers.Length).Merge();
        var titleCell = ws.Cell(1, 1);
        titleCell.Value = title;
        titleCell.Style.Font.Bold = true;
        titleCell.Style.Font.FontSize = 14;
        titleCell.Style.Font.FontColor = XLColor.White;
        titleCell.Style.Fill.BackgroundColor = TitleBg;
        titleCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        for (var c = 0; c < headers.Length; c++)
            ws.Cell(2, c + 1).Value = headers[c];
        var headerRange = ws.Range(2, 1, 2, headers.Length);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Font.FontColor = XLColor.White;
        headerRange.Style.Fill.BackgroundColor = HeaderBg;

        return ws;
    }

    private static void FlushBatch(IXLWorksheet? ws, ref int nextRow, List<object?[]> batch)
    {
        if (ws is null || batch.Count == 0)
        {
            batch.Clear();
            return;
        }
        ws.Cell(nextRow, 1).InsertData(batch);
        nextRow += batch.Count;
        batch.Clear();
    }

    private static void WriteFilterSummary(
        IXLWorksheet ws, int startRow, List<(string Label, string? Value)> filters)
    {
        ws.Cell(startRow, 2).Value = "Active Filters";
        ws.Cell(startRow, 2).Style.Font.SetBold();
        for (var i = 0; i < filters.Count; i++)
        {
            ws.Cell(startRow + 1 + i, 2).Value = filters[i].Label;
            ws.Cell(startRow + 1 + i, 3).Value = filters[i].Value ?? string.Empty;
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { /* best effort */ }
    }
}
