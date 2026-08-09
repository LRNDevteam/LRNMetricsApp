using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using LRN.ReportQueue.Shared;
using Microsoft.Data.SqlClient;
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
    /// A repository bound to THIS lab's own database.
    ///
    /// dbo.DenialTaskBoard / DenialLineItem / DenialInsight live in the lab database, which
    /// the queue already handed us as <paramref name="lab"/> — so pointing the repository
    /// straight at it skips the LRNMaster lookup and the ConnectionStrings:{ConnectionKey}
    /// indirection the web app uses. That keeps this worker free of any master-database
    /// configuration, which its deployment does not have.
    ///
    /// Resolved per job (transient), never constructor-injected: every IReportGenerator is
    /// built while the host starts, so a resolution failure here must not abort the service.
    /// </summary>
    private SqlDenialRecordRepository CreateRepository(LabDbConfig lab)
    {
        if (string.IsNullOrWhiteSpace(lab.DbConnectionString))
            throw new InvalidOperationException(
                $"Lab '{lab.LabName}' has no DbConnectionString in its config JSON — " +
                "Denial Dashboard reports read the denial tables from the lab's own database.");

        var repo = _services.GetRequiredService<SqlDenialRecordRepository>();
        repo.LabConnectionResolver = _ => lab.DbConnectionString;
        return repo;
    }

    /// <summary>
    /// Fails loudly when the lab database has no denial tables. Without this the repository's
    /// own "table missing → empty list" guards would hand the user a silently empty workbook
    /// instead of telling them the data is not where the worker looked.
    /// </summary>
    private static async Task EnsureDenialTablesAsync(LabDbConfig lab, CancellationToken ct)
    {
        const string sql = @"
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'DenialLineItem'
) THEN 1 ELSE 0 END;";

        await using var connection = new SqlConnection(lab.DbConnectionString);
        await connection.OpenAsync(ct);
        await using var command = new SqlCommand(sql, connection) { CommandTimeout = 60 };
        var exists = Convert.ToInt32(await command.ExecuteScalarAsync(ct)) == 1;

        if (!exists)
            throw new InvalidOperationException(
                $"dbo.DenialLineItem was not found in lab '{lab.LabName}'s database. " +
                "Denial Dashboard reports read the denial tables from the lab database configured " +
                "in that lab's config JSON (DbConnectionString); point it at the database holding " +
                "DenialLineItem / DenialTaskBoard / DenialInsight for this lab.");
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
        var repo = CreateRepository(lab);
        await EnsureDenialTablesAsync(lab, ct);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        // Display name only. The lab list lives in LRNMaster, which this worker may have no
        // connection to — the queue's own lab name is a fine substitute when it doesn't.
        var labName = job.LabName;
        try
        {
            var labs = await repo.GetLabsAsync(ct);
            labName = labs.FirstOrDefault(x => x.LabId == labId)?.LabName ?? job.LabName;
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex,
                "Report {ReportId}: LRNMetricsLab lookup unavailable; using the queue's lab name '{Lab}'.",
                job.ReportId, job.LabName);
        }

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
            // The five summary sheets are small — ClosedXML handles them. The Line Item sheet
            // is not: ClosedXML buffers a whole sheet's XML in a MemoryStream when saving and
            // throws "Stream was too long" past 2 GB, which a wide lab with large ICD code
            // lists reaches. Stream that one in afterwards at bounded memory instead.
            using (var workbook = DenialDashboardExcelExportBuilder.CreateWorkbook(exportData, includeLineItemSheet: false))
            using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                workbook.SaveAs(fs);
            }
            await Progress(85);

            var lineSheet = DenialDashboardExcelExportBuilder.BuildLineItemSheetData(exportData);
            await OpenXmlRowStreamer.AppendRowsToWorkbookAsync(
                tempPath,
                DenialDashboardExcelExportBuilder.LineItemSheetName,
                lineSheet.Headers,
                lineSheet.Rows,
                onRowsProgress: null,
                ct);

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
