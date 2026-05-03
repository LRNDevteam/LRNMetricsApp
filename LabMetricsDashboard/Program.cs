using LabMetricsDashboard.Filters;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
<<<<<<< HEAD
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;
=======
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Configuration.Json;
using Microsoft.Extensions.Primitives;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.Authorization;

var builder = WebApplication.CreateBuilder(args);

// ── File logging ─────────────────────────────────────────────────
// Writes Warning+ logs (DB errors, crashes) to rolling daily text files.
var fileLogSection = builder.Configuration.GetSection("Logging:File");

var configuredLogDir = fileLogSection["LogDirectory"];
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

foreach (var labName in labNamesToLoad)
{
	var filePath = Path.Combine(labConfigOptions.LabConfigFolder ?? string.Empty, $"{labName}.json");

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

		builder.Configuration.AddJsonFile(filePath, optional: false, reloadOnChange: true);
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
	// Replace the dictionary reference atomically (do not mutate in-place).
	labSettings.Labs = validLabNames.ToDictionary(
		labName => labName,
		labName => configuration.GetSection(labName).Get<LabCsvConfig>() ?? new LabCsvConfig(),
		StringComparer.OrdinalIgnoreCase);
}

RebuildLabSettings();

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
<<<<<<< HEAD

// ── Data Protection ─────────────────────────────────────────────────────────
// Keys must be persisted to disk so that:
//   a) auth cookies + anti-forgery tokens remain valid across IIS app-pool recycles, and
//   b) multiple IIS worker processes share the same key ring.
// Without this, Chrome (which enforces anti-forgery token validation strictly) loops back
// to the login page after a valid credential submit whenever the key rotates between the
// GET (login page) and POST (form submit) requests. Edge masks the problem by being more
// lenient about cookie/session state on failed decryption.
var dpKeysPath = builder.Configuration["DataProtection:KeysPath"];
var dpKeysDir  = new DirectoryInfo(
    string.IsNullOrWhiteSpace(dpKeysPath)
        ? Path.Combine(AppContext.BaseDirectory, "DataProtectionKeys")
        : dpKeysPath);

try { dpKeysDir.Create(); }
catch (Exception ex) { Console.Error.WriteLine($"[DataProtection] Could not create keys directory '{dpKeysDir.FullName}': {ex.Message}"); }

builder.Services
    .AddDataProtection()
    .PersistKeysToFileSystem(dpKeysDir)
    .SetApplicationName("LRNMetricsDashboard");

// ── Anti-forgery ─────────────────────────────────────────────────────────────
// Explicit configuration ensures Chrome receives the anti-forgery cookie correctly
// under both HTTP (dev) and HTTPS (production IIS) without the browser blocking it.
builder.Services.AddAntiforgery(options =>
{
    options.Cookie.Name         = "LRN.Antiforgery";
    options.Cookie.SameSite     = SameSiteMode.Lax;
    options.Cookie.SecurePolicy = builder.Environment.IsDevelopment()
        ? CookieSecurePolicy.SameAsRequest
        : CookieSecurePolicy.Always;
    options.Cookie.HttpOnly     = true;
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
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});
=======
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5

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
builder.Services.AddScoped<ICodingValidationRepository, SqlCodingValidationRepository>();
builder.Services.AddScoped<IClinicSummaryRepository, SqlClinicSummaryRepository>();
builder.Services.AddScoped<ISalesRepSummaryRepository, SqlSalesRepSummaryRepository>();
builder.Services.AddScoped<IDashboardRepository, SqlDashboardRepository>();
builder.Services.AddScoped<IProductionReportRepository, SqlProductionReportRepository>();
builder.Services.AddScoped<INorthWestProductionSummaryRepository, SqlNorthWestProductionSummaryRepository>();
builder.Services.AddScoped<IAugustusProductionSummaryRepository, SqlAugustusProductionSummaryRepository>();

// ── Per-lab generic production summary repositories (Certus, Cove, Elixir, PCRLabsofAmerica, Beech_Tree, Rising_Tides) ──
// One SqlLabProductionSummaryRepository per lab, keyed by the lab name used in the LabSettings config.
builder.Services.AddSingleton<IReadOnlyDictionary<string, ILabProductionSummaryRepository>>(sp =>
{
    var logger = sp.GetRequiredService<ILogger<SqlLabProductionSummaryRepository>>();
    return new Dictionary<string, ILabProductionSummaryRepository>(StringComparer.OrdinalIgnoreCase)
    {
        ["Certus"]           = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Certus),
        ["Cove"]             = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Cove),
        ["Elixir"]           = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Elixir),
        ["PCRLabsofAmerica"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.PCRLabsofAmerica),
        ["Beech_Tree"]       = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.BeechTree),
        ["Rising_Tides"]     = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.RisingTides),
    };
});
builder.Services.AddScoped<IClaimLineRepository, SqlClaimLineRepository>();
builder.Services.AddScoped<ICollectionSummaryRepository, SqlCollectionSummaryRepository>();
builder.Services.AddScoped<ILisSummaryRepository, SqlLisSummaryRepository>();

// User management repository (uses DefaultConnection from appsettings.json)
builder.Services.AddScoped<IUserManagementRepository, SqlUserManagementRepository>();
// Password hasher
builder.Services.AddSingleton<IPasswordHasher, PasswordHasher>();

// User management repository (uses DefaultConnection from appsettings.json)
builder.Services.AddScoped<IUserManagementRepository, SqlUserManagementRepository>();
// Password hasher
builder.Services.AddSingleton<IPasswordHasher, PasswordHasher>();

// Add services to the container.
builder.Services.AddMemoryCache();
builder.Services.AddScoped<IAppUsageAuditService, SqlAppUsageAuditService>();
builder.Services.AddScoped<AppUsageAuditFilter>();

// In-app Help Bot (singleton - loads topic file once at startup)
builder.Services.AddSingleton<HelpBotService>();

builder.Services.AddControllersWithViews(options =>
{
	options.Filters.AddService<AppUsageAuditFilter>();
    // Require authenticated user for every action by default.
    // Use [AllowAnonymous] on Account/Login etc.
    var policy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
    options.Filters.Add(new AuthorizeFilter(policy));
});

// ── Cookie authentication ─────────────────────────────────────────
builder.Services
    .AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath        = "/Account/Login";
        options.LogoutPath       = "/Account/Logout";
        options.AccessDeniedPath = "/Account/AccessDenied";
        options.ExpireTimeSpan   = TimeSpan.FromHours(8);
        options.SlidingExpiration = true;
<<<<<<< HEAD
        options.Cookie.Name         = "LRN.Auth";
        options.Cookie.HttpOnly     = true;
        options.Cookie.SameSite     = SameSiteMode.Lax;
        // Always mark the auth cookie as Secure in production so Chrome accepts it after
        // the HTTPS redirect that follows a successful login.
        // SameAsRequest is kept for local development (HTTP) so the dev experience is unaffected.
        options.Cookie.SecurePolicy = builder.Environment.IsDevelopment()
            ? CookieSecurePolicy.SameAsRequest
            : CookieSecurePolicy.Always;

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
                    && !returnUrl.Contains("/Home/Error",     StringComparison.OrdinalIgnoreCase)
                    && !returnUrl.Contains("/Account/Login",  StringComparison.OrdinalIgnoreCase)
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
        };
=======
        options.Cookie.Name      = "LRN.Auth";
        options.Cookie.HttpOnly  = true;
        options.Cookie.SameSite  = SameSiteMode.Lax;
>>>>>>> 94cd7d605ea1571223aada4e985df6dfd6b2b3b5
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
            .Where(k => k.StartsWith("LRN.",         StringComparison.OrdinalIgnoreCase)
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
            var path     = context.Request.Path.HasValue     ? context.Request.Path.Value     : "/";
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

// HTTPS redirection: only useful when running standalone (Visual Studio / Kestrel).
// In IIS, HTTPS is already enforced at the IIS binding / URL Rewrite level, and
// HttpsRedirectionMiddleware logs "Failed to determine the https port" because it
// cannot infer the port behind the reverse proxy. Disable it for production.
if (app.Environment.IsDevelopment())
{
    app.UseHttpsRedirection();
}
app.UseStaticFiles();
app.UseRouting();

app.UseAuthentication();
app.UseAuthorization();

app.MapStaticAssets();

app.MapControllerRoute(
	name: "default",
	pattern: "{controller=Home}/{action=Index}/{id?}")
	.WithStaticAssets();

// Map attribute-routed controllers (e.g. HelpBotController -> /api/helpbot/*)
app.MapControllers();

app.Run();