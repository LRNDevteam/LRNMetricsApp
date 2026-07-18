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
/// Async Prediction Analysis export. Reuses the web app's
/// PredictionController.BuildPredictionViewModelAsync (same stored procedures:
/// summary buckets, metrics, payer/pay-status/adjusted breakdowns, denial and
/// no-response breakdowns) and PredictionExcelExportBuilder — the workbook is
/// byte-for-byte the same as the synchronous export, just generated off-request.
/// </summary>
public sealed class PredictionAnalysisReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.PredictionAnalysis;

    private readonly IServiceProvider _services;
    private readonly LabSettings _labSettings;
    private readonly ILogger<PredictionAnalysisReportGenerator> _logger;

    public PredictionAnalysisReportGenerator(
        IServiceProvider services,
        LabSettings labSettings,
        ILogger<PredictionAnalysisReportGenerator> logger)
    {
        _services    = services;
        _labSettings = labSettings;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not configured.");

        var f = PredictionAnalysisFilters.FromJson(job.FilterDetailsJson);
        if (reportProgressAsync is not null) await reportProgressAsync(10);

        // Controller hosted outside a request: give it an empty HttpContext so
        // HttpContext.RequestAborted etc. resolve safely.
        var controller = _services.GetRequiredService<PredictionController>();
        controller.ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() };

        var vm = await controller.BuildPredictionViewModelAsync(
            job.LabName, labConfig,
            f.PayerName, f.PayerType, f.PanelName,
            f.FinalCoverageStatus, f.Payability, f.CPTCode,
            f.ForecastingPayability, f.PayStatus,
            f.ForecastingPayabilitySubstatus, f.PredictionStatus);

        if (reportProgressAsync is not null) await reportProgressAsync(60);

        using var workbook = PredictionExcelExportBuilder.CreateWorkbook(
            vm, job.LabName, activeFilters: f.ToActiveFilterList());

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
            "PredictionAnalysis {ReportId} [{Lab}]: {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, RowCount: 0);
    }
}
