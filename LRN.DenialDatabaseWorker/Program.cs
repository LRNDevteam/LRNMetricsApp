using Azure.Identity;
using DenialDatabaseProcessorWorker.Builders;
using DenialDatabaseProcessorWorker.BulkWriters;
using DenialDatabaseProcessorWorker.Models;
using DenialDatabaseProcessorWorker.Normalizers;
using DenialDatabaseProcessorWorker.Notifications;
using DenialDatabaseProcessorWorker.Services;
using DenialDatabaseProcessorWorker.Services.ReportLogging;
using DenialDatabaseProcessorWorker.Services.Workflow;
using DenialDatabaseProcessorWorker.Models.Workflow;
using DenialDatabaseProcessorWorker.Services.SharePoint;
using DenialDatabaseProcessorWorker.Worker;

// The content root is the folder the exe sits in, not the process working directory, which for a
// Windows Service is System32. Without this, appsettings.json and appsettings.Secrets.json are not
// found once the service is installed.
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
	Args = args,
	ContentRootPath = AppContext.BaseDirectory
});

// Every secret this service needs - ConnectionStrings:DenialDatabase, each lab's database, and the
// SharePoint app registration - lives in Azure Key Vault, never in a file in this repo. Secret names
// use "--" where the configuration key uses ":", so "ConnectionStrings--DenialDatabase" in the vault
// binds to ConnectionStrings:DenialDatabase here.
//
// Added AFTER appsettings.json, so vault values win. Authentication is DefaultAzureCredential: the
// service's managed identity on the server, and the developer's az-cli / Visual Studio sign-in
// locally. Either identity needs the "Key Vault Secrets User" role on the vault, which has RBAC
// authorization enabled.
//
// Set KeyVault:VaultUri to "" to skip the vault entirely (offline work); configuration then falls
// back to appsettings.json, appsettings.Secrets.json and environment variables.
var vaultUri = builder.Configuration["KeyVault:VaultUri"];
if (!string.IsNullOrWhiteSpace(vaultUri))
	builder.Configuration.AddAzureKeyVault(new Uri(vaultUri), new DefaultAzureCredential());

// Narrow escape hatch for the few secrets the vault cannot hold - today just the Teams
// incoming-webhook URL, which at 265 characters exceeds the 256-character limit on the vault tags
// these settings are managed through. Gitignored, and loaded after the vault so it wins. See
// appsettings.Secrets.example.json for the expected shape.
builder.Configuration.AddJsonFile("appsettings.Secrets.json", optional: true, reloadOnChange: true);

// ProcessorOptions
builder.Services.Configure<ProcessorOptions>(builder.Configuration.GetSection(ProcessorOptions.SectionName));
builder.Services.PostConfigure<ProcessorOptions>(options =>
{
	options.Configuration = builder.Configuration;
});

// Labs. appsettings.json carries only LabDbConnectionKey - the NAME of the vault secret holding
// that lab's connection string - so resolve each one here, after the vault provider is in place.
// A literal LabConnectionString in configuration still wins, for a throwaway local override.
builder.Services.Configure<List<LabConfig>>(builder.Configuration.GetSection("Labs"));
builder.Services.PostConfigure<List<LabConfig>>(labs =>
{
	foreach (var lab in labs)
	{
		if (!string.IsNullOrWhiteSpace(lab.LabConnectionString))
			continue;

		if (string.IsNullOrWhiteSpace(lab.LabDbConnectionKey))
			throw new InvalidOperationException(
				$"Lab '{lab.LabName}' (LabId {lab.LabId}) has neither LabDbConnectionKey nor a literal " +
				"LabConnectionString. Set LabDbConnectionKey to the name of its vault secret.");

		lab.LabConnectionString = builder.Configuration.GetConnectionString(lab.LabDbConnectionKey)
			?? throw new InvalidOperationException(
				$"Connection string '{lab.LabDbConnectionKey}' for lab '{lab.LabName}' was not found. " +
				$"Confirm the secret \"ConnectionStrings--{lab.LabDbConnectionKey}\" exists in the vault " +
				"named by KeyVault:VaultUri and that this identity may read it.");
	}
});
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

// Run logging + workflow tracker (LRNMaster). Both wrap stored procedures and swallow
// their own failures, so a logging outage costs a log row and not the run.
builder.Services.AddSingleton<RecentSuccessRunProvider>();
builder.Services.AddSingleton<ReportRunIdInfoLogger>();
builder.Services.AddSingleton<ReportsWorkflowTrackerRepository>();

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