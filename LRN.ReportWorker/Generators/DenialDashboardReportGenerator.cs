using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Denial Dashboard export — one sheet per exported tab, in tab order:
/// Monthly Breakdown, Weekly Breakdown, Filter Panel, SLA Tracker, Denial Insight, Line Item.
///
/// Every figure comes from DenialDashboardController's own helpers over the same
/// IDenialRecordRepository queries the page uses, so a queued workbook matches what the
/// user was looking at when they pressed Download. The Line Item sheet additionally
/// carries each denial's Denial Workflow state — Assigned To, Workflow Status and the
/// reviewer's notes — joined from dbo.DenialTaskBoard by
/// <see cref="DenialWorkflowLineItemAnnotator"/>.
/// </summary>
public sealed class DenialDashboardReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.DenialDashboard;

    private readonly IServiceProvider _services;
    private readonly ILogger<DenialDashboardReportGenerator> _logger;

    public DenialDashboardReportGenerator(
        IServiceProvider services,
        ILogger<DenialDashboardReportGenerator> logger)
    {
        _services = services;
        _logger = logger;
    }

    /// <summary>
    /// Resolved per job, never in the constructor. SqlDenialRecordRepository throws from its
    /// OWN constructor when ConnectionStrings:DefaultConnection is absent, and every
    /// IReportGenerator is built while the host starts — constructor-injecting it would
    /// abort the whole service on a deployment that sources its connection strings
    /// elsewhere. Resolving here keeps that failure inside the one report that needs it.
    /// </summary>
    private IDenialRecordRepository ResolveRepository()
    {
        try
        {
            return _services.GetRequiredService<IDenialRecordRepository>();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "Denial Dashboard reports need the denial databases configured for LRN.ReportWorker: " +
                "ConnectionStrings:DefaultConnection (dbo.LRNMetricsLab) plus each lab's ConnectionKey entry. " +
                $"Other report types are unaffected. Underlying error: {ex.Message}", ex);
        }
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        var f = DenialDashboardReportFilters.FromJson(job.FilterDetailsJson);
        if (f.LabId is not > 0)
            throw new InvalidOperationException(
                $"Denial Dashboard report {job.ReportId} has no LabId — the page must post the dashboard's numeric lab id.");

        var labId = f.LabId.Value;
        var repo = ResolveRepository();

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        var labs = await repo.GetLabsAsync(ct);
        var labName = labs.FirstOrDefault(x => x.LabId == labId)?.LabName ?? job.LabName;

        // Same normalization the page applies before it queries anything, so "(All)" and
        // pipe-delimited multi-selects behave identically here.
        var filters = DenialDashboardController.Normalize(ToDashboardFilters(f), labId);
        await Progress(5);

        var runId = await repo.GetCurrentRunIdAsync(labId, ct) ?? string.Empty;
        var taskRecords = await repo.GetByLabAsync(labId, ct);
        await Progress(20);

        var insights = (await repo.GetInsightTableByLabAsync(labId, ct)).ToList();
        await Progress(30);

        var breakdownSource = (await repo.GetBreakdownSourceByLabAsync(labId, filters, ct)).ToList();
        await Progress(45);

        var lineItems = (await repo.GetLineItemsForExportByLabAsync(labId, filters, ct)).ToList();
        await Progress(70);

        var exportData = DenialDashboardController.BuildExportData(
            labName, runId, filters, taskRecords, lineItems, insights, breakdownSource,
            f.ToActiveFilterList());
        await Progress(80);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        try
        {
            using (var workbook = DenialDashboardExcelExportBuilder.CreateWorkbook(exportData))
            using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                workbook.SaveAs(fs);
            }

            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { }
            throw;
        }

        await Progress(95);

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "DenialDashboard {ReportId} [{Lab} #{LabId}, run {RunId}]: {Lines:N0} line items, " +
            "{Tasks:N0} filtered tasks, {Insights:N0} insights, {Size:N0} bytes → {Path}",
            job.ReportId, labName, labId, string.IsNullOrWhiteSpace(runId) ? "-" : runId,
            lineItems.Count, exportData.TaskRecords.Count, insights.Count, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, lineItems.Count);
    }

    /// <summary>Rebuilds the page's own filter object from the queued snapshot.</summary>
    private static DenialDashboardFilters ToDashboardFilters(DenialDashboardReportFilters f) => new()
    {
        LabId = f.LabId,
        DenialCode = f.DenialCode ?? string.Empty,
        Status = Choice(f.Status),
        Priority = Choice(f.Priority),
        ActionCategory = Choice(f.ActionCategory),
        Deadline = Choice(f.Deadline),
        Classification = Choice(f.Classification),
        SalesRepname = f.SalesRepname ?? string.Empty,
        ClinicName = f.ClinicName ?? string.Empty,
        ReferringProvider = f.ReferringProvider ?? string.Empty,
        PayerName = f.PayerName ?? string.Empty,
        PayerType = f.PayerType ?? string.Empty,
        PanelName = f.PanelName ?? string.Empty,
        FirstBilledDateFrom = ParseDate(f.FirstBilledDateFrom),
        FirstBilledDateTo = ParseDate(f.FirstBilledDateTo),
        DateOfServiceFrom = ParseDate(f.DateOfServiceFrom),
        DateOfServiceTo = ParseDate(f.DateOfServiceTo),
        DenialDateFrom = ParseDate(f.DenialDateFrom),
        DenialDateTo = ParseDate(f.DenialDateTo),
    };

    /// <summary>Blank multi-choice filters mean "(All)" — the page's no-filter sentinel.</summary>
    private static string Choice(string? value) =>
        string.IsNullOrWhiteSpace(value) ? "(All)" : value;

    private static DateTime? ParseDate(string? value) =>
        DateTime.TryParse(value, out var d) && d != default ? d.Date : null;
}
