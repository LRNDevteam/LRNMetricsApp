using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using RcmWatcherService;
using RcmWatcherService.Models;
using RcmWatcherService.Services;
using Serilog;

// Read log path from appsettings.json before the full host is built
var bootstrapCfg = new ConfigurationBuilder()
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

var logPath          = bootstrapCfg["Logging:LogPath"]          ?? "Logs\\RcmWatcher-.log";
var retainedFileDays = int.TryParse(bootstrapCfg["Logging:RetainedFileDays"], out var d) ? d : 30;

const string logTemplate = "[{Timestamp:yyyy-MM-dd HH:mm:ss}] [{Level:u4}] {Message:lj}{NewLine}{Exception}";

// Bootstrap logger (used during startup before the full host is ready)
Log.Logger = new LoggerConfiguration()
    .WriteTo.Console(outputTemplate: logTemplate)
    .WriteTo.File(
        path: logPath,
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: retainedFileDays,
        outputTemplate: logTemplate)
    .CreateBootstrapLogger();

try
{
    Log.Information("[RCM Watcher] Starting up…");

    var host = Host.CreateDefaultBuilder(args)
        .UseWindowsService(o => o.ServiceName = "LRN RCM Watcher")
        .UseSerilog((ctx, services, cfg) => cfg
            .ReadFrom.Configuration(ctx.Configuration)
            .ReadFrom.Services(services)
            .WriteTo.Console(outputTemplate: logTemplate)
            .WriteTo.File(
                path: ctx.Configuration["Logging:LogPath"] ?? logPath,
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: int.TryParse(ctx.Configuration["Logging:RetainedFileDays"], out var rd) ? rd : retainedFileDays,
                outputTemplate: logTemplate))
        .ConfigureAppConfiguration((ctx, cfg) =>
        {
            cfg.AddJsonFile("appsettings.json", optional: false, reloadOnChange: true);

            // Load per-lab JSON config files from LabConfigFolder
            var tempCfg = cfg.Build();
            var labConfigOptions = tempCfg
                .GetSection(LabConfigOptions.Section)
                .Get<LabConfigOptions>() ?? new LabConfigOptions();

            foreach (var labName in labConfigOptions.Labs)
            {
                var filePath = Path.Combine(labConfigOptions.LabConfigFolder, $"{labName}.json");
                cfg.AddJsonFile(filePath, optional: true, reloadOnChange: true);
            }
        })
        .ConfigureServices((ctx, services) =>
        {
            // Build LabSettings from loaded config
            var configuration = ctx.Configuration;
            var labConfigOptions = configuration
                .GetSection(LabConfigOptions.Section)
                .Get<LabConfigOptions>() ?? new LabConfigOptions();

            var labSettings = new LabSettings
            {
                Labs = labConfigOptions.Labs.ToDictionary(
                    labName => labName,
                    labName => configuration.GetSection(labName).Get<LabCsvConfig>() ?? new LabCsvConfig(),
                    StringComparer.OrdinalIgnoreCase)
            };

            services.AddSingleton(labSettings);
            services.AddSingleton<LabCsvFileResolver>();
            services.AddSingleton<CsvParserService>();
            services.AddSingleton<RcmJsonWriterService>();
            services.AddHostedService<RcmWatcherWorker>();
        })
        .Build();

    await host.RunAsync();
}
catch (Exception ex)
{
    Log.Fatal(ex, "[RCM Watcher] Host terminated unexpectedly.");
}
finally
{
    Log.CloseAndFlush();
}
