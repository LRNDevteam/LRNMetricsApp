using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services.DenialDashboard;

/// <summary>Bound from appsettings "DenialDashboardSnapshots" (the scheduling half; retention lives server-side in LRN.ReportsApi).</summary>
public sealed class DenialDashboardSnapshotSchedulerOptions
{
    public bool ScheduleEnabled { get; set; } = true;
    public int CheckIntervalMinutes { get; set; } = 60;
}

/// <summary>
/// Period math for Denial Dashboard snapshots - a weekly snapshot is "the week that just ended"
/// (Monday-Sunday), a monthly one is the month that just ended. Deliberately not back-filled: a
/// snapshot is the state at capture time, and a week captured late would present today's numbers
/// under last week's label. Mirrors LRN.ReportsApi's DenialSummarySchedule (a sibling feature); kept
/// as its own copy here per this codebase's convention of small per-app duplicates for this kind of
/// pure helper rather than a new shared project.
/// </summary>
internal static class DenialDashboardSnapshotSchedule
{
    public static (DateTime Start, DateTime End) LastCompletedWeek(DateTime today)
    {
        var date = today.Date;
        var daysSinceMonday = ((int)date.DayOfWeek + 6) % 7;
        var thisMonday = date.AddDays(-daysSinceMonday);
        return (thisMonday.AddDays(-7), thisMonday.AddDays(-1));
    }

    public static (DateTime Start, DateTime End) LastCompletedMonth(DateTime today)
    {
        var firstOfThisMonth = new DateTime(today.Year, today.Month, 1);
        return (firstOfThisMonth.AddMonths(-1), firstOfThisMonth.AddDays(-1));
    }
}

/// <summary>
/// Hourly pass that captures each lab's completed week and month once. Mirrors LRN.ReportsApi's
/// DenialSummarySnapshotScheduler, but this feature's workbook builder
/// (DenialDashboardExcelExportBuilder) lives in this project, not the API - so unlike the sibling
/// feature, the scheduler here builds the workbook itself and POSTs the finished bytes to the API's
/// api/denial-dashboard/snapshots endpoint, which only stores them and applies retention.
/// </summary>
public sealed class DenialDashboardSnapshotScheduler : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly DenialDashboardSnapshotSchedulerOptions _options;
    private readonly ILogger<DenialDashboardSnapshotScheduler> _logger;

    public DenialDashboardSnapshotScheduler(IServiceScopeFactory scopeFactory, IOptions<DenialDashboardSnapshotSchedulerOptions> options, ILogger<DenialDashboardSnapshotScheduler> logger)
    {
        _scopeFactory = scopeFactory;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.ScheduleEnabled)
        {
            _logger.LogInformation("Denial Dashboard snapshot schedule is disabled (DenialDashboardSnapshots:ScheduleEnabled).");
            return;
        }

        try { await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken); }
        catch (OperationCanceledException) { return; }

        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(Math.Max(5, _options.CheckIntervalMinutes)));
        try
        {
            do
            {
                try
                {
                    using var scope = _scopeFactory.CreateScope();
                    var api = scope.ServiceProvider.GetRequiredService<IDenialDashboardApiClient>();
                    var taken = await RunOnceAsync(api, stoppingToken);
                    if (taken > 0)
                        _logger.LogInformation("Denial Dashboard snapshot scheduler captured {Count} snapshot(s).", taken);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _logger.LogError(ex, "Denial Dashboard snapshot pass failed.");
                }
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException)
        {
            // shutdown
        }
    }

    private static async Task<int> RunOnceAsync(IDenialDashboardApiClient api, CancellationToken ct)
    {
        var today = DateTime.Now.Date;
        var week = DenialDashboardSnapshotSchedule.LastCompletedWeek(today);
        var month = DenialDashboardSnapshotSchedule.LastCompletedMonth(today);
        var taken = 0;

        var labs = await api.GetLabsAsync(ct);
        foreach (var lab in labs)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                if (await CaptureIfMissingAsync(api, lab.LabId, lab.LabName, "Weekly", week.Start, week.End, ct)) taken++;
                if (await CaptureIfMissingAsync(api, lab.LabId, lab.LabName, "Monthly", month.Start, month.End, ct)) taken++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // One lab's unreachable database (via the API) must not stop the others being captured.
                System.Diagnostics.Trace.TraceError($"Denial Dashboard snapshot failed for lab {lab.LabId} ({lab.LabName}): {ex}");
            }
        }

        return taken;
    }

    private static async Task<bool> CaptureIfMissingAsync(IDenialDashboardApiClient api, int labId, string labName, string periodType, DateTime periodStart, DateTime periodEnd, CancellationToken ct)
    {
        // Cheap existence check before doing the work of building a workbook nobody will store.
        if (await api.InsightSnapshotPeriodExistsAsync(labId, periodType, periodStart, ct)) return false;

        var info = await DenialDashboardSnapshotBuilder.BuildAndSaveAsync(api, labId, labName, periodType, periodStart, periodEnd, "Scheduler", ct);
        return info is not null;
    }
}

/// <summary>
/// Builds the Monthly Summary + Weekly Summary + Denial Insight workbook for one lab (unfiltered -
/// a snapshot is the lab's position at a point in time, not a viewer's current filters) and saves it
/// through the API. Shared by the scheduler above and the on-demand "Save Snapshot Now" action on
/// DenialDashboardController.
/// </summary>
internal static class DenialDashboardSnapshotBuilder
{
    public static async Task<DenialDashboardSnapshotInfo?> BuildAndSaveAsync(
        IDenialDashboardApiClient api, int labId, string labName, string periodType, DateTime periodStart, DateTime periodEnd, string createdBy, CancellationToken ct)
    {
        var filters = new DenialDashboardFilters { LabId = labId };
        var allRecords = await api.GetByLabAsync(labId, ct);
        var lineItems = (await api.GetLineItemsForExportByLabAsync(labId, filters, ct)).ToList();
        var insights = (await api.GetInsightTableByLabAsync(labId, ct)).ToList();
        var breakdownSource = (await api.GetBreakdownSourceByLabAsync(labId, filters, ct)).ToList();
        var runId = await api.GetCurrentRunIdAsync(labId, ct) ?? string.Empty;

        var exportData = DenialDashboardController.BuildExportData(labName, runId, filters, allRecords, lineItems, insights, breakdownSource);

        var safeLabName = new string(labName.Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray()).Trim('_');
        var fileName = periodType switch
        {
            "Weekly" => $"{safeLabName}_DenialDashboard_Weekly_{periodStart:yyyyMMdd}-{periodEnd:yyyyMMdd}.xlsx",
            "Monthly" => $"{safeLabName}_DenialDashboard_Monthly_{periodStart:yyyy-MM}.xlsx",
            _ => $"{safeLabName}_DenialDashboard_{DateTime.Now:yyyyMMdd_HHmm}.xlsx"
        };

        using var workbook = DenialDashboardExcelExportBuilder.CreateWorkbook(exportData, fileName: fileName);
        await using var stream = new MemoryStream();
        workbook.SaveAs(stream);

        return await api.SaveInsightSnapshotAsync(labId, periodType, periodStart, periodEnd, fileName, stream.ToArray(), createdBy, ct);
    }
}
