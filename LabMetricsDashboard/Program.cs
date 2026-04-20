using LabMetricsDashboard.Filters;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;

var builder = WebApplication.CreateBuilder(args);

// ── File logging ─────────────────────────────────────────────────
// Writes Warning+ logs (DB errors, crashes) to rolling daily text files.
var fileLogSection = builder.Configuration.GetSection("Logging:File");
var fileLogOptions = new FileLoggerOptions
{
    LogDirectory = fileLogSection["LogDirectory"] ?? "Logs",
    MinLevel     = Enum.TryParse<LogLevel>(fileLogSection["LogLevel"], true, out var lvl) ? lvl : LogLevel.Warning,
    RetainDays   = int.TryParse(fileLogSection["RetainDays"], out var rd) ? rd : 30
};
builder.Logging.AddProvider(new FileLoggerProvider(fileLogOptions));

// Bind the "LabConfig" section from appsettings.json.
var labConfigOptions = builder.Configuration
    .GetSection(LabConfigOptions.Section)
    .Get<LabConfigOptions>() ?? new LabConfigOptions();

// Load each lab's dedicated JSON file from the shared config folder.
// Convention: {LabConfigFolder}{LabName}.json  e.g. Configs\PCRLabsofAmerica.json
foreach (var labName in labConfigOptions.Labs)
{
    var filePath = Path.Combine(labConfigOptions.LabConfigFolder, $"{labName}.json");
    builder.Configuration.AddJsonFile(filePath, optional: true, reloadOnChange: true);
}

// Re-read configuration after all lab files have been added.
var configuration = builder.Configuration;

// Build LabSettings: each lab file is expected to have a root section matching the lab name.
var labSettings = new LabSettings
{
    Labs = labConfigOptions.Labs.ToDictionary(
        labName => labName,
        labName => configuration.GetSection(labName).Get<LabCsvConfig>() ?? new LabCsvConfig(),
        StringComparer.OrdinalIgnoreCase)
};
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
builder.Services.AddScoped<ICodingSetupRepository, SqlCodingSetupRepository>();
builder.Services.AddSingleton<HelpBotService>();

// Add services to the container.
builder.Services.AddMemoryCache();
builder.Services.AddScoped<IAppUsageAuditService, SqlAppUsageAuditService>();
builder.Services.AddScoped<AppUsageAuditFilter>();
builder.Services.AddControllersWithViews(options =>
{
    options.Filters.AddService<AppUsageAuditFilter>();
});

var app = builder.Build();

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
}

// ── Global error logging (all environments) ─────────────────────
// Logs unhandled exceptions with full detail to the text file so
// deployed-server errors are always captured.
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

        throw; // re-throw so the standard exception handler page still works
    }
});

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();

app.UseAuthorization();

app.MapStaticAssets();

app.MapControllers();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}")
    .WithStaticAssets();

app.Run();
