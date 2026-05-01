using LabMetricsDashboard.Filters;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
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

foreach (var labName in labConfigOptions.Labs ?? Enumerable.Empty<string>())
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
builder.Services.AddScoped<IClaimLineRepository, SqlClaimLineRepository>();
builder.Services.AddScoped<ICollectionSummaryRepository, SqlCollectionSummaryRepository>();
builder.Services.AddScoped<ILisSummaryRepository, SqlLisSummaryRepository>();

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
        options.Cookie.Name      = "LRN.Auth";
        options.Cookie.HttpOnly  = true;
        options.Cookie.SameSite  = SameSiteMode.Lax;
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

app.UseHttpsRedirection();
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