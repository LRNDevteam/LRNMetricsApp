using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;

var builder = WebApplication.CreateBuilder(args);

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

// Add services to the container.
builder.Services.AddMemoryCache();
builder.Services.AddControllersWithViews();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();

app.UseAuthorization();

app.MapStaticAssets();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}")
    .WithStaticAssets();

app.Run();
