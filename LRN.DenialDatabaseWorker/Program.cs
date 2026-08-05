using DenialDatabaseProcessorWorker.Builders;
using DenialDatabaseProcessorWorker.BulkWriters;
using DenialDatabaseProcessorWorker.Models;
using DenialDatabaseProcessorWorker.Normalizers;
using DenialDatabaseProcessorWorker.Notifications;
using DenialDatabaseProcessorWorker.Services;
using DenialDatabaseProcessorWorker.Services.Workflow;
using DenialDatabaseProcessorWorker.Models.Workflow;
using DenialDatabaseProcessorWorker.Services.SharePoint;
using DenialDatabaseProcessorWorker.Worker;

var builder = Host.CreateApplicationBuilder(args);

// ProcessorOptions
builder.Services.Configure<ProcessorOptions>(builder.Configuration.GetSection(ProcessorOptions.SectionName));
builder.Services.PostConfigure<ProcessorOptions>(options =>
{
	options.Configuration = builder.Configuration;
});

// Labs
builder.Services.Configure<List<LabConfig>>(builder.Configuration.GetSection("Labs"));
builder.Services.Configure<DenialWorkflowApiOptions>(builder.Configuration.GetSection(DenialWorkflowApiOptions.SectionName));

// Logging
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
if (OperatingSystem.IsWindows())
	builder.Logging.AddEventLog();

// Core Services
builder.Services.AddSingleton<CsvStepLogger>();
builder.Services.AddSingleton<ExcelTableReader>();
builder.Services.AddSingleton<PayerValidationReportRepository>();
builder.Services.AddSingleton<DenialCodeNormalizer>();
builder.Services.AddSingleton<DenialDatabaseBuilder>();
builder.Services.AddSingleton<ExcelWriter>();
builder.Services.AddSingleton<DenialInsightBuilder>();

// NEW Services
builder.Services.AddSingleton<FileResolver>();
builder.Services.AddSingleton<OutputPathBuilder>();
builder.Services.AddSingleton<DenialAnalysisRunLogRepository>();
builder.Services.AddSingleton<DenialTaskBoardRepository>();
builder.Services.AddHttpClient<IDenialWorkflowApiClient, DenialWorkflowApiClient>();

// SharePoint
builder.Services.AddHttpClient<SharePointGraphClient>();
builder.Services.AddSingleton<ISharePointUploader, SharePointUploader>();
builder.Services.AddSingleton<IErrorLogger, ErrorLogger>();
builder.Services.AddSingleton<ITeamsNotifier, TeamsWebhookNotifier>();

// Worker
builder.Services.AddHostedService<DenialDatabaseWorker>();

// Windows Service
if (OperatingSystem.IsWindows())
{
	builder.Services.AddWindowsService(options =>
	{
		options.ServiceName = "LRN - Denial Database Processor";
	});
}

var host = builder.Build();
await host.RunAsync();