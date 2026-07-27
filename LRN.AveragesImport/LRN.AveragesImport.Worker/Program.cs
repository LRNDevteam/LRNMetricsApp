using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Data;
using LRN.AveragesImport.Core.Services;
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

builder.Services.AddSingleton<ISqlConnectionFactory>(new SqlConnectionFactory(connectionString));
builder.Services.AddSingleton<ILabRunProvider, LabRunProvider>();
builder.Services.AddSingleton<IFileLocator, FileLocator>();
builder.Services.AddSingleton<ICsvReaderService, CsvReaderService>();
builder.Services.AddSingleton<IImportService, ImportService>();
builder.Services.AddHostedService<AveragesImportWorker>();

var host = builder.Build();
await host.RunAsync();
