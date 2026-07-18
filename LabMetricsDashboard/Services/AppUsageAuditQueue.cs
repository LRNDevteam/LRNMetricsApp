using System.Threading.Channels;

namespace LabMetricsDashboard.Services;

/// <summary>One captured page-view, ready to be written to dbo.AppUsageAudit.</summary>
public sealed record PageVisitAuditEntry(
    string UserName,
    string BrowserId,
    string TabId,
    string PageName,
    string Path,
    string QueryString,
    string IpAddress,
    string UserAgent);

/// <summary>
/// Bounded in-memory queue so page-view audit INSERTs never block the request pipeline.
/// The request thread captures the entry cheaply (cookies/claims/headers only) and the
/// <see cref="AppUsageAuditBackgroundWriter"/> performs the actual SQL INSERT off-thread.
/// Audit logging is best-effort by design: when the queue is full the oldest entries
/// are dropped instead of ever slowing down a user request.
/// </summary>
public sealed class AppUsageAuditQueue
{
    private readonly Channel<PageVisitAuditEntry> _channel =
        Channel.CreateBounded<PageVisitAuditEntry>(new BoundedChannelOptions(10_000)
        {
            SingleReader = true,
            FullMode = BoundedChannelFullMode.DropOldest,
        });

    public bool TryEnqueue(PageVisitAuditEntry entry) => _channel.Writer.TryWrite(entry);

    public IAsyncEnumerable<PageVisitAuditEntry> ReadAllAsync(CancellationToken ct) =>
        _channel.Reader.ReadAllAsync(ct);
}

/// <summary>Drains <see cref="AppUsageAuditQueue"/> and writes page-view rows off the request path.</summary>
public sealed class AppUsageAuditBackgroundWriter : BackgroundService
{
    private readonly AppUsageAuditQueue _queue;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<AppUsageAuditBackgroundWriter> _logger;

    public AppUsageAuditBackgroundWriter(
        AppUsageAuditQueue queue,
        IServiceScopeFactory scopeFactory,
        ILogger<AppUsageAuditBackgroundWriter> logger)
    {
        _queue = queue;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var entry in _queue.ReadAllAsync(stoppingToken))
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var writer = scope.ServiceProvider.GetRequiredService<SqlAppUsageAuditService>();
                await writer.WritePageVisitAsync(entry, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Never let audit failures affect the app; the service's own circuit
                // breaker already suppresses repeated connection errors.
                _logger.LogDebug(ex, "Background usage-audit write failed.");
            }
        }
    }
}
