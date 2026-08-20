using LRN.AzBlobSync;
using LRN.AzBlobSync.Models;
using LRN.AzBlobSync.Services;
using Microsoft.Extensions.Configuration;
using Serilog;

Directory.SetCurrentDirectory(AppContext.BaseDirectory);

const string logTemplate = "[{Timestamp:yyyy-MM-dd HH:mm:ss}] [{Level:u4}] {Message:lj}{NewLine}{Exception}";

var bootstrapCfg = new ConfigurationBuilder()
    .SetBasePath(AppContext.BaseDirectory)
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

var logPath = bootstrapCfg["BlobSync:LogPath"]
    ?? bootstrapCfg["Logging:LogPath"]
    ?? "Logs\\azblob-sync-.log";
var retainedFileDays = int.TryParse(bootstrapCfg["BlobSync:LogRetainDays"] ?? bootstrapCfg["Logging:RetainedFileDays"], out var days)
    ? days
    : 30;
var logDir = Path.GetDirectoryName(logPath);
if (!string.IsNullOrWhiteSpace(logDir))
    Directory.CreateDirectory(logDir);

Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .WriteTo.Console(outputTemplate: logTemplate)
    .WriteTo.File(
        path: logPath,
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: retainedFileDays,
        shared: true,
        outputTemplate: logTemplate)
    .CreateLogger();

try
{
    Log.Information("[BlobSync] Starting LRN.AzBlobSync (one-shot). Log file: {LogPath}", logPath);

    var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
    {
        Args = args,
        ContentRootPath = AppContext.BaseDirectory,
    });

    builder.Services.AddWindowsService(o => o.ServiceName = "LRN Azure Blob Sync");
    builder.Services.AddSerilog(Log.Logger, dispose: false);

    var options = builder.Configuration.GetSection(BlobSyncOptions.Section).Get<BlobSyncOptions>()
        ?? new BlobSyncOptions();
    if (string.IsNullOrWhiteSpace(options.LogPath))
        options.LogPath = logPath;
    builder.Services.AddSingleton(options);
    var foundry = builder.Configuration.GetSection(FoundryOptions.Section).Get<FoundryOptions>()
        ?? new FoundryOptions();
    builder.Services.AddSingleton(foundry);
    builder.Services.AddSingleton<KeyVaultSecretReader>();
    builder.Services.AddSingleton<WeekFolderScanner>();
    builder.Services.AddSingleton<AzureBlobUploader>();
    builder.Services.AddSingleton<LatestFolderStateStore>();
    builder.Services.AddSingleton<FoundryInsightClient>();
    builder.Services.AddSingleton<ThreePillarInsightGenerator>();
    builder.Services.AddHostedService<ThreePillarBlobSyncWorker>();

    var host = builder.Build();
    await host.RunAsync();
}
catch (Exception ex)
{
    Environment.ExitCode = 1;
    Log.Fatal(ex, "[BlobSync] FAILED. {Message}", ex.Message);
}
finally
{
    Log.CloseAndFlush();
}

return Environment.ExitCode;
