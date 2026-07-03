using Common.Logging;
using LRN.MasterFileProcessorWorker.Options;
using LRN.MasterFileProcessorWorker.Services;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker;

public sealed class Worker : BackgroundService
{
    private readonly ILoggerService _log;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly MasterFileProcessorOptions _opts;

    public Worker(
        ILoggerService log,
        IServiceScopeFactory scopeFactory,
        IOptions<MasterFileProcessorOptions> opts)
    {
        _log = log;
        _scopeFactory = scopeFactory;
        _opts = opts.Value;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _log.Info($"MasterFileProcessorWorker started. PollingIntervalSeconds={_opts.PollingIntervalSeconds}");

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var processor = scope.ServiceProvider.GetRequiredService<MasterFileProcessorOrchestrator>();
                await processor.ProcessAllLabsOnceAsync(stoppingToken);
            }
            catch (Exception ex)
            {
                _log.Error("Top-level worker loop error.", ex);
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(30, _opts.PollingIntervalSeconds)), stoppingToken);
            }
            catch (TaskCanceledException) { }
        }
    }
}
