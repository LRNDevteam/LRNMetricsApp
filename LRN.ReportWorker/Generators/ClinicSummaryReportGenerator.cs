using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Clinic Summary export — same IClinicSummaryRepository queries and
/// ClinicSummaryExcelExportBuilder (green ExcelTheme) that
/// DashboardController.ExportClinicSummaryExcel uses synchronously.
/// </summary>
public sealed class ClinicSummaryReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.ClinicSummary;

    private readonly LabSettings _labSettings;
    private readonly IClinicSummaryRepository _repo;
    private readonly ILogger<ClinicSummaryReportGenerator> _logger;

    public ClinicSummaryReportGenerator(
        LabSettings labSettings,
        IClinicSummaryRepository repo,
        ILogger<ClinicSummaryReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var config))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not configured.");
        if (!config.LineClaimEnable || string.IsNullOrWhiteSpace(config.DbConnectionString))
            throw new InvalidOperationException($"Clinic Summary is not available for '{job.LabName}'.");

        var connStr   = config.DbConnectionString;
        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? job.LabName : config.DbLabName;
        var f = ClinicSalesRepSummaryFilters.FromJson(job.FilterDetailsJson);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }
        await Progress(5);

        // Same normalization/date semantics as the synchronous action.
        var clinics = NonEmpty(f.ClinicNames);
        var reps    = NonEmpty(f.SalesRepNames);
        var payers  = NonEmpty(f.PayerNames);
        var panels  = NonEmpty(f.PanelNames);
        var dosFrom = ParseDate(f.DosFrom);
        var dosTo   = ParseDate(f.DosTo);
        var fbFrom  = ParseDate(f.FirstBillFrom);
        var fbTo    = ParseDate(f.FirstBillTo);

        var result = await _repo.GetClinicSummaryAsync(
            connStr, dbLabName, clinics, reps, payers, panels, dosFrom, dosTo, fbFrom, fbTo, ct);
        await Progress(40);

        var rows = result.Rows;
        var totals = new ClinicSummaryRow
        {
            ClinicName                  = "Grand Total",
            BilledClaimCount            = rows.Sum(r => r.BilledClaimCount),
            PaidClaimCount              = rows.Sum(r => r.PaidClaimCount),
            DeniedClaimCount            = rows.Sum(r => r.DeniedClaimCount),
            OutstandingClaimCount       = rows.Sum(r => r.OutstandingClaimCount),
            TotalBilledCharges          = rows.Sum(r => r.TotalBilledCharges),
            TotalBilledChargeOnPaidClaim = rows.Sum(r => r.TotalBilledChargeOnPaidClaim),
            TotalAllowedAmount          = rows.Sum(r => r.TotalAllowedAmount),
            TotalInsurancePaidAmount    = rows.Sum(r => r.TotalInsurancePaidAmount),
            TotalPatientResponsibility  = rows.Sum(r => r.TotalPatientResponsibility),
            TotalDeniedCharges          = rows.Sum(r => r.TotalDeniedCharges),
            TotalOutstandingCharges     = rows.Sum(r => r.TotalOutstandingCharges),
            AverageAllowedAmount        = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageAllowedAmount), 2),
            AverageInsurancePaidAmount  = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageInsurancePaidAmount), 2),
        };

        var panelStatusVm = await _repo.GetClinicPanelStatusAsync(
            connStr, dbLabName, clinics, reps, payers, panels, dosFrom, dosTo, fbFrom, fbTo, ct);
        await Progress(55);

        var dollarAnalysis = await _repo.GetClinicDollarAnalysisAsync(
            connStr, dbLabName, clinics, reps, payers, panels, dosFrom, dosTo, fbFrom, fbTo, ct);
        await Progress(65);

        var dosCountVm = await _repo.GetClinicDosCountAsync(
            connStr, dbLabName, clinics, reps, payers, panels, dosFrom, dosTo, fbFrom, fbTo, ct);
        await Progress(75);

        using var workbook = ClinicSummaryExcelExportBuilder.CreateWorkbook(
            rows, totals,
            result.TopCollectedClinics, result.TopCollectedSalesReps,
            result.TopCollectedPayers, result.TopCollectedPanels,
            result.TopDeniedClinics, result.TopDeniedSalesReps,
            result.TopDeniedPayers, result.TopDeniedPanels,
            job.LabName,
            panelStatus: panelStatusVm,
            dollarAnalysis: dollarAnalysis,
            dosCount: dosCountVm,
            activeFilters: new List<(string, IReadOnlyList<string>?)>
            {
                ("Clinic", clinics),
                ("Sales Rep", reps),
                ("Payer", payers),
                ("Panel", panels),
                ("DOS From", Single(f.DosFrom)),
                ("DOS To", Single(f.DosTo)),
                ("First Bill From", Single(f.FirstBillFrom)),
                ("First Bill To", Single(f.FirstBillTo)),
            });
        await Progress(88);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        try
        {
            using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
                workbook.SaveAs(fs);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "ClinicSummary {ReportId} [{Lab}]: {Rows:N0} clinics, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, rows.Count, size, targetPath);
        await Progress(100);

        return new GeneratedReportFile(fileName, targetPath, size, rows.Count);
    }

    private static List<string>? NonEmpty(List<string>? values)
    {
        var list = values?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList();
        return list is { Count: > 0 } ? list : null;
    }

    private static string[]? Single(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : [value];

    private static DateOnly? ParseDate(string? value) =>
        DateOnly.TryParse(value, out var d) && d != default ? d : null;
}
