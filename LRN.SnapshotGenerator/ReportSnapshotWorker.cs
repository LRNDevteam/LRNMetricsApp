using Microsoft.Extensions.Options;

namespace LRN.SnapshotGenerator;

/// <summary>
/// Checks dbo.ReportSnapshotRequest every ReportSnapshot:RequestPollSeconds (Denial Insight uploads) and
/// ReportsWorkflowTracker every ReportSnapshot:PollMinutes, and captures what is new.
/// </summary>
public sealed class ReportSnapshotWorker : BackgroundService
{
    private readonly ReportSnapshotService _service;
    private readonly ReportSnapshotOptions _options;
    private readonly ILogger<ReportSnapshotWorker> _logger;

    public ReportSnapshotWorker(ReportSnapshotService service, IOptions<ReportSnapshotOptions> options, ILogger<ReportSnapshotWorker> logger)
    {
        _service = service;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled)
        {
            _logger.LogWarning("Report snapshots are disabled (ReportSnapshot:Enabled = false). Nothing will be captured.");
            return;
        }

        var trackerEvery = TimeSpan.FromMinutes(Math.Max(1, _options.PollMinutes));
        var requestEvery = TimeSpan.FromSeconds(Math.Clamp(_options.RequestPollSeconds, 15, (int)trackerEvery.TotalSeconds));
        _logger.LogInformation("Report snapshots: checking ReportsWorkflowTracker every {Minutes} minute(s) and upload requests every {Seconds} second(s).",
            _options.PollMinutes, (int)requestEvery.TotalSeconds);

        var nextTrackerPoll = DateTime.UtcNow;
        using var timer = new PeriodicTimer(requestEvery);
        try
        {
            do
            {
                if (DateTime.UtcNow >= nextTrackerPoll)
                {
                    nextTrackerPoll = DateTime.UtcNow + trackerEvery;
                    await RunAsync("Tracker", () => _service.PollTrackerAsync(stoppingToken));
                }
                await RunAsync("Request", () => _service.ProcessRequestsAsync(ignoreSettle: false, stoppingToken));
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException)
        {
            // shutdown
        }
    }

    private async Task RunAsync(string what, Func<Task> poll)
    {
        try
        {
            await poll();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // LRNMaster unreachable, tracker query failed, ...: log and try again next poll.
            _logger.LogError(ex, "Report snapshot {What} poll failed.", what);
        }
    }
}
