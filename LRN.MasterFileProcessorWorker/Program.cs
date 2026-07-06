using Common.Logging;
using LRN.ExcelValidator.Services;
using LRN.Notifications;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var host = Host.CreateDefaultBuilder(args)
	.UseContentRoot(AppContext.BaseDirectory)
	.UseWindowsService(o => o.ServiceName = "LRN - Master File Processor")
	.ConfigureLogging((context, logging) =>
	{
		logging.ClearProviders();
		logging.AddConsole();
		logging.AddEventLog();
	})
	.ConfigureServices((context, services) =>
	{
		services.Configure<ImportOptions>(context.Configuration.GetSection("MasterFileProcessor"));
		services.Configure<ProcessLogOptions>(context.Configuration.GetSection("ProcessLog"));

		services.AddSingleton<ILoggerService, LogManagerService>();
		services.AddHttpClient<SharePointDownloader>();
		services.AddExcelValidator();
		services.AddMyCompanyNotifications(context.Configuration);


		services.AddSingleton<MasterFileProcessorFileStatusStore>();

		services.AddSingleton<IProcessLogRepository, SqlProcessLogRepository>();
		services.AddSingleton<IProcessLogCsvWriter, ProcessLogCsvWriter>();
		services.AddSingleton<IProcessLogWorkbookWriter, ProcessLogWorkbookWriter>();
		services.AddSingleton<IProcessLogService, ProcessLogService>();
		services.AddSingleton<ModeMedianReportPublisher>();

		services.AddHostedService<MasterFileProcessorWorker>();
	})
	.Build();

await host.RunAsync();