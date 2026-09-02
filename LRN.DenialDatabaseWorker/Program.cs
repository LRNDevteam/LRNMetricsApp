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

// Check the one secret everything depends on here, while the configuration sources that were meant
// to supply it are still in view. Six services resolve ConnectionStrings:DenialDatabase in their
// constructors and each throws the same bare "Connection string 'DenialDatabase' not found." - which
// in the Windows event log arrives as a DI stack trace naming whichever service the container
// happened to build first, and says nothing about the vault. This says where to look instead.
//
// Note the failure mode that message calls out: the vault configuration provider silently SKIPS a
// secret whose "Enabled" attribute is false, so a disabled (or deleted, or renamed) secret is
// indistinguishable here from one that was never created. Missing access is the louder failure -
// that throws out of AddAzureKeyVault above, before this line runs.
if (string.IsNullOrWhiteSpace(builder.Configuration.GetConnectionString("DenialDatabase")))
	throw new InvalidOperationException(
		"Connection string 'DenialDatabase' (the LRNMaster database) was not supplied by any " +
		"configuration source. " +
		(string.IsNullOrWhiteSpace(vaultUri)
			? "KeyVault:VaultUri is empty, so the vault was skipped entirely: either set it, or supply " +
			  "ConnectionStrings__DenialDatabase as an environment variable - see README.md, " +
			  "\"Running without the vault\"."
			: $"Confirm the secret \"ConnectionStrings--DenialDatabase\" exists AND is enabled in {vaultUri}, " +
			  "and that this service's identity still holds the \"Key Vault Secrets User\" role on that vault."));

// ProcessorOptions
builder.Services.Configure<ProcessorOptions>(builder.Configuration.GetSection(ProcessorOptions.SectionName));

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
// Teams notifications. TeamsNotificationOptions was never bound, so TeamsNotification:* was read
// by nothing and the notifier was inert whatever the config said. Binding it makes the existing
// "Enabled" switch mean what it says; it stays false-by-default in the type, so a lab that has not
// set Enabled=true and supplied a webhook URL still sends nothing.
builder.Services.Configure<TeamsWebhookNotifier.TeamsNotificationOptions>(
	builder.Configuration.GetSection("TeamsNotification"));

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