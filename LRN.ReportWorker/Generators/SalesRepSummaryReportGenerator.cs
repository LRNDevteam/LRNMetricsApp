using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Sales Rep Summary export — same ISalesRepSummaryRepository query and
/// SalesRepSummaryExcelExportBuilder (green ExcelTheme) that
/// DashboardController.ExportSalesRepSummaryExcel uses synchronously.
/// </summary>
public sealed class SalesRepSummaryReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.SalesRepSummary;

    private readonly LabSettings _labSettings;
    private readonly ISalesRepSummaryRepository _repo;
    private readonly ILogger<SalesRepSummaryReportGenerator> _logger;

    public SalesRepSummaryReportGenerator(
        LabSettings labSettings,
        ISalesRepSummaryRepository repo,
        ILogger<SalesRepSummaryReportGenerator> logger)
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
            throw new InvalidOperationException($"Sales Rep Summary is not available for '{job.LabName}'.");

        var connStr   = config.DbConnectionString;
        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? job.LabName : config.DbLabName;
        var f = ClinicSalesRepSummaryFilters.FromJson(job.FilterDetailsJson);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }
        await Progress(5);

        // Same normalization/date semantics as the synchronous action.
        var reps    = NonEmpty(f.SalesRepNames);
        var clinics = NonEmpty(f.ClinicNames);
        var payers  = NonEmpty(f.PayerNames);
        var panels  = NonEmpty(f.PanelNames);
        var dosFrom = ParseDate(f.DosFrom);
        var dosTo   = ParseDate(f.DosTo);
        var fbFrom  = ParseDate(f.FirstBillFrom);
        var fbTo    = ParseDate(f.FirstBillTo);

        var result = await _repo.GetSalesRepSummaryAsync(
            connStr, dbLabName, reps, clinics, payers, panels, dosFrom, dosTo, fbFrom, fbTo, ct);
        await Progress(60);

        var rows = result.Rows;
        var totals = new SalesRepSummaryRow
        {
            SalesRepName                = "Grand Total",
            BilledClaimCount            = rows.Sum(r => r.BilledClaimCount),
            PaidClaimCount              = rows.Sum(r => r.PaidClaimCount),
            DeniedClaimCount            = rows.Sum(r => r.DeniedClaimCount),
            OutstandingClaimCount       = rows.Sum(r => r.OutstandingClaimCount),
            TotalBilledCharges          = rows.Sum(r => r.TotalBilledCharges),
            TotalAllowedAmount          = rows.Sum(r => r.TotalAllowedAmount),
            TotalInsurancePaidAmount    = rows.Sum(r => r.TotalInsurancePaidAmount),
            TotalPatientResponsibility  = rows.Sum(r => r.TotalPatientResponsibility),
            TotalDeniedCharges          = rows.Sum(r => r.TotalDeniedCharges),
            TotalOutstandingCharges     = rows.Sum(r => r.TotalOutstandingCharges),
            AverageAllowedAmount        = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageAllowedAmount), 2),
            AverageInsurancePaidAmount  = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageInsurancePaidAmount), 2),
        };

        using var workbook = SalesRepSummaryExcelExportBuilder.CreateWorkbook(
            rows, totals,
            result.TopCollectedSalesReps, result.TopCollectedClinics,
            result.TopCollectedPayers, result.TopCollectedPanels,
            result.TopDeniedSalesReps, result.TopDeniedClinics,
            result.TopDeniedPayers, result.TopDeniedPanels,
            job.LabName,
            activeFilters: new List<(string, IReadOnlyList<string>?)>
            {
                ("Sales Rep", reps),
                ("Clinic", clinics),
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
            "SalesRepSummary {ReportId} [{Lab}]: {Rows:N0} sales reps, {Size:N0} bytes → {Path}",
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
