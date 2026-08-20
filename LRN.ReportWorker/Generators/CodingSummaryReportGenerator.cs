using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Coding Summary Excel export — same datasets and
/// CodingExcelExportBuilder the Coding/Summary page uses for
/// its synchronous ExportCodingExcel download.
/// When <c>Avgs</c> is configured for the lab, packages Excel + average CSVs as a ZIP.
/// </summary>
public sealed class CodingSummaryReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.CodingSummary;

    private readonly LabSettings _labSettings;
    private readonly ICodingValidationRepository _repo;
    private readonly LabCsvFileResolver _fileResolver;
    private readonly IConfiguration _configuration;
    private readonly ILogger<CodingSummaryReportGenerator> _logger;

    public CodingSummaryReportGenerator(
        LabSettings labSettings,
        ICodingValidationRepository repo,
        LabCsvFileResolver fileResolver,
        IConfiguration configuration,
        ILogger<CodingSummaryReportGenerator> logger)
    {
        _labSettings    = labSettings;
        _repo           = repo;
        _fileResolver   = fileResolver;
        _configuration  = configuration;
        _logger         = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig)
            || !labConfig.EnableCoding
            || !labConfig.DBEnabled
            || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
        {
            throw new InvalidOperationException(
                $"Coding Summary is not available for '{job.LabName}'.");
        }

        // Filter contract is validated at queue time; export is currently full-lab.
        _ = CodingSummaryFilters.FromJson(job.FilterDetailsJson);

        var connStr   = labConfig.DbConnectionString;
        var dbLabName = string.IsNullOrWhiteSpace(labConfig.DbLabName) ? job.LabName : labConfig.DbLabName;

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        await Progress(5);

        var tInsights     = _repo.GetYtdInsightsAsync(connStr, dbLabName, ct);
        var tSummaries    = _repo.GetYtdSummaryAsync(connStr, dbLabName, ct);
        var tWtdInsights  = _repo.GetWtdInsightsAsync(connStr, dbLabName, ct);
        var tWtdSummaries = _repo.GetWtdSummaryAsync(connStr, dbLabName, ct);
        var tFinancial    = _repo.GetFinancialSummaryAsync(connStr, ct);
        // CVDETAIL-ALL (2026-07-27): export uses the uncapped proc (all weeks, no TOP 5000).
        var tDetail       = _repo.GetValidationDetailExportRowsAsync(connStr, ct);
        await Task.WhenAll(tInsights, tSummaries, tWtdInsights, tWtdSummaries, tFinancial, tDetail);
        await Progress(70);

        var insights     = tInsights.Result;
        var summaries    = tSummaries.Result;
        var wtdInsights  = tWtdInsights.Result;
        var wtdSummaries = tWtdSummaries.Result;
        var financial    = tFinancial.Result;
        var detail       = tDetail.Result;

        var vm = new CodingSummaryViewModel
        {
            LabName        = job.LabName,
            InsightRows    = insights,
            SummaryRows    = summaries,
            WtdInsightRows = wtdInsights,
            WtdSummaryRows = wtdSummaries,
            FinancialRows  = financial,
            DetailRows     = detail,
        };

        var logicTemplatePath = _configuration["CodingSummary:CalculationLogicTemplatePath"];
        using var workbook = CodingExcelExportBuilder.CreateWorkbook(
            vm, job.LabName, logicTemplatePath);
        var sheetNames = string.Join(", ", workbook.Worksheets.Select(w => w.Name));
        _logger.LogInformation(
            "CodingSummary {ReportId} [{Lab}]: sheets=[{Sheets}]; CalculationLogic={HasLogic}; template={Path}",
            job.ReportId, job.LabName, sheetNames,
            workbook.Worksheets.Contains(CodingCalculationLogicTemplate.SheetName),
            string.IsNullOrWhiteSpace(logicTemplatePath) ? "(embedded)" : logicTemplatePath);
        await using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        var excelBytes = stream.ToArray();
        await Progress(90);

        var averages = _fileResolver.ResolveCodingAverageFiles(job.LabName);
        byte[] outputBytes;
        string outFileName;
        string outPath;

        if (CodingExportPackageBuilder.ShouldPackage(averages))
        {
            var excelEntryName = Path.ChangeExtension(fileName, ".xlsx") ?? fileName;
            outputBytes = CodingExportPackageBuilder.BuildZip(excelBytes, excelEntryName, averages);
            outFileName = Path.ChangeExtension(fileName, ".zip") ?? (fileName + ".zip");
            outPath = Path.ChangeExtension(targetPath, ".zip") ?? (targetPath + ".zip");
            _logger.LogInformation(
                "CodingSummary package [{Lab}]: Excel + Cpt={HasCpt} Panel={HasPanel}",
                job.LabName,
                !string.IsNullOrWhiteSpace(averages.CptAveragePath),
                !string.IsNullOrWhiteSpace(averages.PanelAveragePath));
        }
        else
        {
            outputBytes = excelBytes;
            outFileName = fileName;
            outPath = targetPath;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
        var tempPath = outPath + ".tmp";
        try
        {
            await File.WriteAllBytesAsync(tempPath, outputBytes, ct);
            File.Move(tempPath, outPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }

        var size = new FileInfo(outPath).Length;
        var rowCount = insights.Count + summaries.Count + wtdInsights.Count
                     + wtdSummaries.Count + financial.Count + detail.Count;

        _logger.LogInformation(
            "CodingSummary {ReportId} [{Lab}]: {Rows:N0} rows, {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, rowCount, size, outPath);
        await Progress(100);

        return new GeneratedReportFile(outFileName, outPath, size, rowCount);
    }
}
