using LRN.ReportQueue.Shared;
using LRN.ReportWorker;
using LRN.ReportWorker.Generators;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// Same hosting pattern as LRN.MasterFileProcessorWorker:
// runs as a console app in development, installs as a Windows Service in production:
//   sc create "LRN - Report Generation Worker" binPath="...\LRN.ReportWorker.exe"
var host = Host.CreateDefaultBuilder(args)
    .UseContentRoot(AppContext.BaseDirectory)
    .UseWindowsService(o => o.ServiceName = "LRN - Report Generation Worker")
    .ConfigureLogging((context, logging) =>
    {
        logging.ClearProviders();
        logging.AddConsole();
        if (OperatingSystem.IsWindows())
        {
            try
            {
                // Creating / probing an Event Log source can stall LocalSystem long enough
                // for SCM to raise Error 1053. Never let Event Log block service start.
                logging.AddEventLog();
            }
            catch
            {
                // File logger below is the operational source of truth.
            }
        }

        // Rolling daily file logs (reportworker-YYYY-MM-DD.log).
        var fileSection = context.Configuration.GetSection("Logging:File");
        var fileOptions = new FileLoggerOptions
        {
            LogDirectory = fileSection["LogDirectory"] ?? "Logs",
            RetainDays = fileSection.GetValue("RetainDays", 30),
            MinLevel = ParseLogLevel(fileSection["LogLevel"], LogLevel.Information),
        };
        logging.AddProvider(new FileLoggerProvider(fileOptions));
    })
    .ConfigureServices((context, services) =>
    {
        services.Configure<ReportWorkerOptions>(context.Configuration.GetSection("ReportWorker"));
        services.Configure<ReportStorageOptions>(context.Configuration.GetSection("ReportStorage"));

        services.AddSingleton<IReportRequestRepository, SqlReportRequestRepository>();

        // Dashboard data layer (LabSettings + the pages' repositories), shared with LRN.SnapshotGenerator.
        services.AddReportDataServices(context.Configuration);

        // One IReportGenerator per report type — add future reports here.
        services.AddSingleton<IReportGenerator, PayerPolicyValidationReportGenerator>();
        services.AddSingleton<IReportGenerator, PredictionAnalysisReportGenerator>();
        services.AddSingleton<IReportGenerator, ForecastingSummaryReportGenerator>();
        services.AddSingleton<IReportGenerator, CollectionReportGenerator>();
        services.AddSingleton<IReportGenerator, ClaimLevelDetailsReportGenerator>();
        services.AddSingleton<IReportGenerator, LineLevelDetailsReportGenerator>();
        services.AddSingleton<IReportGenerator, ProductionReportGenerator>();
        services.AddSingleton<IReportGenerator, ExecutiveSummaryReportGenerator>();
        services.AddSingleton<IReportGenerator, RevenueDashboardReportGenerator>();
        services.AddSingleton<IReportGenerator, ClinicSummaryReportGenerator>();
        services.AddSingleton<IReportGenerator, SalesRepSummaryReportGenerator>();
        services.AddSingleton<IReportGenerator, CodingSummaryReportGenerator>();
        services.AddSingleton<IReportGenerator, LisSummaryReportGenerator>();
        services.AddSingleton<IReportGenerator, DenialDashboardReportGenerator>();
        services.AddSingleton<IReportGenerator, DenialSummaryReportGenerator>();
        // Two report types, one class: registered per tab so the factory can key on ReportType.
        services.AddSingleton<IReportGenerator>(sp => CptLookupReportGenerator.ForCpt(
            sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<ReportStorageOptions>>(),
            sp.GetRequiredService<ILogger<CptLookupReportGenerator>>()));
        services.AddSingleton<IReportGenerator>(sp => CptLookupReportGenerator.ForPanel(
            sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<ReportStorageOptions>>(),
            sp.GetRequiredService<ILogger<CptLookupReportGenerator>>()));
        services.AddSingleton<ReportGeneratorFactory>();

        services.AddSingleton<ReportJobProcessor>();
        services.AddHostedService<ReportQueueWorker>();
        services.AddHostedService<ReportCleanupWorker>();
    })
    .Build();

{
    var logger = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("Startup");
    var fileSection = host.Services.GetRequiredService<IConfiguration>().GetSection("Logging:File");
    var logDir = fileSection["LogDirectory"] ?? "Logs";
    if (!Path.IsPathRooted(logDir))
        logDir = Path.Combine(AppContext.BaseDirectory, logDir);

    logger.LogInformation(
        "LRN.ReportWorker starting. Machine={Machine} ContentRoot={Root} LogDirectory={LogDir}",
        Environment.MachineName, AppContext.BaseDirectory, logDir);
}

await host.RunAsync();

static LogLevel ParseLogLevel(string? value, LogLevel fallback) =>
    Enum.TryParse<LogLevel>(value, ignoreCase: true, out var level) ? level : fallback;
