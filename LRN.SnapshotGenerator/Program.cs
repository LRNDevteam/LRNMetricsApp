using Azure.Identity;
using LRN.MasterFileProcessorWorker.Snapshots;
using LRN.ReportQueue.Shared;
using LRN.ReportWorker;
using LRN.ReportWorker.Generators;
using LRN.SnapshotGenerator;

// Weekly snapshots of the LRN Metrics page reports (Executive, LIS, Production, Collection and Denial
// Summary) per lab and RunId, taken once each report shows Success in ReportsWorkflowTracker; and of the
// client-uploaded Denial Insight tab when LabMetricsDashboard requests it after an upload.
//   sc create "LRN - Snapshot Generator" binPath="...\LRN.SnapshotGenerator.exe"
// Offline check of the view-model -> Parquet conversion; needs no database, vault or storage.
if (args.Contains("--selftest", StringComparer.OrdinalIgnoreCase))
    return await SelfTest.RunAsync();

var host = Host.CreateDefaultBuilder(args)
    .UseContentRoot(AppContext.BaseDirectory)
    .UseWindowsService(o => o.ServiceName = "LRN - Snapshot Generator")
    .ConfigureAppConfiguration(config =>
    {
        // Every secret from Key Vault, as in the master file processor: ConnectionStrings--DefaultConnection
        // (LRNMaster) and MasterDataSnapshot--BlobServiceUri / --ContainerName (the snapshot container).
        // KeyVault:VaultUri: kv-lrnmetrics-prod in appsettings.json, lrn-testapp-kv in appsettings.Test.json
        // (set DOTNET_ENVIRONMENT=Test on the service only). Added last, so vault values win.
        var vaultUri = config.Build()["KeyVault:VaultUri"];
        if (!string.IsNullOrWhiteSpace(vaultUri))
            config.AddAzureKeyVault(new Uri(vaultUri), new DefaultAzureCredential());
    })
    .ConfigureLogging((context, logging) =>
    {
        logging.ClearProviders();
        logging.AddConsole();
        if (OperatingSystem.IsWindows())
        {
            try { logging.AddEventLog(); } catch { /* never let Event Log block service start (Error 1053) */ }
        }

        var fileSection = context.Configuration.GetSection("Logging:File");
        logging.AddProvider(new FileLoggerProvider(new FileLoggerOptions
        {
            LogDirectory = fileSection["LogDirectory"] ?? "Logs",
            // <service folder>\Logs\snapshotgenerator-YYYY-MM-DD.log
            FilePrefix = "snapshotgenerator",
            RetainDays = fileSection.GetValue("RetainDays", 30),
            MinLevel = Enum.TryParse<LogLevel>(fileSection["LogLevel"], ignoreCase: true, out var level) ? level : LogLevel.Information
        }));
    })
    .ConfigureServices((context, services) =>
    {
        // The pages' data layer and the five report generators - the same code the LRN Metrics pages and
        // the queued Excel exports run, so each lab's own stored procedures and rules apply.
        // No ReportStorage section: that is the Excel output folder of a queued export (GenerateAsync), which a
        // snapshot never writes - it only loads the page's data (LoadUnfilteredAsync).
        services.AddReportDataServices(context.Configuration);
        services.AddReportSnapshotSources();

        // The dashboard's per-lab Denial Summary week / date / balance columns (LabConfig:DenialSummary*),
        // copied from LabMetricsDashboard's appsettings.json, so the Denial snapshots match the page.
        services.AddSingleton(context.Configuration.GetSection(LabMetricsDashboard.Models.LabConfigOptions.Section)
            .Get<LabMetricsDashboard.Models.LabConfigOptions>() ?? new LabMetricsDashboard.Models.LabConfigOptions());
        // The Denial Insight tab: client-uploaded, captured on LabMetricsDashboard's request.
        services.AddSingleton<IReportSnapshotSource, DenialInsightSnapshotSource>();

        // Snapshot storage, index and retention: the master file processor's (MasterDataSnapshot section).
        services.Configure<MasterDataSnapshotOptions>(context.Configuration.GetSection(MasterDataSnapshotOptions.SectionName));
        services.AddSingleton<SnapshotStoreFactory>();
        services.AddSingleton<ReportSnapshotRepository>();

        services.Configure<ReportSnapshotOptions>(context.Configuration.GetSection(ReportSnapshotOptions.SectionName));
        services.AddSingleton<ReportSnapshotIndex>();
        services.AddSingleton<SnapshotWorkflowTracker>();
        services.AddSingleton<ReportSnapshotService>();
        services.AddHostedService<ReportSnapshotWorker>();
    })
    .Build();

// One pass now, outside the service: --once. Captures whatever is due for the enabled labs and exits.
if (args.Contains("--once", StringComparer.OrdinalIgnoreCase))
{
    var service = host.Services.GetRequiredService<ReportSnapshotService>();
    await service.RunOnceAsync(CancellationToken.None);
    return 0;
}

await host.RunAsync();
return 0;
