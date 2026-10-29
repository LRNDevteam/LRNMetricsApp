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
		// Every secret - LRNMaster and every lab's SQL connection string, the SharePoint client
		// secret, the Teams webhook URL and the snapshot storage settings - lives in Azure Key
		// Vault, never in a file. Secret names use "--" where the configuration key uses ":", so
		// "ConnectionStrings--DefaultConnection" in the vault binds to
		// ConnectionStrings:DefaultConnection here, and a lab's LabDbConnectionKey "CoveConnection"
		// reads the secret "ConnectionStrings--CoveConnection".
		//
		// KeyVault:VaultUri picks the vault: kv-lrnmetrics-prod in appsettings.json, lrn-testapp-kv
		// in appsettings.Test.json (DOTNET_ENVIRONMENT=Test). This provider is added LAST, so vault
		// values win over every file. Authentication is DefaultAzureCredential: the service's
		// managed identity on the server, and the developer's az-cli / Visual Studio sign-in
		// locally. Either identity needs the "Key Vault Secrets User" role on the vault (RBAC).
		//
		// Set KeyVault:VaultUri to "" to skip the vault entirely (offline work); the same keys must
		// then come from environment variables (ConnectionStrings__DefaultConnection, ...).
		//
		// The builder is built here rather than reading HostBuilderContext.Configuration, which at
		// this point still only holds host configuration - appsettings.json is not visible on it
		// until every ConfigureAppConfiguration delegate has run.
		var vaultUri = config.Build()["KeyVault:VaultUri"];
		if (!string.IsNullOrWhiteSpace(vaultUri))
			config.AddAzureKeyVault(new Uri(vaultUri), new DefaultAzureCredential());
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
		// Derives DenialCodeNormalized / DenialDescription on the claim- and line-level tables after they load.
		services.AddSingleton<DenialDescriptionEnricher>();
		services.AddSingleton<LineClaimImportService>();

		// Reads claim/line master data out of a lab's own database for labs whose
		// MasterDataSource is "LabDatabase" (Cove), in place of the SharePoint workbook.
		services.AddSingleton<LRN.MasterFileProcessorWorker.Database.LabDatabaseMasterReader>();

		// Read-only gate over LRNMaster.dbo.LrnFileStatus: only ingest a lab's tables once the
		// upstream run that filled them reports Completed, and only once per run.
		services.AddSingleton<LRN.MasterFileProcessorWorker.Database.LabSourceRunGate>();
		services.AddSingleton<LRN.MasterFileProcessorWorker.ProcessLogging.RerunRequestStore>();

		// After the line/claim load: refresh the lab's AR Workbench (Denial Workbench) claims and move
		// assigned claims whose claim status changed to RCM Manager verification.
		services.Configure<LRN.MasterFileProcessorWorker.ArWorkbench.ArWorkbenchSyncOptions>(
			context.Configuration.GetSection(LRN.MasterFileProcessorWorker.ArWorkbench.ArWorkbenchSyncOptions.SectionName));
		services.AddSingleton<LRN.MasterFileProcessorWorker.ArWorkbench.ArWorkbenchSyncService>();

		// Step 88: weekly Parquet snapshots of the Line Level, Claim Level and LIMS tables, kept for
		// MasterDataSnapshot:KeepWeeks weeks. Off until MasterDataSnapshot:Enabled is true.
		services.Configure<LRN.MasterFileProcessorWorker.Snapshots.MasterDataSnapshotOptions>(
			context.Configuration.GetSection(LRN.MasterFileProcessorWorker.Snapshots.MasterDataSnapshotOptions.SectionName));
		services.AddSingleton<LRN.MasterFileProcessorWorker.Snapshots.SnapshotStoreFactory>();
		services.AddSingleton<LRN.MasterFileProcessorWorker.Snapshots.ReportSnapshotRepository>();
		services.AddSingleton<LRN.MasterFileProcessorWorker.Snapshots.MasterDataSnapshotService>();

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
