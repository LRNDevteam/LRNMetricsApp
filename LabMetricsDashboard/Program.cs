using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Filters;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.ReimbursementAgent;
using LabMetricsDashboard.Services.DenialDashboard;
using LabMetricsDashboard.Services.DenialWorkflow;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using LRN.ProductionReports.Services;
using LRN.ProductionReports.Services;
using LRN.ProductionReports.Services;
using Azure.Identity;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Http.Timeouts;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Configuration.Json;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Primitives;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.Authorization;
using Microsoft.AspNetCore.RateLimiting;
using System.Net;
using System.Security.Cryptography;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);

// Secrets (connection strings, JWT signing key, import API key) live in appsettings.Local.json,
// which is gitignored and machine/environment specific. The tracked appsettings*.json files must
// never contain credentials. Environment variables can also be used
// (e.g. ConnectionStrings__DefaultConnection).
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: true);

// ── Azure Key Vault ──────────────────────────────────────────────────────────────────────
// Production secrets live in kv-lrnmetrics-prod: every ConnectionStrings:* entry (LRNMaster plus
// each lab database) and the DenialWorkflowAuth:* block. The signing key in particular has to be
// byte-identical to the one LRN.ReportsApi validates with — a single vault secret is what keeps
// the two apps from drifting apart, which is the failure that logs every workflow user out.
//
// Vault secret names use "--" wherever configuration uses ":" — ConnectionStrings--DefaultConnection
// binds to ConnectionStrings:DefaultConnection. That is AddAzureKeyVault's own convention, so
// nothing here needs a custom KeyVaultSecretManager.
//
// Registered AFTER appsettings.Local.json so the vault wins wherever both define a key. A machine
// with no vault access blanks KeyVault:Uri in its appsettings.Local.json and keeps running on local
// secrets — an empty or absent URI skips this entirely.
// Recorded and logged below, once the file logger exists. A blank Uri silently switches the
// vault off, which surfaces much later as "DefaultConnection not configured" from whichever
// repository happens to resolve first — an error that names neither the vault nor the file
// that blanked it.
var keyVaultUri = builder.Configuration["KeyVault:Uri"];
var keyVaultApplied = ApplyKeyVault(builder.Configuration, keyVaultUri);

const string DenialWorkflowLocalDevCorsPolicy = "DenialWorkflowLocalDevCors";

// Windows Event Log requires elevated access on some developer machines. Keep local
// startup independent of that external service while retaining normal production logging.
if (builder.Environment.IsDevelopment())
{
    builder.Logging.ClearProviders();
    builder.Logging.AddConsole();
    builder.Logging.AddDebug();
}

// Local React/Vite runs on https://localhost:5173 and calls MVC through the
// project or IIS Express HTTPS ports (44350/44351/57996).
// For fetch(..., credentials: "include") the auth cookie must be SameSite=None and Secure.
var useWorkflowCrossOriginCookie = builder.Environment.IsDevelopment()
    || builder.Configuration.GetValue<bool>("DenialWorkflowAuth:UseCrossOriginCookies");

// ── File logging ─────────────────────────────────────────────────
// Writes Warning+ logs (DB errors, crashes) to rolling daily text files.
var fileLogSection = builder.Configuration.GetSection("Logging:File");

var configuredLogDir = builder.Environment.IsDevelopment()
    ? Path.Combine(AppContext.BaseDirectory, "Logs")
    : fileLogSection["LogDirectory"];
var resolvedLogDir = string.IsNullOrWhiteSpace(configuredLogDir)
    ? Path.Combine(AppContext.BaseDirectory, "Logs")
    : (Path.IsPathRooted(configuredLogDir)
        ? configuredLogDir
        : Path.Combine(AppContext.BaseDirectory, configuredLogDir));

var fileLogOptions = new FileLoggerOptions
{
    LogDirectory = resolvedLogDir,
    MinLevel = Enum.TryParse<LogLevel>(fileLogSection["LogLevel"], true, out var lvl)
        ? lvl
        : LogLevel.Warning,
    ProductionExcelSplitMinLevel = Enum.TryParse<LogLevel>(fileLogSection["ProductionExcelSplitLogLevel"], true, out var splitLvl)
        ? splitLvl
        : LogLevel.Information,
    RetainDays = int.TryParse(fileLogSection["RetainDays"], out var rd)
        ? rd
        : 30
};

try
{
    builder.Logging.AddProvider(new FileLoggerProvider(fileLogOptions));
}
catch (Exception ex)
{
    // Do not fail app startup because custom file logger failed.
    Console.Error.WriteLine($"File logger initialization failed: {ex}");
}

// ── Where secrets came from ─────────────────────────────────────────────────────
// Logged as early as the file logger allows, because getting this wrong is silent: with the
// vault off, every ConnectionStrings:* entry is simply absent and the first repository to be
// constructed throws "DefaultConnection not configured" — naming neither the vault nor the
// appsettings.Local.json that switched it off. On a server this line should always report
// the vault; if it reports SKIPPED, look for a stray appsettings.Local.json in the deployed
// folder (it ships in build output, though never in `dotnet publish` output) or a
// KeyVault__Uri environment variable overriding appsettings.json.
if (keyVaultApplied)
{
    LogStartupWarning($"Key Vault loaded: {keyVaultUri}");

    // Logged first, checked second: "loaded" only means the vault answered. A vault that
    // authenticates but holds none of these still starts the site cleanly, and the failure then
    // arrives as "DefaultConnection not configured" on the first page that touches a database —
    // naming the symptom, not the empty vault behind it. That is exactly what a deployment looks
    // like when the identity and RBAC are in place but the secrets were never created.
    RequireVaultSecrets(builder.Configuration,
        "ConnectionStrings:DefaultConnection",
        "DenialWorkflowAuth:JwtSigningKey");
}
else
{
    LogStartupWarning(
        "Key Vault SKIPPED — KeyVault:Uri is empty or absent, so connection strings and the JWT " +
        "signing key must come from appsettings.Local.json or environment variables. This is " +
        "expected on a developer machine and a misconfiguration on a server.");
}

// Bind the "LabConfig" section from appsettings.json.
var labConfigOptions = builder.Configuration
    .GetSection(LabConfigOptions.Section)
    .Get<LabConfigOptions>() ?? new LabConfigOptions();

// Temporary startup logger helpers
void LogStartupError(string message, Exception? ex = null)
{
    try
    {
        var logDir = fileLogOptions.LogDirectory;
        if (!Path.IsPathRooted(logDir))
        {
            logDir = Path.Combine(AppContext.BaseDirectory, logDir);
        }

        Directory.CreateDirectory(logDir);

        var logFile = Path.Combine(logDir, $"startup-{DateTime.Now:yyyyMMdd}.log");
        var lines = new List<string>
        {
            new string('=', 120),
            $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}"
        };

        if (ex != null)
        {
            lines.Add(ex.ToString());
        }

        File.AppendAllLines(logFile, lines);
    }
    catch
    {
        // Do not crash startup because logging failed.
    }
}

void LogStartupWarning(string message)
{
    LogStartupError("WARNING: " + message);
}

// A JSON file save (lab config, appsettings, or a VS/IIS Express copy into bin)
// that is briefly empty or invalid used to throw JsonReaderException and shut
// the whole host down. Ignore reload failures and keep the last-good values.
void IgnoreJsonReloadError(FileLoadExceptionContext ctx)
{
    var path = ctx.Provider is FileConfigurationProvider fp
        ? fp.Source.Path ?? "(json)"
        : "(json)";
    LogStartupError(
        $"Ignored invalid JSON reload for '{path}'. Keeping last-good configuration so the site stays up.",
        ctx.Exception);
    ctx.Ignore = true;
}

foreach (var jsonSource in ((IConfigurationBuilder)builder.Configuration).Sources.OfType<JsonConfigurationSource>())
    jsonSource.OnLoadException = IgnoreJsonReloadError;

// Load each lab's dedicated JSON file from the shared config folder.
// Convention: {LabConfigFolder}{LabName}.json  e.g. Configs\PCRLabsofAmerica.json
var validLabNames = new List<string>();
var skippedLabNames = new List<string>();

// Determine which lab JSON files to load.
// Prefer a union of:
// - LabConfig:Labs (legacy explicit list)
// - LabConfig:LabsID[].Name (Id->Name mapping used for login/lab assignment)
// This ensures deployments that only update LabsID still load the per-lab JSON files.
var labNamesToLoad = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
foreach (var labName in labConfigOptions.Labs ?? Enumerable.Empty<string>())
{
    if (!string.IsNullOrWhiteSpace(labName)) labNamesToLoad.Add(labName);
}
foreach (var lab in labConfigOptions.LabsID ?? new List<LabIdInfo>())
{
    if (!string.IsNullOrWhiteSpace(lab.Name)) labNamesToLoad.Add(lab.Name);
}

if (labNamesToLoad.Count == 0)
{
    LogStartupWarning("No labs were configured to load. Configure LabConfig:Labs or LabConfig:LabsID in appsettings.json.");
}

// Lab JSON files live outside the web content root (LabConfigFolder).
// AddJsonFile(absolutePath) is resolved against ContentRoot, so the file is
// not found and every Enable* flag stays at its C# default (Production Summary = false).
PhysicalFileProvider? labConfigFileProvider = null;
var labConfigFolder = labConfigOptions.LabConfigFolder;
if (!string.IsNullOrWhiteSpace(labConfigFolder) && Directory.Exists(labConfigFolder))
{
    labConfigFileProvider = new PhysicalFileProvider(Path.GetFullPath(labConfigFolder));
}

foreach (var labName in labNamesToLoad)
{
    var filePath = Path.Combine(labConfigFolder ?? string.Empty, $"{labName}.json");

    if (!File.Exists(filePath))
    {
        LogStartupWarning($"Lab config file not found for lab '{labName}'. Expected path: {filePath}");
        skippedLabNames.Add(labName);
        continue;
    }

    try
    {
        // Validate JSON first so a malformed file does not crash the whole app.
        var jsonText = File.ReadAllText(filePath);
        using var _ = System.Text.Json.JsonDocument.Parse(jsonText);

        builder.Configuration.AddJsonFile(s =>
        {
            s.FileProvider = labConfigFileProvider
                ?? new PhysicalFileProvider(Path.GetDirectoryName(Path.GetFullPath(filePath))!);
            s.Path = Path.GetFileName(filePath);
            s.Optional = true;
            s.ReloadOnChange = true;
            s.OnLoadException = IgnoreJsonReloadError;
        });
        validLabNames.Add(labName);
    }
    catch (System.Text.Json.JsonException jsonEx)
    {
        LogStartupError(
            $"Invalid JSON in lab config file for lab '{labName}'. File: {filePath}",
            jsonEx);

        skippedLabNames.Add(labName);
    }
    catch (FormatException formatEx)
    {
        LogStartupError(
            $"Format error while loading lab config file for lab '{labName}'. File: {filePath}",
            formatEx);

        skippedLabNames.Add(labName);
    }
    catch (InvalidDataException dataEx)
    {
        LogStartupError(
            $"Invalid data while loading lab config file for lab '{labName}'. File: {filePath}",
            dataEx);

        skippedLabNames.Add(labName);
    }
    catch (Exception ex)
    {
        LogStartupError(
            $"Unexpected error while loading lab config file for lab '{labName}'. File: {filePath}",
            ex);

        skippedLabNames.Add(labName);
    }
}

if (skippedLabNames.Count > 0)
{
    LogStartupWarning($"Skipped lab configs: {string.Join(", ", skippedLabNames)}");
}

// Re-read configuration after all valid lab files have been added.
var configuration = builder.Configuration;

// Build LabSettings: each lab file is expected to have a root section matching the lab name.
// IMPORTANT: configuration uses reloadOnChange=true for lab files, but LabSettings is a singleton.
// If we build it once at startup, the app will NOT see lab config changes until an app restart.
// Hook configuration reload and rebuild LabSettings in-memory automatically.
var labSettings = new LabSettings();

void RebuildLabSettings()
{
    var previous = labSettings.Labs;
    labSettings.Labs = validLabNames.ToDictionary(
        labName => labName,
        labName =>
        {
            var loaded = configuration.GetSection(labName).Get<LabCsvConfig>() ?? new LabCsvConfig();
            // A JSON reload that parsed but dropped lab sections (or a briefly empty file)
            // used to replace a good config with defaults (all Enable* flags false). That
            // left the navbar showing the lab while Production Report had nothing to bind.
            if (string.IsNullOrWhiteSpace(loaded.DbConnectionString)
                && previous.TryGetValue(labName, out var existing)
                && !string.IsNullOrWhiteSpace(existing.DbConnectionString))
            {
                LogStartupWarning($"Kept last-good config for '{labName}' after a config reload with an empty connection string.");
                return existing;
            }
            return loaded;
        },
        StringComparer.OrdinalIgnoreCase);
}

RebuildLabSettings();

var summaryEnabledLabs = labSettings.Labs
    .Where(kv => kv.Value.EnableProductionSummaryReport)
    .Select(kv => kv.Key)
    .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
    .ToList();
LogStartupWarning(
    summaryEnabledLabs.Count == 0
        ? $"No labs have EnableProductionSummaryReport=true after loading from '{labConfigFolder}'. Loaded labs: {string.Join(", ", validLabNames)}"
        : $"Production Summary enabled for: {string.Join(", ", summaryEnabledLabs)}");

ChangeToken.OnChange(
    () => ((IConfigurationRoot)configuration).GetReloadToken(),
    () =>
    {
        try
        {
            RebuildLabSettings();
            LogStartupWarning($"Lab config reloaded: {string.Join(", ", validLabNames)}");
        }
        catch (Exception ex)
        {
            LogStartupError("Failed to rebuild LabSettings after configuration reload.", ex);
        }
    });

// ── Data Protection ─────────────────────────────────────────────────────────
// IMPORTANT FOR IIS PUBLISHING:
// Do NOT store DataProtection keys under the published web root unless IIS AppPool
// has write permission. In production the app was failing on /Account/Login because
// ASP.NET Core could not create/read:
//   C:\inetpub\wwwroot\LRNMetrics\DataProtectionKeys
// That breaks antiforgery token generation before the login page can render.
//
// Preferred production location:
//   C:\ProgramData\LRNMetrics\DataProtectionKeys
// Grant Modify permission to the IIS AppPool identity for that folder.

static bool TryEnsureWritableDirectory(string path, out DirectoryInfo directory, out string? error)
{
    directory = new DirectoryInfo(path);
    error = null;

    try
    {
        directory.Create();

        // Verify write permission now, during startup, instead of failing later
        // when the Login form tries to create an antiforgery token.
        var testFile = Path.Combine(directory.FullName, $".__write_test_{Guid.NewGuid():N}.tmp");
        File.WriteAllText(testFile, "ok");
        File.Delete(testFile);

        return true;
    }
    catch (Exception ex)
    {
        error = ex.Message;
        return false;
    }
}

var configuredDpKeysPath = builder.Configuration["DataProtection:KeysPath"];

var preferredDpKeysPath = string.IsNullOrWhiteSpace(configuredDpKeysPath)
    ? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "LRNMetrics",
        "DataProtectionKeys")
    : (Path.IsPathRooted(configuredDpKeysPath)
        ? configuredDpKeysPath
        : Path.Combine(AppContext.BaseDirectory, configuredDpKeysPath));

if (!TryEnsureWritableDirectory(preferredDpKeysPath, out var dpKeysDir, out var dpError))
{
    LogStartupWarning($"DataProtection keys path is not writable: {preferredDpKeysPath}. Error: {dpError}");

    // Fallback keeps the application alive even when the configured IIS folder has
    // no permission. This prevents the login page from crashing. For best stability
    // across app-pool recycles, fix folder permission and use ProgramData path.
    var fallbackDpKeysPath = Path.Combine(AppContext.BaseDirectory, "App_Data", "DataProtectionKeys");

    if (!TryEnsureWritableDirectory(fallbackDpKeysPath, out dpKeysDir, out var fallbackError))
    {
        throw new InvalidOperationException(
            $"DataProtection key storage is not writable. Preferred path: '{preferredDpKeysPath}' ({dpError}). " +
            $"Fallback path: '{fallbackDpKeysPath}' ({fallbackError}). " +
            "Grant Modify permission to the IIS AppPool identity or set DataProtection:KeysPath to a writable folder.");
    }

    LogStartupWarning($"DataProtection keys path fallback is being used: {dpKeysDir.FullName}");
}
else
{
    LogStartupWarning($"DataProtection keys path: {dpKeysDir.FullName}");
}

builder.Services
    .AddDataProtection()
    .PersistKeysToFileSystem(dpKeysDir)
    .SetApplicationName("LRNMetricsDashboard");

builder.Services.AddAntiforgery(options =>
{
    //<<<<<<< HEAD
    //    options.Cookie.Name         = "LRN.Antiforgery";
    //    options.Cookie.SameSite     = SameSiteMode.Lax;
    //    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
    //    options.Cookie.HttpOnly     = true;
    //=======
    //	options.Cookie.Name = "LRN.Antiforgery";
    //	options.Cookie.SameSite = builder.Environment.IsDevelopment() ? SameSiteMode.Lax : SameSiteMode.None;
    options.Cookie.Path = "/";
    //	options.Cookie.SecurePolicy = builder.Environment.IsDevelopment()
    //		? CookieSecurePolicy.SameAsRequest
    //		: CookieSecurePolicy.Always;
    //	options.Cookie.HttpOnly = true;
    //>>>>>>> 23cf9fdcfbffecee7d6826a98b7baa4821a4bc13

    options.Cookie.Name = "LRN.Antiforgery";
    // Lax works for same-site forms on local IIS (http://localhost/LRNMetrics) and
    // HTTPS production. SameSite=None requires a Secure cookie and breaks plain HTTP.
    options.Cookie.SameSite = SameSiteMode.Lax;
    options.Cookie.Path = "/";
    // SameAsRequest: do not require SSL to render antiforgery tokens.
    // CookieSecurePolicy.Always throws InvalidOperationException on Login when the
    // site is published as Production but opened over HTTP (local IIS).
    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
    options.Cookie.HttpOnly = true;

    // Lets a JSON fetch() carry the token in a header instead of a form field — the form-field
    // name keeps working unchanged, so no existing POST is affected. Required by the
    // Reimbursement Insights chat, which posts application/json rather than a form.
    options.HeaderName = "RequestVerificationToken";
});

// ── Forwarded Headers (IIS reverse-proxy / SSL termination) ────────────────────
// IIS terminates HTTPS and forwards requests to the ASP.NET Core process as HTTP.
// Without this the app sees "http://" as the request scheme, so cookies are issued
// without the Secure flag, Chrome drops them on the HTTPS redirect after login.
// This also covers out-of-process (reverse-proxy) deployments.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    // Trust loopback (127.0.0.1 / ::1) — the address IIS uses when forwarding internally.
    foreach (var proxy in builder.Configuration.GetSection("ForwardedHeaders:KnownProxies").Get<string[]>() ?? Array.Empty<string>())
    {
        if (IPAddress.TryParse(proxy, out var address)) options.KnownProxies.Add(address);
    }
});

var useMockData = builder.Configuration.GetValue<bool>("DashboardData:UseMockData");
if (useMockData)
{
    builder.Services.AddSingleton<IDenialRecordRepository, MockDenialRecordRepository>();
}
else
{
    builder.Services.AddScoped<IDenialRecordRepository, SqlDenialRecordRepository>();
}

builder.Services.AddSingleton(labSettings);
builder.Services.AddSingleton(labConfigOptions);
builder.Services.AddSingleton<LabCsvFileResolver>();
builder.Services.AddSingleton<CsvParserService>();
builder.Services.AddSingleton<PredictionInsightLoader>();
builder.Services.AddSingleton<RcmJsonWriterService>();
builder.Services.AddScoped<PredictionReportParserService>();
builder.Services.AddScoped<IPredictionDbRepository, SqlPredictionDbRepository>();
builder.Services.AddScoped<DenialDescriptionMasterLookup>();
builder.Services.AddScoped<ICodingValidationRepository, SqlCodingValidationRepository>();
builder.Services.AddScoped<IClinicSummaryRepository, SqlClinicSummaryRepository>();
builder.Services.AddScoped<ISalesRepSummaryRepository, SqlSalesRepSummaryRepository>();
builder.Services.AddScoped<IDashboardRepository, SqlDashboardRepository>();
builder.Services.AddScoped<IProductionReportRepository, SqlProductionReportRepository>();
builder.Services.AddScoped<IAnalysisRangeService, AnalysisRangeService>();
builder.Services.AddScoped<INorthWestProductionSummaryRepository, SqlNorthWestProductionSummaryRepository>();
builder.Services.AddScoped<IAugustusProductionSummaryRepository, SqlAugustusProductionSummaryRepository>();

// ── Per-lab generic production summary repositories (Certus, Cove, Elixir, PCRLabsofAmerica, Beech_Tree, Rising_Tides, Phi_Life, Inhealth_DTR) ──
// One SqlLabProductionSummaryRepository per lab, keyed by the lab name used in the LabSettings config.
builder.Services.AddSingleton<IReadOnlyDictionary<string, ILabProductionSummaryRepository>>(sp =>
{
    var logger = sp.GetRequiredService<ILogger<SqlLabProductionSummaryRepository>>();
    return new Dictionary<string, ILabProductionSummaryRepository>(StringComparer.OrdinalIgnoreCase)
    {
        ["Certus"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Certus),
        ["Cove"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Cove),
        ["Elixir"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Elixir),
        ["PCRLabsofAmerica"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.PCRLabsofAmerica),
        ["Beech_Tree"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.BeechTree),
        ["Rising_Tides"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.RisingTides),
        ["Phi_Life"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.PhiLife),
        ["Inhealth_DTR"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.InHealthDTR),
    };
});
// The lab list lives in LabProductionSummaryRepositoryMap so LRN.ReportWorker
// registers exactly the same set (queued Excel exports go through the worker).
builder.Services.AddSingleton<IReadOnlyDictionary<string, ILabProductionSummaryRepository>>(sp =>
    LabProductionSummaryRepositoryMap.Create(
        sp.GetRequiredService<ILogger<SqlLabProductionSummaryRepository>>()));
builder.Services.AddScoped<IClaimLineRepository, SqlClaimLineRepository>();
builder.Services.AddScoped<ICptSearchRepository, SqlCptSearchRepository>();
builder.Services.AddScoped<ICollectionSummaryRepository, SqlCollectionSummaryRepository>();
builder.Services.AddScoped<AllLabsCollectionExcelBuilder>();
builder.Services.AddScoped<PayerPolicyValidationService>();

// Async report queue (UserReqReports per lab DB; generation runs in LRN.ReportWorker)
builder.Services.AddSingleton<LRN.ReportQueue.Shared.IReportRequestRepository,
    LRN.ReportQueue.Shared.SqlReportRequestRepository>();
builder.Services.AddScoped<UserReportService>();

builder.Services.AddScoped<ILisSummaryRepository, SqlLisSummaryRepository>();
builder.Services.AddScoped<SqlPhiExecutiveSummaryRepository>();
builder.Services.AddScoped<BeechTreeRevenuePipelineLisService>();
builder.Services.AddScoped<INotesRepository, SqlNotesRepository>();
builder.Services.AddScoped<ExecutiveSummaryExcelBuilder>();

// User management repository (uses DefaultConnection from appsettings.json)
builder.Services.AddScoped<IUserManagementRepository, SqlUserManagementRepository>();
builder.Services.AddScoped<WorkflowJwtIssuer>();
// Password hasher
builder.Services.AddSingleton<IPasswordHasher, PasswordHasher>();

// Add services to the container.
builder.Services.AddMemoryCache();
builder.Services.AddHttpContextAccessor();
// Usage audit: requests only enqueue; a background writer performs the SQL INSERTs
// so a slow/remote audit database never adds latency to page loads.
builder.Services.AddSingleton<AppUsageAuditQueue>();
builder.Services.AddHostedService<AppUsageAuditBackgroundWriter>();
builder.Services.AddScoped<SqlAppUsageAuditService>();
builder.Services.AddScoped<IAppUsageAuditService>(sp => sp.GetRequiredService<SqlAppUsageAuditService>());
builder.Services.AddScoped<AppUsageAuditFilter>();

// In-app Help Bot (singleton - loads topic file once at startup)
builder.Services.AddSingleton<HelpBotService>();

builder.Services.Configure<DenialWorkflowOptions>(builder.Configuration.GetSection("DenialWorkflowApi"));
builder.Services.AddHttpClient<IDenialWorkflowApiClient, DenialWorkflowApiClient>();
// Denial Dashboard data now comes from LRN.ReportsApi. Long timeout because GetByLab returns
// the full task-board set (can be tens of thousands of rows) for in-memory aggregation.
builder.Services
    .AddHttpClient<IDenialDashboardApiClient, DenialDashboardApiClient>()
    .ConfigureHttpClient(client => client.Timeout = TimeSpan.FromMinutes(10));
builder.Services
    .AddHttpClient<IMasterValuesApiClient, MasterValuesApiClient>()
    .ConfigureHttpClient(client => client.Timeout = TimeSpan.FromMinutes(10));
// Analytics reference lists (Modes / Meridian) served by LRN.ReportsApi.
builder.Services
    .AddHttpClient<ILabAnalyticsApiClient, LabAnalyticsApiClient>()
    .ConfigureHttpClient(client => client.Timeout = TimeSpan.FromMinutes(2));
// Report Control Board (report workflow tracker). Short timeout: this is a landing page, and a
// slow tracker must show the error card quickly rather than hold the page.
builder.Services
    .AddHttpClient<IReportBoardApiClient, ReportBoardApiClient>()
    .ConfigureHttpClient(client => client.Timeout = TimeSpan.FromSeconds(15));
builder.Services.AddSingleton<ILabNameResolver, LabNameResolver>();

// ── Reimbursement Insights chat (Foundry agent via the ReimbursementAgentProxy App Service) ──
// The browser posts to ReimbursementChatController on this origin and this app calls the proxy,
// rather than the page calling azurewebsites.net directly. Two reasons that is not optional here:
// the site's own Content-Security-Policy allows connect-src 'self' only, so a direct browser call
// would be blocked outright; and relaying keeps the shared ChatToken signing key server-side.
builder.Services.Configure<ReimbursementAgentOptions>(
    configuration.GetSection(ReimbursementAgentOptions.Section));
builder.Services.Configure<ReimbursementChatTokenOptions>(
    configuration.GetSection(ReimbursementChatTokenOptions.Section));
builder.Services.AddSingleton<ReimbursementChatTokenIssuer>();

// Long timeout by design: one answer is a whole agent run — the model reasons, calls the MCP
// bridge, and writes a per-lab breakdown — which routinely takes far longer than a data API call.
builder.Services
    .AddHttpClient<IReimbursementAgentApiClient, ReimbursementAgentApiClient>()
    .ConfigureHttpClient(client => client.Timeout = TimeSpan.FromSeconds(
        builder.Configuration.GetValue<int?>("ReimbursementAgent:TimeoutSeconds") ?? 120));

// Which reports the board offers to which labs — the padlocked cells. Bound with IOptionsMonitor
// (not Get<T>()) so editing the "ReportAvailability" section of appsettings.json takes effect on
// the next page load, without restarting the site.
builder.Services.Configure<ReportAvailabilitySettings>(configuration.GetSection("ReportAvailability"));
builder.Services.AddSingleton<IReportAvailabilityService, ReportAvailabilityService>();

// Dynamic role-based navbar (Menu Master + Role Menu Mapping via LRN.ReportsApi).
// Short timeout: this client sits on the hot path of EVERY page (navbar + MenuAccessFilter).
// A slow/unreachable Reports API must fail fast so pages keep rendering (menu falls back
// to the static navbar and access checks fail open).
builder.Services
    .AddHttpClient<IMenuApiClient, MenuApiClient>()
    .ConfigureHttpClient(client => client.Timeout = TimeSpan.FromSeconds(
        builder.Configuration.GetValue<int?>("DenialWorkflowApi:MenuTimeoutSeconds") ?? 5));
builder.Services.AddScoped<IMenuService, MenuService>();
builder.Services.AddScoped<MenuAccessFilter>();

// Allow local Vite React dev server to call MVC AuthToken endpoint with cookies.
// Production stays same-origin, but these origins are useful while debugging React locally.
var denialWorkflowCorsOrigins = builder.Configuration
    .GetSection("DenialWorkflowCors:AllowedOrigins")
    .Get<string[]>()
    ?.Where(x => !string.IsNullOrWhiteSpace(x))
    .Select(x => x.Trim().TrimEnd('/'))
    .Distinct(StringComparer.OrdinalIgnoreCase)
    .ToArray()
    ?? new[]
    {
        "http://localhost:5173",
        "https://localhost:5173",
        "http://127.0.0.1:5173",
        "https://127.0.0.1:5173"
    };

builder.Services.AddCors(options =>
{
    options.AddPolicy(DenialWorkflowLocalDevCorsPolicy, policy =>
    {
        policy
            .WithOrigins(denialWorkflowCorsOrigins)
            .AllowAnyHeader()
            .AllowAnyMethod()
            .AllowCredentials();
    });
});

builder.Services.AddRateLimiter(options =>
{
    options.AddPolicy("login", context =>
        RateLimitPartition.GetFixedWindowLimiter(
            $"{context.Connection.RemoteIpAddress}|{(context.Request.HasFormContentType ? context.Request.Form["UserName"].ToString().Trim().ToUpperInvariant() : string.Empty)}",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = builder.Configuration.GetValue<int?>("Security:LoginRateLimit:PermitLimit") ?? 5,
                Window = TimeSpan.FromMinutes(builder.Configuration.GetValue<int?>("Security:LoginRateLimit:WindowMinutes") ?? 1),
                QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
                QueueLimit = 0
            }));

    // Reimbursement chat: partitioned by user, not by IP. The agent proxy rate-limits per calling
    // IP, and every question from this site now arrives from this one server address — so its
    // limit can no longer separate one user from another. This is where per-person fairness (and
    // the cost ceiling that limit was protecting) has to be enforced instead.
    options.AddPolicy(ReimbursementChatRateLimit.PolicyName, context =>
        RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: context.User.Identity?.Name
                          ?? context.Connection.RemoteIpAddress?.ToString()
                          ?? "unknown",
            factory: _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = builder.Configuration.GetValue<int?>("ReimbursementAgent:RateLimit:PermitLimit") ?? 10,
                Window = TimeSpan.FromMinutes(
                    builder.Configuration.GetValue<int?>("ReimbursementAgent:RateLimit:WindowMinutes") ?? 1),
                QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
                QueueLimit = 0
            }));

    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
});

// Compress large HTML responses (Coding Summary renders all tabs in one page;
// gzip/brotli typically shrinks it 10-20x, cutting transfer time drastically).
builder.Services.AddResponseCompression(options =>
{
    options.EnableForHttps = true;
});

builder.Services.AddControllersWithViews(options =>
{
    options.Filters.AddService<AppUsageAuditFilter>();
    // Server-side menu enforcement (FR-9): blocks direct URLs to menu-managed
    // routes the user's role has no mapping for. Non-managed routes pass through.
    options.Filters.AddService<MenuAccessFilter>();
    // Require authenticated user for every action by default.
    // Use [AllowAnonymous] on Account/Login etc.
    var policy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
    options.Filters.Add(new AuthorizeFilter(policy));
});

builder.Services.AddRequestTimeouts();

// ── Cookie authentication ─────────────────────────────────────────
builder.Services
    //<<<<<<< HEAD
    //    .AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    //    .AddCookie(options =>
    //    {
    //        options.LoginPath        = "/Account/Login";
    //        options.LogoutPath       = "/Account/Logout";
    //        options.AccessDeniedPath = "/Account/AccessDenied";
    //        options.ExpireTimeSpan   = TimeSpan.FromHours(8);
    //        options.SlidingExpiration = true;
    //        options.Cookie.Name     = "LRN.Auth";
    //        options.Cookie.HttpOnly  = true;
    //        options.Cookie.SameSite  = SameSiteMode.Lax;
    //        // SameAsRequest: Secure flag is added only when the connection is already HTTPS.
    //        // Using Always on an HTTP-only IIS server caused Chrome to silently drop the
    //        // auth cookie after login, so every request was redirected back to the login page.
    //        options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
    //=======
    .AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath = "/Account/Login";
        options.LogoutPath = "/Account/Logout";
        options.AccessDeniedPath = "/Account/AccessDenied";
        options.ExpireTimeSpan = TimeSpan.FromHours(8);
        options.SlidingExpiration = true;
        options.Cookie.Name = "LRN.Auth";
        options.Cookie.HttpOnly = true;
        options.Cookie.SameSite = useWorkflowCrossOriginCookie ? SameSiteMode.None : SameSiteMode.Lax;
        options.Cookie.Path = "/";
        // Required for local React/Vite cross-origin AuthToken fetch.
        // If this is SameAsRequest/Lax in Development, Chrome will not send LRN.Auth
        // from https://localhost:5173 to https://localhost:44350, causing login loops.
        options.Cookie.SecurePolicy = useWorkflowCrossOriginCookie
            ? CookieSecurePolicy.Always
            // SameAsRequest for normal same-site host: works on HTTPS prod and HTTP local IIS.
            // Always on HTTP local Production drops the auth cookie after login (Chrome).
            : CookieSecurePolicy.SameAsRequest;

        // ── ReturnUrl loop guard ──────────────────────────────────────────────
        // Prevent the error and login pages from being embedded as a ReturnUrl.
        // Without this guard, a failing error page causes an exponentially growing
        // ReturnUrl query string (/Home/Error?ReturnUrl=/Home/Error?...) until IIS
        // rejects the request with HTTP 404.15 (query string too long).
        //
        // CRITICAL: when the app is hosted as an IIS sub-application (e.g. /LRNMetrics),
        // every redirect URL MUST be prefixed with Request.PathBase, otherwise IIS routes
        // the redirect to the root site and returns 404.0 (file not found).
        options.Events = new CookieAuthenticationEvents
        {
            OnRedirectToLogin = ctx =>
            {
                var returnUrl = ctx.Properties.RedirectUri ?? string.Empty;

                // A "safe" ReturnUrl is one that does NOT point at the error/login/logout
                // pages — those would just trigger another redirect cycle.
                var isSafeReturn =
                    !string.IsNullOrWhiteSpace(returnUrl)
                    && !returnUrl.Contains("/Home/Error", StringComparison.OrdinalIgnoreCase)
                    && !returnUrl.Contains("/Account/Login", StringComparison.OrdinalIgnoreCase)
                    && !returnUrl.Contains("/Account/Logout", StringComparison.OrdinalIgnoreCase);

                // Build the login URL using PathBase so sub-app deployments (e.g. /LRNMetrics)
                // work correctly. Without PathBase the redirect goes to the IIS root site.
                var pathBase = ctx.Request.PathBase.HasValue ? ctx.Request.PathBase.Value : string.Empty;
                var loginUri = $"{pathBase}{options.LoginPath}";

                if (isSafeReturn)
                {
                    // Preserve the ReturnUrl exactly as the framework would have built it.
                    loginUri = $"{loginUri}?ReturnUrl={Uri.EscapeDataString(returnUrl)}";
                }

                ctx.Response.Redirect(loginUri);
                return Task.CompletedTask;
            },

            // Business rule: never show the raw "Access Denied" page. An authenticated-but-
            // unauthorized request (a stale session, or a denied action) is sent to the Metrics
            // login page instead — a fresh login resolves the common stale-session case.
            OnRedirectToAccessDenied = ctx =>
            {
                var returnUrl = ctx.Properties.RedirectUri ?? string.Empty;
                var isSafeReturn =
                    !string.IsNullOrWhiteSpace(returnUrl)
                    && !returnUrl.Contains("/Home/Error", StringComparison.OrdinalIgnoreCase)
                    && !returnUrl.Contains("/Account/Login", StringComparison.OrdinalIgnoreCase)
                    && !returnUrl.Contains("/Account/Logout", StringComparison.OrdinalIgnoreCase)
                    && !returnUrl.Contains("/Account/AccessDenied", StringComparison.OrdinalIgnoreCase);

                var pathBase = ctx.Request.PathBase.HasValue ? ctx.Request.PathBase.Value : string.Empty;
                var loginUri = $"{pathBase}{options.LoginPath}";
                if (isSafeReturn)
                {
                    loginUri = $"{loginUri}?ReturnUrl={Uri.EscapeDataString(returnUrl)}";
                }

                ctx.Response.Redirect(loginUri);
                return Task.CompletedTask;
            },
        };




    });

var app = builder.Build();

// Log skipped labs into normal logger after DI is ready.
if (skippedLabNames.Count > 0)
{
    var startupLogger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("Startup");
    startupLogger.LogWarning("Some lab config files were skipped due to missing/invalid JSON: {Labs}", skippedLabNames);
}

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
}

// ── Forwarded headers MUST be processed first ────────────────────────────────
// Reads X-Forwarded-For / X-Forwarded-Proto from IIS and rewrites Request.Scheme
// to "https" so every downstream middleware (auth, cookie policy, HTTPS redirect)
// sees the correct scheme.  Without this, IIS terminates SSL and the app sees
// "http://" — cookies are issued without the Secure flag and Chrome drops them.
app.UseForwardedHeaders();

app.Use(ApplySecurityHeadersMiddleware);

// ── Stale cookie self-healing ──────────────────────────────────────────────
// When the DataProtection key ring changes (e.g. when persistence was first turned on,
// or when keys are deleted/rotated), pre-existing browser cookies cannot be decrypted
// and the antiforgery filter rejects the request with HTTP 400 — the user just sees
// a blank/error page. Catch that exception, delete the offending cookies, and redirect
// to the same URL so the next request gets fresh cookies issued by the current key ring.
app.Use(async (context, next) =>
{
    try
    {
        await next();
    }
    catch (Exception ex) when (
        ex is System.Security.Cryptography.CryptographicException
        || ex is Microsoft.AspNetCore.Antiforgery.AntiforgeryValidationException
        || ex.InnerException is System.Security.Cryptography.CryptographicException)
    {
        var staleCookieNames = context.Request.Cookies.Keys
            .Where(k => k.StartsWith("LRN.", StringComparison.OrdinalIgnoreCase)
                     || k.StartsWith(".AspNetCore.", StringComparison.OrdinalIgnoreCase))
            .ToList();

        foreach (var cookieName in staleCookieNames)
            context.Response.Cookies.Delete(cookieName);

        var staleLogger = context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("StaleCookieRecovery");
        staleLogger.LogWarning(ex,
            "Stale auth/antiforgery cookie(s) cleared for {Path} (cookies: {Cookies}). Redirecting to retry.",
            context.Request.Path, string.Join(",", staleCookieNames));

        if (!context.Response.HasStarted)
        {
            // Send the user back to the same URL so the request runs again with fresh cookies.
            var pathBase = context.Request.PathBase.HasValue ? context.Request.PathBase.Value : string.Empty;
            var path = context.Request.Path.HasValue ? context.Request.Path.Value : "/";
            context.Response.Redirect($"{pathBase}{path}");
        }
    }
});


// ── Global error logging (all environments) ─────────────────────
app.Use(async (context, next) =>
{
    try
    {
        await next();
    }
    catch (Exception ex)
    {
        var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("UnhandledException");

        logger.LogCritical(ex,
            "Unhandled exception on {Method} {Path}{Query} | TraceId={TraceId}",
            context.Request.Method,
            context.Request.Path,
            context.Request.QueryString,
            context.TraceIdentifier);

        throw;
    }
});

// ── Login antiforgery 400 self-healing ────────────────────────────────────────
// After every publish the DataProtection key ring may change (especially on a fresh
// IIS app pool / new worker process). Browsers — Chrome in particular, which is
// stricter than Edge about persisting cookies across HTTPS reconnections — still
// hold the old LRN.Antiforgery / LRN.Auth cookies. On the next POST /Account/Login
// the [ValidateAntiForgeryToken] filter inside MVC silently fails validation and
// returns HTTP 400 *without* throwing — so the cookie-clearing exception handler
// above never sees it and the user is stuck on Chrome's "This page isn't working"
// screen. This middleware runs AFTER the MVC pipeline (it inspects the response
// status code), and when it sees a 400 on a POST under /Account/, deletes the
// stale cookies and redirects to GET /Account/Login so the next request gets a
// fresh antiforgery token from the current key ring.
app.Use(async (context, next) =>
{
    await next();

    if (context.Response.StatusCode != StatusCodes.Status400BadRequest) return;
    if (context.Response.HasStarted) return;
    if (!HttpMethods.IsPost(context.Request.Method)) return;

    var path = context.Request.Path.Value ?? string.Empty;
    if (!path.StartsWith("/Account/", StringComparison.OrdinalIgnoreCase)) return;

    var staleCookieNames = context.Request.Cookies.Keys
        .Where(k => k.StartsWith("LRN.", StringComparison.OrdinalIgnoreCase)
                 || k.StartsWith(".AspNetCore.", StringComparison.OrdinalIgnoreCase))
        .ToList();

    foreach (var cookieName in staleCookieNames)
        context.Response.Cookies.Delete(cookieName);

    context.RequestServices.GetRequiredService<ILoggerFactory>()
        .CreateLogger("LoginCookieRecovery")
        .LogWarning(
            "POST {Path} returned 400 (likely stale antiforgery/auth cookie after publish). " +
            "Cleared {Count} cookie(s) [{Names}] and redirecting to login.",
            path, staleCookieNames.Count, string.Join(",", staleCookieNames));

    var pathBase = context.Request.PathBase.HasValue ? context.Request.PathBase.Value : string.Empty;
    context.Response.Clear();
    context.Response.Redirect($"{pathBase}/Account/Login");
});

// HTTPS redirection: only useful when running standalone (Visual Studio / Kestrel).
// In IIS, HTTPS is already enforced at the IIS binding / URL Rewrite level, and
// HttpsRedirectionMiddleware logs "Failed to determine the https port" because it
// cannot infer the port behind the reverse proxy. Disable it for production.
if (app.Environment.IsDevelopment())
{
    app.UseHttpsRedirection();
}
app.UseResponseCompression();
app.UseStaticFiles();
app.UseRouting();
app.UseRequestTimeouts();

// Must be after UseRouting and before UseAuthentication so preflight/AuthToken
// responses include Access-Control-Allow-Origin for local React dev.
app.UseCors(DenialWorkflowLocalDevCorsPolicy);

app.UseAuthentication();
app.UseAuthorization();

// After authentication, not before: the reimbursement-chat policy partitions by signed-in
// user, and HttpContext.User is only populated once the cookie has been read. Ahead of
// UseAuthentication every request looks anonymous and the partition collapses to the caller
// IP. The login policy is unaffected — it keys off the posted form and the IP, never User.
app.UseRateLimiter();

app.MapStaticAssets();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=ReportBoard}/{action=Index}/{id?}")
    .WithStaticAssets();

// Map attribute-routed controllers (e.g. HelpBotController -> /api/helpbot/*)
app.MapControllers();

app.Run();

static async Task ApplySecurityHeadersMiddleware(HttpContext context, Func<Task> next)
{
    context.Items["CspNonce"] = Convert.ToBase64String(RandomNumberGenerator.GetBytes(16));
    ApplySecurityHeaders(context);
    await next();
}

/// <summary>
/// Layers Azure Key Vault over the configuration already loaded, when KeyVault:Uri names one.
/// </summary>
/// <returns>True when the vault was layered on; false when KeyVault:Uri named none.</returns>
static bool ApplyKeyVault(IConfigurationBuilder configuration, string? uri)
{
    var trimmed = uri?.Trim();
    if (string.IsNullOrEmpty(trimmed)) return false;

    // Validated rather than handed straight to the SDK: the URI is hand-maintained in
    // appsettings.json and a typo there ("https: //…") otherwise surfaces much later as a
    // connection string that is simply missing.
    if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var vaultUri) || vaultUri.Scheme != Uri.UriSchemeHttps)
        throw new InvalidOperationException(
            $"KeyVault:Uri must be an absolute https URI, e.g. https://kv-lrnmetrics-prod.vault.azure.net/ — got '{trimmed}'.");

    try
    {
        // DefaultAzureCredential so one build authenticates everywhere it is deployed: the app
        // pool's managed identity in Azure, AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_CLIENT_SECRET
        // where a service principal is used instead, and the developer's `az login` or Visual
        // Studio account locally.
        configuration.AddAzureKeyVault(vaultUri, new DefaultAzureCredential());
        return true;
    }
    catch (Exception ex)
    {
        // Continuing would boot the site with no connection strings and no JWT signing key. Every
        // page would then fail deep inside a repository, naming a missing connection string rather
        // than the vault that never loaded. Stop here, where the message can name the real cause.
        throw new InvalidOperationException(
            $"Could not load secrets from Azure Key Vault '{vaultUri}'. The vault uses RBAC (not access " +
            $"policies), so the identity running this process needs the 'Key Vault Secrets User' role on it, " +
            $"and this host must be able to reach the vault.", ex);
    }
}

/// <summary>
/// Confirms the vault actually delivered the settings the site cannot run without.
///
/// Reading the vault successfully and finding what you need in it are two different things, and
/// only the first one fails loudly on its own. The message names the secret to create, in the
/// '--' form you type into the vault, because that is the only form that helps at 2am.
/// </summary>
static void RequireVaultSecrets(IConfiguration configuration, params string[] requiredKeys)
{
    var missing = requiredKeys.Where(k => string.IsNullOrWhiteSpace(configuration[k])).ToArray();
    if (missing.Length == 0) return;

    var secretNames = string.Join(", ", missing.Select(k => k.Replace(":", "--")));
    throw new InvalidOperationException(
        $"Azure Key Vault was read successfully but is missing {missing.Length} required secret(s): {secretNames}. " +
        $"Create them in the vault (secret names use '--' where configuration uses ':'), or clear KeyVault:Uri to " +
        $"run from local settings instead. Values stored as vault TAGS are not secrets and are never loaded.");
}

static void ApplySecurityHeaders(HttpContext context)
{
    var environment = context.RequestServices.GetRequiredService<IWebHostEnvironment>();
    // Local login can move between Vite, Kestrel, and IIS Express ports. Browsers
    // validate every form redirect against form-action, so a fixed port list is
    // fragile even when the initial POST target is present. form-action does not
    // fall back to default-src: omit it only in Development and keep Production
    // restricted to the origin that served the login page.
    var formActionDirective = environment.IsDevelopment()
        ? string.Empty
        : "form-action 'self'; ";

    var headers = context.Response.Headers;
    headers["X-Content-Type-Options"] = "nosniff";
    headers["X-Frame-Options"] = "SAMEORIGIN";
    headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
    headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=()";
    headers["Content-Security-Policy"] =
        "default-src 'self'; " +
        "base-uri 'self'; " +
        "object-src 'none'; " +
        "frame-ancestors 'self'; " +
        formActionDirective +
        "img-src 'self' data: blob:; " +
        "font-src 'self' data:; " +
        "style-src 'self' 'unsafe-inline'; " +
        $"script-src 'self' 'nonce-{context.Items["CspNonce"]}'; " +
        "connect-src 'self' http://localhost:* https://localhost:* ws://localhost:* wss://localhost:* http://127.0.0.1:* https://127.0.0.1:* ws://127.0.0.1:* wss://127.0.0.1:*";

    if (context.Request.IsHttps)
    {
        headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains";
    }
}
