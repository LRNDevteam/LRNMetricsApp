using Azure.Identity;
using LRN.MasterFileProcessorWorker.BulkLoad;
using LRN.MasterFileProcessorWorker.ExcelValidation;
using LRN.MasterFileProcessorWorker.Logging;
using LRN.MasterFileProcessorWorker.Notifications;
using LRN.MasterFileProcessorWorker.SharePoint;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

// Self-tests for the line/claim bulk-copy pipeline. Runs without a database or a test framework.
if (args.Contains("--selftest", StringComparer.OrdinalIgnoreCase))
	return SelfTests.Run();

var host = Host.CreateDefaultBuilder(args)
	.UseContentRoot(AppContext.BaseDirectory)
	.UseWindowsService(o => o.ServiceName = "LRN - Master File Processor")
	.ConfigureAppConfiguration(config =>
	{
		// Every secret - the SharePoint app registration and all SQL connection strings - lives in
		// Azure Key Vault, never in a file in this repo. Secret names use "--" where the
		// configuration key uses ":", so "ConnectionStrings--DefaultConnection" in the vault binds
		// to ConnectionStrings:DefaultConnection here.
		//
		// This provider is added LAST, so vault values win over appsettings.json. Authentication is
		// DefaultAzureCredential: the service's managed identity on the server, and the developer's
		// az-cli / Visual Studio sign-in locally. Either identity needs the "Key Vault Secrets User"
		// role on the vault, which has RBAC authorization enabled.
		//
		// Set KeyVault:VaultUri to "" to skip the vault entirely (offline work); configuration then
		// falls back to appsettings.json and environment variables.
		//
		// The builder is built here rather than reading HostBuilderContext.Configuration, which at
		// this point still only holds host configuration - appsettings.json is not visible on it
		// until every ConfigureAppConfiguration delegate has run.
		var vaultUri = config.Build()["KeyVault:VaultUri"];
		if (!string.IsNullOrWhiteSpace(vaultUri))
			config.AddAzureKeyVault(new Uri(vaultUri), new DefaultAzureCredential());

		// Narrow escape hatch for the few secrets the vault cannot hold - today just the Teams
		// incoming-webhook URL, which exceeds the 256-character limit on the vault tags these
		// settings are managed through. Gitignored, and loaded after the vault so it wins.
		// See appsettings.Secrets.example.json for the expected shape.
		config.AddJsonFile("appsettings.Secrets.json", optional: true, reloadOnChange: true);
	})
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
		services.AddNotifications(context.Configuration);

		services.AddSingleton<MasterFileProcessorFileStatusStore>();

		services.AddSingleton<IProcessLogRepository, SqlProcessLogRepository>();
		services.AddSingleton<IProcessLogCsvWriter, ProcessLogCsvWriter>();
		services.AddSingleton<IProcessLogWorkbookWriter, ProcessLogWorkbookWriter>();
		services.AddSingleton<IProcessLogService, ProcessLogService>();
		services.AddSingleton<LabModeMedianRepository>();
		services.AddSingleton<LabInsuranceMasterRepository>();
		services.AddSingleton<ModeMedianReportPublisher>();

		// Line-level / claim-level bulk copy. Additive: the existing LRN_Run_Log / LRN_Step_Log /
		// LRN_Error_Log pipeline above is untouched and keeps firing.
		services.Configure<LineClaimImportOptions>(context.Configuration.GetSection(LineClaimImportOptions.SectionName));
		services.AddSingleton<LabMappingLoader>();
		services.AddSingleton<LabRegistry>();
		services.AddSingleton<LineClaimBulkLoader>();
		services.AddSingleton<LineClaimFileLogRepository>();
		services.AddSingleton<ReportRunIdInfoLogger>();
		services.AddSingleton<ReportsWorkflowTrackerRepository>();
		services.AddSingleton<LineClaimImportService>();

		services.AddHostedService<MasterFileProcessorWorker>();
	})
	.Build();

// Preflight check: verifies config, mappings, LabMaster and the target tables without
// processing a file. Answers "is the bulk copy set up correctly" directly.
if (args.Contains("--diagnose", StringComparer.OrdinalIgnoreCase))
{
	using var scope = host.Services.CreateScope();
	var sp = scope.ServiceProvider;

	return await ImportDiagnostics.RunAsync(
		sp.GetRequiredService<IOptions<LineClaimImportOptions>>().Value,
		sp.GetRequiredService<IOptions<ImportOptions>>().Value,
		sp.GetRequiredService<IConfiguration>(),
		sp.GetRequiredService<LabMappingLoader>(),
		AppContext.BaseDirectory,
		CancellationToken.None);
}

await host.RunAsync();
return 0;
