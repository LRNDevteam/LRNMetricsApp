using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Line Level Details export — streams dbo.LineLevelData using the
/// lab's Select_Script column list (same fields as Dashboard/LineLevel)
/// into a green-themed workbook, sheet-split every 300K rows.
/// </summary>
public sealed class LineLevelDetailsReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.LineLevelDetails;

    private static readonly HashSet<string> MoneyColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit",
        "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment", "PatientPaymentPerUnit",
        "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments",
        "InsuranceBalance", "PatientBalance", "PatientBalancePerUnit", "TotalBalance",
    };

    private readonly LabSettings _labSettings;
    private readonly SqlClaimLineRepository _repo;
    private readonly ILogger<LineLevelDetailsReportGenerator> _logger;

    public LineLevelDetailsReportGenerator(
        LabSettings labSettings,
        SqlClaimLineRepository repo,
        ILogger<LineLevelDetailsReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig)
            || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException($"Line Level Details is not available for '{job.LabName}'.");

        var f = LineLevelDetailsFilters.FromJson(job.FilterDetailsJson);
        var (dataSql, countSql, parameters) = _repo.BuildLineLevelDetailsExportQuery(
            job.LabName,
            f.PayerName, f.PayerTypes, f.ClaimStatuses, f.PayStatuses,
            f.CPTCodes, f.ClinicNames, f.DenialCode);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        int totalRows;
        try
        {
            totalRows = await DetailExportStreamer.WriteAsync(
                labConfig.DbConnectionString, dataSql, countSql, parameters,
                job.LabName, "Line Level Details", f.ToActiveFilterList(),
                MoneyColumns, ExcelTheme.TabGold, tempPath, reportProgressAsync, ct);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "LineLevelDetails {ReportId} [{Lab}]: {Rows:N0} rows, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, totalRows, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, totalRows);
    }
}
