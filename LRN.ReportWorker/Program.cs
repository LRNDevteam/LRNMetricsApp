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
            logging.AddEventLog();

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

        // ── Web services reused for Prediction / Forecasting generation ──
        // Same LabSettings the dashboard builds, from the same per-lab JSONs.
        services.AddMemoryCache();
        services.AddSingleton(sp =>
        {
            var opts = context.Configuration.GetSection("ReportWorker").Get<ReportWorkerOptions>()
                       ?? new ReportWorkerOptions();
            var logger = sp.GetRequiredService<ILoggerFactory>()
                           .CreateLogger("LabSettingsFactory");
            return LabSettingsFactory.Build(opts.LabConfigFolder, opts.Labs, logger);
        });
        services.AddSingleton<LabMetricsDashboard.Services.LabCsvFileResolver>();
        services.AddSingleton<LabMetricsDashboard.Services.PredictionReportParserService>();
        services.AddSingleton<LabMetricsDashboard.Services.IPredictionDbRepository,
            LabMetricsDashboard.Services.SqlPredictionDbRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.PredictionInsightLoader>();
        services.AddSingleton<LabMetricsDashboard.Services.DenialDescriptionMasterLookup>();
        services.AddTransient<LabMetricsDashboard.Controllers.PredictionController>();
        services.AddSingleton<LabMetricsDashboard.Services.ICollectionSummaryRepository,
            LabMetricsDashboard.Services.SqlCollectionSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IAnalysisRangeService,
            LabMetricsDashboard.Services.AnalysisRangeService>();
        services.AddTransient<LabMetricsDashboard.Controllers.CollectionSummaryController>();
        services.AddSingleton<LabMetricsDashboard.Services.SqlClaimLineRepository>();
        services.AddSingleton<LRN.ProductionReports.Services.IProductionReportRepository,
            LRN.ProductionReports.Services.SqlProductionReportRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.INorthWestProductionSummaryRepository,
            LabMetricsDashboard.Services.SqlNorthWestProductionSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IAugustusProductionSummaryRepository,
            LabMetricsDashboard.Services.SqlAugustusProductionSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.SqlPhiExecutiveSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IDashboardRepository,
            LabMetricsDashboard.Services.SqlDashboardRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IClinicSummaryRepository,
            LabMetricsDashboard.Services.SqlClinicSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.ISalesRepSummaryRepository,
            LabMetricsDashboard.Services.SqlSalesRepSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.ICodingValidationRepository,
            LabMetricsDashboard.Services.SqlCodingValidationRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.ILisSummaryRepository,
            LabMetricsDashboard.Services.SqlLisSummaryRepository>();
        // Denial Dashboard reads go straight to SQL (the same queries LRN.ReportsApi runs
        // for the page) — the HTTP client mints its JWT from the signed-in HttpContext,
        // which a background service does not have. Needs ConnectionStrings:DefaultConnection
        // plus each lab's ConnectionKey entry, exactly as in the dashboard's appsettings.
        services.AddSingleton<LabMetricsDashboard.Services.IDenialRecordRepository,
            LabMetricsDashboard.Services.SqlDenialRecordRepository>();

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
