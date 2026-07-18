using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Revenue Dashboard export — same IDashboardRepository query and
/// DashboardExcelExportBuilder (green ExcelTheme, matching the Prediction
/// summary) that DashboardController.ExportDashboardExcel uses synchronously.
///
/// DB path only: the queue is available only for DB-enabled labs, so the
/// controller's CSV fallback branch is intentionally not replicated here —
/// CSV-only labs keep using the legacy synchronous download.
/// </summary>
public sealed class RevenueDashboardReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.RevenueDashboard;

    private readonly LabSettings _labSettings;
    private readonly IDashboardRepository _repo;
    private readonly ILogger<RevenueDashboardReportGenerator> _logger;

    public RevenueDashboardReportGenerator(
        LabSettings labSettings,
        IDashboardRepository repo,
        ILogger<RevenueDashboardReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not configured.");
        if (!labConfig.LineClaimEnable || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException(
                $"Revenue Dashboard async export requires the claim/line database for '{job.LabName}'.");

        var connStr   = labConfig.DbConnectionString;
        var dbLabName = string.IsNullOrWhiteSpace(labConfig.DbLabName) ? job.LabName : labConfig.DbLabName;
        var f = RevenueDashboardFilters.FromJson(job.FilterDetailsJson);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }
        await Progress(5);

        // Same normalization/date semantics as BuildDashboardViewModelAsync (DB branch).
        var payerNames = Normalize(f.PayerNames);
        var panelNames = Normalize(f.PanelNames);
        DateOnly.TryParse(f.DosFrom, out var dosFrom);
        DateOnly.TryParse(f.DosTo, out var dosTo);
        DateOnly.TryParse(f.FirstBillFrom, out var fbFrom);
        DateOnly.TryParse(f.FirstBillTo, out var fbTo);

        var r = await _repo.GetDashboardAsync(
            connStr, dbLabName,
            payerNames, f.PayerType, panelNames, f.ClinicName,
            f.ReferringProvider,
            dosFrom != default ? dosFrom : null,
            dosTo   != default ? dosTo   : null,
            fbFrom  != default ? fbFrom  : null,
            fbTo    != default ? fbTo    : null,
            ct);
        await Progress(60);

        var vm = new DashboardViewModel
        {
            SelectedLab          = job.LabName,
            FilterPayerName      = DisplayFilterValue(payerNames),
            FilterPayerType      = f.PayerType,
            FilterPanelName      = DisplayFilterValue(panelNames),
            FilterPayerNames     = payerNames ?? [],
            FilterPanelNames     = panelNames ?? [],
            FilterClinicName     = f.ClinicName,
            FilterReferringProvider = f.ReferringProvider,
            FilterDosFrom        = f.DosFrom,
            FilterDosTo          = f.DosTo,
            FilterFirstBillFrom  = f.FirstBillFrom,
            FilterFirstBillTo    = f.FirstBillTo,
            PayerNames           = r.PayerNames,
            PayerTypes           = r.PayerTypes,
            PanelNames           = r.PanelNames,
            ClinicNames          = r.ClinicNames,
            ReferringProviders   = r.ReferringProviders,
            TotalClaims          = r.TotalClaims,
            TotalCharges         = r.TotalCharges,
            TotalPayments        = r.TotalPayments,
            TotalBalance         = r.TotalBalance,
            CollectionNumerator  = r.CollectionNumerator,
            DenialNumerator      = r.DenialNumerator,
            AdjustmentNumerator  = r.AdjustmentNumerator,
            OutstandingNumerator = r.OutstandingNumerator,
            ClaimStatusBreakdown = r.ClaimStatusRows.ToDictionary(s => s.Status, s => s.Claims),
            ClaimStatusRows      = r.ClaimStatusRows,
            TotalLines           = r.TotalLines,
            LineTotalCharges     = r.LineTotalCharges,
            LineTotalPayments    = r.LineTotalPayments,
            LineTotalBalance     = r.LineTotalBalance,
            TopCPTCharges        = r.TopCPTCharges,
            PayStatusBreakdown   = r.PayStatusBreakdown,
            PayerLevelInsights         = r.PayerLevelInsights,
            PanelLevelInsights         = r.PanelLevelInsights,
            ClinicLevelInsights        = r.ClinicLevelInsights,
            ReferringPhysicianInsights = r.ReferringPhysicianInsights,
            DOSMonthly                 = r.DOSMonthly,
            FirstBillMonthly           = r.FirstBillMonthly,
            PayerTypePayments          = r.PayerTypePayments,
            AvgAllowedMonths           = r.AvgAllowedMonths,
            AvgAllowedByPanelMonth     = r.AvgAllowedByPanelMonth,
            TopCptDetail               = r.TopCptDetail,
            SupportsAggregateMode      = labConfig.UseDBDashboard,
        };

        using var workbook = DashboardExcelExportBuilder.CreateWorkbook(vm, job.LabName);
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
            "RevenueDashboard {ReportId} [{Lab}]: {Claims:N0} claims summarized, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, r.TotalClaims, size, targetPath);
        await Progress(100);

        return new GeneratedReportFile(fileName, targetPath, size, r.TotalClaims);
    }

    private static List<string>? Normalize(IEnumerable<string>? values)
    {
        var list = values?
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        return list is { Count: > 0 } ? list : null;
    }

    private static string? DisplayFilterValue(IReadOnlyCollection<string>? values) => values switch
    {
        null or { Count: 0 } => null,
        { Count: 1 } => values.First(),
        _ => string.Join(", ", values),
    };
}
