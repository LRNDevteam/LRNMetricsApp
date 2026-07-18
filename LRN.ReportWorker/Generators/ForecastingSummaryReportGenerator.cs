using ClosedXML.Excel;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Forecasting Summary export. Mirrors ExportForecastingExcel exactly:
/// one slim dbo.usp_GetForecastingRecords fetch shared by the summary sheets
/// (via PredictionController.BuildForecastingViewModelAsync — same SPs, incl.
/// usp_GetForecastingSummaryByWeekRange) and the Data sheet, with dimension
/// filters applied in memory; workbook built by ForecastingExcelExportBuilder.
/// </summary>
public sealed class ForecastingSummaryReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.ForecastingSummary;

    private readonly IServiceProvider _services;
    private readonly LabSettings _labSettings;
    private readonly IPredictionDbRepository _dbRepo;
    private readonly ILogger<ForecastingSummaryReportGenerator> _logger;

    public ForecastingSummaryReportGenerator(
        IServiceProvider services,
        LabSettings labSettings,
        IPredictionDbRepository dbRepo,
        ILogger<ForecastingSummaryReportGenerator> logger)
    {
        _services    = services;
        _labSettings = labSettings;
        _dbRepo      = dbRepo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not configured.");
        if (!labConfig.DBEnabled || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not database-enabled.");

        var f = ForecastingSummaryFilters.FromJson(job.FilterDetailsJson);
        if (reportProgressAsync is not null) await reportProgressAsync(10);

        // Single slim fetch shared by summary sheets AND the Data sheet
        // (same optimization as the synchronous export).
        var slimRecords = await _dbRepo.GetForecastRecordsAsync(
            labConfig.DbConnectionString, cancellationToken: ct);

        if (reportProgressAsync is not null) await reportProgressAsync(35);

        var controller = _services.GetRequiredService<PredictionController>();
        controller.ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() };

        var vm = await controller.BuildForecastingViewModelAsync(job.LabName, labConfig, slimRecords);

        if (reportProgressAsync is not null) await reportProgressAsync(60);

        // Dimension filters applied in memory — identical to ExportForecastingExcel.
        var q = slimRecords.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(f.PayerName))
            q = q.Where(r => r.PayerNameNormalized.Equals(f.PayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(f.PayerType))
            q = q.Where(r => r.PayerType.Equals(f.PayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(f.PanelName))
            q = q.Where(r => r.PanelName.Equals(f.PanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(f.CPTCode))
            q = q.Where(r => r.CPTCode.Equals(f.CPTCode, StringComparison.OrdinalIgnoreCase));
        var exportRecords = q.ToList();

        var activeFilters = f.ToActiveFilterList();
        using var workbook = ForecastingExcelExportBuilder.CreateWorkbook(
            vm, job.LabName, activeFilters.Count > 0 ? activeFilters : null, exportRecords);

        if (reportProgressAsync is not null) await reportProgressAsync(90);

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
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { }
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "ForecastingSummary {ReportId} [{Lab}]: {Rows:N0} detail rows, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, exportRecords.Count, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, exportRecords.Count);
    }
}
