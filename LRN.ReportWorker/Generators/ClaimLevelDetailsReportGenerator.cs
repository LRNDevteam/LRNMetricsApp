using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Claim Level Details export — streams dbo.ClaimLevelData using the
/// lab's Select_Script column list (same fields as Dashboard/ClaimLevel)
/// into a green-themed workbook, sheet-split every 300K rows.
/// </summary>
public sealed class ClaimLevelDetailsReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.ClaimLevelDetails;

    private static readonly HashSet<string> MoneyColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "ChargeAmount", "AllowedAmount", "InsurancePayment", "PatientPayment",
        "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments",
        "InsuranceBalance", "PatientBalance", "TotalBalance",
    };

    private readonly LabSettings _labSettings;
    private readonly SqlClaimLineRepository _repo;
    private readonly ILogger<ClaimLevelDetailsReportGenerator> _logger;

    public ClaimLevelDetailsReportGenerator(
        LabSettings labSettings,
        SqlClaimLineRepository repo,
        ILogger<ClaimLevelDetailsReportGenerator> logger)
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
            throw new InvalidOperationException($"Claim Level Details is not available for '{job.LabName}'.");

        var f = ClaimLevelDetailsFilters.FromJson(job.FilterDetailsJson);
        static DateOnly? ParseDate(string? s) =>
            DateOnly.TryParse(s, out var d) ? d : null;

        var (dataSql, countSql, parameters) = _repo.BuildClaimLevelDetailsExportQuery(
            job.LabName,
            f.PayerName, f.PayerTypes, f.ClaimStatuses, f.ClinicNames,
            f.DenialCode, f.DenialCodeExcludeBlank,
            f.PayerNames, f.PayerExcludeBlank,
            f.PanelNames, f.PanelExcludeBlank,
            f.AgingBuckets,
            ParseDate(f.FirstBillFrom), ParseDate(f.FirstBillTo), f.FirstBillNull, f.FirstBillExcludeBlank,
            ParseDate(f.ChargeEnteredFrom), ParseDate(f.ChargeEnteredTo), f.ChargeEnteredNull, f.ChargeEnteredExcludeBlank,
            ParseDate(f.DosFrom), ParseDate(f.DosTo), f.DosNull);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        int totalRows;
        try
        {
            totalRows = await DetailExportStreamer.WriteAsync(
                labConfig.DbConnectionString, dataSql, countSql, parameters,
                job.LabName, "Claim Level Details", f.ToActiveFilterList(),
                MoneyColumns, ExcelTheme.TabGreen, tempPath, reportProgressAsync, ct);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "ClaimLevelDetails {ReportId} [{Lab}]: {Rows:N0} rows, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, totalRows, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, totalRows);
    }
}
