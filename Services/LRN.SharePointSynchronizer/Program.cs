using Azure.Identity;
using LRN.SharePointClient;
using LRN.SharePointClient.Models;
using LRN.SharePointClient.Sync;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Configuration;

internal static class Program
{
    public static async Task Main(string[] args)
    {
        // The content root is the folder the exe sits in, not the process working directory, which
        // for a Windows Service is System32. Without this, appsettings.json and
        // appsettings.Secrets.json are not found once the service is installed.
        var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
        {
            Args = args,
            ContentRootPath = AppContext.BaseDirectory
        });

        // Every secret this service needs - the SharePoint app registration and any SQL connection
        // string - lives in Azure Key Vault, never in a file in this repo. Secret names use "--"
        // where the configuration key uses ":", so "MasterFileProcessor--SharePoint--ClientSecret"
        // in the vault binds to MasterFileProcessor:SharePoint:ClientSecret here. The app
        // registration is the same one LRN.MasterFileProcessorWorker uses, so these are the very
        // same vault secrets - one rotation covers both services.
        //
        // Added AFTER appsettings.json, so vault values win. Authentication is
        // DefaultAzureCredential: the service's managed identity on the server, and the developer's
        // az-cli / Visual Studio sign-in locally. Either identity needs the "Key Vault Secrets User"
        // role on the vault, which has RBAC authorization enabled.
        //
        // Set KeyVault:VaultUri to "" to skip the vault entirely (offline work); configuration then
        // falls back to appsettings.json, appsettings.Secrets.json and environment variables.
        var vaultUri = builder.Configuration["KeyVault:VaultUri"];
        if (!string.IsNullOrWhiteSpace(vaultUri))
            builder.Configuration.AddAzureKeyVault(new Uri(vaultUri), new DefaultAzureCredential());

        // Narrow escape hatch for the few secrets the vault cannot hold - today just the Teams
        // incoming-webhook URL, which at 296 characters exceeds the 256-character limit on the vault
        // tags these settings are managed through. Gitignored, and loaded after the vault so it
        // wins. See appsettings.Secrets.example.json for the expected shape.
        builder.Configuration.AddJsonFile("appsettings.Secrets.json", optional: true, reloadOnChange: true);

        // Windows Service
        builder.Services.AddWindowsService(o => o.ServiceName = "LRN SharePoint Synchronizer");

        // Logging
        builder.Logging.ClearProviders();
        builder.Logging.AddSimpleConsole(o =>
        {
            o.SingleLine = true;
            o.TimestampFormat = "HH:mm:ss ";
        });
#if WINDOWS
        builder.Logging.AddEventLog();
#endif
        builder.Logging.SetMinimumLevel(LogLevel.Information);

        // Options
        var opt = builder.Configuration.GetSection("SharePointSynchronizer")
            .Get<SynchronizerWorkerOptions>() ?? new SynchronizerWorkerOptions();

        var uploadPaths = builder.Configuration.GetSection("UploadPaths")
            .Get<List<UploadPathItem>>() ?? new List<UploadPathItem>();

        opt.UploadPaths = uploadPaths;
        builder.Services.AddSingleton(Options.Create(opt));

        // SharePoint client
        builder.Services.AddLrnSharePointClient(builder.Configuration);
        builder.Services.AddSingleton<FolderSyncEngine>();

        // Worker
        builder.Services.AddHostedService<SharePointSynchronizerWorker>();

        var host = builder.Build();
        await host.RunAsync();
    }
}
