using System.Data;
using LRN.ReportQueue.Shared;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Streams dbo.usp_GetPayerValidationReportPaged (@PageSize = NULL → all filtered rows)
/// via <see cref="OpenXmlRowStreamer"/> (OpenXmlWriter → disk). ClosedXML SaveAs
/// OOMs on Cove-scale ICD-heavy exports; OpenXml keeps memory flat.
/// </summary>
public sealed class PayerPolicyValidationReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.PayerPolicyValidation;

    private static readonly HashSet<string> ExcludedColumns =
        new(StringComparer.OrdinalIgnoreCase) { "RowNum", "RowNumber", "TotalFiltered", "TotalAll" };

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

        // Pass 1 — measure max ICD overflow parts per column (0 when nothing
        // exceeds Excel's 32,767-char limit). Matches the ClosedXML sync export:
        // only create "{Name}_1"… columns when they are actually needed.
        int[] icdExtraParts;
        int totalFiltered;
        {
            await using var measureCmd = BuildPagedCommand(conn, filters);
            await using var measureReader = await measureCmd.ExecuteReaderAsync(
                CommandBehavior.SequentialAccess, ct);

            totalFiltered = 0;
            if (await measureReader.ReadAsync(ct) && !measureReader.IsDBNull(0))
                totalFiltered = Convert.ToInt32(measureReader.GetValue(0));

            if (!await measureReader.NextResultAsync(ct))
                throw new InvalidOperationException(
                    "usp_GetPayerValidationReportPaged did not return a data result set.");

            if (reportProgressAsync is not null)
                await reportProgressAsync(3);

            icdExtraParts = await OpenXmlRowStreamer.MeasureIcdOverflowAsync(
                measureReader, ExcludedColumns, ct);
        }

        if (reportProgressAsync is not null)
            await reportProgressAsync(8);

        // Pass 2 — stream the same result set into the workbook with only the
        // overflow columns that pass 1 measured.
        await using var writeCmd = BuildPagedCommand(conn, filters);
        await using var writeReader = await writeCmd.ExecuteReaderAsync(
            CommandBehavior.SequentialAccess, ct);

        // Skip the count result set (already captured in pass 1).
        if (!await writeReader.ReadAsync(ct))
            throw new InvalidOperationException(
                "usp_GetPayerValidationReportPaged did not return a count result set.");
        if (!await writeReader.NextResultAsync(ct))
            throw new InvalidOperationException(
                "usp_GetPayerValidationReportPaged did not return a data result set.");

        return await OpenXmlRowStreamer.WriteFromReaderAsync(
            writeReader,
            tempPath,
            job.LabName,
            "Payer Policy Validation",
            filters.ToActiveFilterList(),
            reportProgressAsync,
            totalFiltered > 0 ? totalFiltered : null,
            ExcludedColumns,
            splitIcdColumns: true,
            ct,
            icdExtraParts);
    }

    private SqlCommand BuildPagedCommand(SqlConnection conn, PayerPolicyValidationFilters filters)
    {
        var cmd = new SqlCommand("dbo.usp_GetPayerValidationReportPaged", conn)
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
        return cmd;
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { /* best effort */ }
    }
}
