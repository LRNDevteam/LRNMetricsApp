using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.ReportSnapshots;
using LabMetricsDashboard.ViewModels;
using LRN.ProductionReports.Models;
using LRN.ProductionReports.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// A past week's report from Master Values &gt; Report Snapshots: the report's own Excel workbook, written by
/// the same builder as the live download, from the view model the snapshot captured that week - so the file
/// holds exactly what the page showed for that run, whatever the lab database holds today.
/// <list type="bullet">
///   <item>Only the report's summary sheets. The raw claim / line / LIMS extracts are the master data
///         snapshots (Line Level, Claim Level, LIMS), and the Denial claim-level sheet is live data.</item>
///   <item>No Insights sheet and no Executive Summary highlight tabs: both read the lab database today.</item>
/// </list>
/// The web app resolves the snapshot file and checks the requester's lab before queueing; this only reads
/// the snapshot container (<see cref="IReportSnapshotFileStore"/>, MasterDataSnapshot settings).
/// </summary>
public sealed class ReportSnapshotDownloadGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.ReportSnapshot;

    private readonly IReportSnapshotFileStore _store;
    private readonly ReportStorageOptions _storage;
    private readonly ILogger<ReportSnapshotDownloadGenerator> _logger;

    public ReportSnapshotDownloadGenerator(
        IReportSnapshotFileStore store,
        Microsoft.Extensions.Options.IOptions<ReportStorageOptions> storage,
        ILogger<ReportSnapshotDownloadGenerator> logger)
    {
        _store   = store;
        _storage = storage.Value;
        _logger  = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        var f = ReportSnapshotFilters.FromJson(job.FilterDetailsJson);
        if (string.IsNullOrWhiteSpace(f.BlobPath))
            throw new InvalidOperationException("The historical report request names no snapshot file.");

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        var page = ReportPageSnapshotReader.Parse(await _store.ReadAsync(f.BlobPath, ct)).Bind();
        await Progress(30);

        var labName = string.IsNullOrWhiteSpace(page.LabKey) ? job.LabName : page.LabKey;
        var runId = f.RunId ?? page.RunId;
        var week = f.WeekFolder ?? page.WeekFolder;

        (fileName, targetPath) = ReportFilePathBuilder.BuildNamed(
            _storage.RootPath, job.ReportType, job.RequestedBy, DateTime.Now,
            ReportFilePathBuilder.ComposeName(Title(f.ReportCode ?? page.ReportCode).Replace(" ", ""), labName, runId, week));

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        var rows = 0;
        try
        {
            switch (page.BoundModel)
            {
                case PhiExecutiveSummaryViewModel es:
                    await File.WriteAllBytesAsync(tempPath, new ExecutiveSummaryExcelBuilder().Build(es), ct);
                    rows = es.Rows.Count;
                    break;

                case LisSummaryResult lis:
                    using (var wb = LisSummaryExcelExportBuilder.CreateWorkbook(
                               lis, lineData: null, labName, "", null, null, null, null, null, null, null))
                    {
                        // The LIMS Master sheet is the line-level extract: the master data snapshot (LIMS).
                        foreach (var ws in wb.Worksheets.Where(w => w.Name.Equals("LIMS Master", StringComparison.OrdinalIgnoreCase)).ToList())
                            ws.Delete();
                        Save(wb, tempPath);
                    }
                    break;

                case ProductionReportViewModel prod:
                    using (var wb = IsNorthWest(labName)
                               ? NorthWestProductionSummaryExcelExportBuilder.CreateWorkbook(prod, labName)
                               : ProductionReportExcelExportBuilder.CreateWorkbookSummaryOnly(prod, labName, week, runId))
                        Save(wb, tempPath);
                    rows = prod.PanelRows.Count;
                    break;

                case CollectionSummaryViewModel coll:
                    using (var wb = LabMetricsDashboard.Services.CollectionSummaryExcelExportBuilder.CreateWorkbook(coll, [], [], labName, f.ToActiveFilterList()))
                    {
                        foreach (var ws in wb.Worksheets.Where(w => w.Name is "ClaimLevelData" or "LineLevelData").ToList())
                            ws.Delete();
                        Save(wb, tempPath);
                    }
                    OpenXmlPivotCacheFix.Apply(tempPath);
                    break;

                case DenialClaimReportViewModel denial:
                    await AddInsightAsync(denial, f.InsightBlobPath, ct);
                    using (var wb = DenialClaimReportExcelBuilder.Build(denial))
                        Save(wb, tempPath);
                    rows = denial.TotalClaims;
                    break;

                default:
                    throw new InvalidOperationException($"The {Title(page.ReportCode)} snapshot ({page.ModelType}) has no Excel workbook.");
            }
            await Progress(90);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "ReportSnapshot {ReportId} [{Lab}]: {Code} of {RunId} ({Week}), {Size:N0} bytes → {Path}",
            job.ReportId, labName, page.ReportCode, runId, week, size, targetPath);
        await Progress(100);

        return new GeneratedReportFile(fileName, targetPath, size, rows);
    }

    /// <summary>The run's Denial Insight upload as the workbook's Denial Insight sheet (Current Week).</summary>
    private async Task AddInsightAsync(DenialClaimReportViewModel model, string? insightBlobPath, CancellationToken ct)
    {
        model.Insight ??= new DenialInsightPanelViewModel();
        model.Insight.CurrentLab = model.CurrentLab;
        model.Insight.CanEdit = false;
        model.Insight.Rows = [];
        if (string.IsNullOrWhiteSpace(insightBlobPath)) return;
        try
        {
            if (ReportPageSnapshotReader.Parse(await _store.ReadAsync(insightBlobPath, ct)).Bind().BoundModel is DenialInsightSnapshotModel insight)
            {
                model.Insight.Rows = insight.CurrentWeek;
                model.Insight.BucketCounts = insight.BucketCounts;
                model.Insight.CurrentWeekStart = insight.CurrentWeekStart;
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The summary sheets stand on their own; the sheet then says it has no rows.
            _logger.LogWarning(ex, "Denial Insight snapshot {Path} could not be read; the workbook goes without it.", insightBlobPath);
        }
    }

    private static void Save(XLWorkbook wb, string path)
    {
        using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        wb.SaveAs(fs);
    }

    private static bool IsNorthWest(string labName) =>
        labName.Equals("NorthWest", StringComparison.OrdinalIgnoreCase)
        || labName.Equals("NWL", StringComparison.OrdinalIgnoreCase);

    private static string Title(string? code) => ReportSnapshotViewContext.Title(code ?? "");
}
