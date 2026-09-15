using LRN.CpuMonitor;
using LRN.CpuMonitor.Models;
using LRN.CpuMonitor.Services;
using Serilog;
using Serilog.Events;

Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .Enrich.FromLogContext()
    .WriteTo.Console()

    // Everything, so a breach can be read in the context of the cycles around it.
    .WriteTo.File(
        path: Path.Combine(AppContext.BaseDirectory, "Logs", "cpu-monitor-.txt"),
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: 30)

    // Threshold breaches only, so they are not buried in routine cycle logging.
    // Retained far longer than the operational log because this is the record you
    // come back to weeks later asking what was eating the box.
    .WriteTo.Logger(breachOnly => breachOnly
        .Filter.ByIncludingOnly(IsBreachEvent)
        .WriteTo.File(
            path: Path.Combine(AppContext.BaseDirectory, "Logs", "cpu-breaches-.txt"),
            rollingInterval: RollingInterval.Day,
            retainedFileCountLimit: 180))
    .CreateLogger();

static bool IsBreachEvent(LogEvent logEvent) =>
    logEvent.Properties.TryGetValue("SourceContext", out var sourceContext)
    && sourceContext.ToString().Contains(Worker.BreachLoggerCategory, StringComparison.Ordinal);

try
{
    Log.Information("Starting CPU Monitor Worker");

    // Anchor configuration to the executable's folder rather than the working
    // directory. AddWindowsService does this for service mode, but without it a
    // console run from anywhere else silently ignores appsettings.json and falls
    // back to the built-in defaults.
    var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
    {
        Args = args,
        ContentRootPath = AppContext.BaseDirectory,
    });

    builder.Services.AddWindowsService(options =>
    {
        options.ServiceName = "LRN - CPU Monitor";
    });

    builder.Services.AddSerilog();

    builder.Services.Configure<CpuMonitorSettings>(
        builder.Configuration.GetSection(CpuMonitorSettings.SectionName));

    builder.Services.AddSingleton(TimeProvider.System);
    builder.Services.AddSingleton<ICpuSampler, CpuSampler>();
    builder.Services.AddSingleton<IProcessInspector, ProcessInspector>();
    builder.Services.AddSingleton<ISqlActivityProbe, SqlActivityProbe>();
    builder.Services.AddHostedService<Worker>();

    var host = builder.Build();
    await host.RunAsync();
}
catch (Exception ex)
{
    Log.Fatal(ex, "CPU Monitor Worker terminated unexpectedly");
}
finally
{
    Log.Information("Stopped CPU Monitor Worker");
    await Log.CloseAndFlushAsync();
}
