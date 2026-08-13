using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Data;
using LRN.AveragesImport.Core.Services;
using LRN.AveragesImport.Core.Services.ReportLogging;
using LRN.AveragesImport.Worker;
using Serilog;

// When hosted as a Windows Service the process starts in System32 — anchor
// everything (config, relative log paths) to the executable's folder.
Directory.SetCurrentDirectory(AppContext.BaseDirectory);

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory
});

builder.Services.AddWindowsService(options => options.ServiceName = "LRN Averages Import Service");

builder.Services.AddSerilog(loggerConfiguration => loggerConfiguration
    .ReadFrom.Configuration(builder.Configuration)
    .Enrich.FromLogContext());

builder.Services.Configure<ImportSettings>(builder.Configuration.GetSection(ImportSettings.SectionName));

var connectionString = builder.Configuration.GetConnectionString("LRNMaster")
    ?? throw new InvalidOperationException("ConnectionStrings:LRNMaster is not configured.");

// LRNMaster is the write target (CPTAverage / PanelAverage / AverageImportLog);
// each lab's own database is the read source and is opened per lab from
// ImportSettings:Labs[].ConnectionString.
builder.Services.AddSingleton<ISqlConnectionFactory>(new SqlConnectionFactory(connectionString));
builder.Services.AddSingleton<ILabRunProvider, LabRunProvider>();
builder.Services.AddSingleton<IAverageAggregateReader, AverageAggregateReader>();
builder.Services.AddSingleton<IImportService, ImportService>();

// Run logging + workflow tracker (LRNMaster) — what the report dashboard reads.
// Both swallow their own failures: a logging outage costs a log row, not a cycle.
builder.Services.AddSingleton<ReportRunIdInfoLogger>();
builder.Services.AddSingleton<ReportsWorkflowTrackerRepository>();
builder.Services.AddHostedService<AveragesImportWorker>();

var host = builder.Build();
await host.RunAsync();
