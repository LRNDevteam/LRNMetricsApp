using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<DenialWorkflowOptions>(builder.Configuration.GetSection("Workflow"));
builder.Services.AddScoped<IDenialWorkflowRepository, SqlDenialWorkflowRepository>();
builder.Services.AddScoped<IDenialWorkflowService, DenialWorkflowService>();
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddCors(options =>
{
    options.AddPolicy("MetricsWeb", policy => policy.AllowAnyHeader().AllowAnyMethod().AllowAnyOrigin());
});

var app = builder.Build();
app.UseCors("MetricsWeb");
app.UseSwagger();
app.UseSwaggerUI();
app.MapGet("/", () => Results.Redirect("/swagger"));
app.MapGet("/health", () => Results.Ok("LRN.ReportsApi running"));
app.MapControllers();
app.Run();
