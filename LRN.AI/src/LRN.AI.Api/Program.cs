using LRN.AI.Api.Extensions;
using LRN.AI.Api.Middleware;
using LRN.AI.Api.Security;
using LRN.AI.Application;
using LRN.AI.Application.ModelComparison;
using LRN.AI.Infrastructure;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;

var builder = WebApplication.CreateBuilder(args);

// Per-machine secrets (gitignored), then environment variables again so AI__* / DenialWorkflowAuth__* overrides
// still win over the local file. Production secrets come from Key Vault in the Azure phase.
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: true);
builder.Configuration.AddEnvironmentVariables();

var maxRequestBodyBytes = builder.Configuration.GetValue<long?>($"{AiSecurityOptions.SectionName}:MaxRequestBodyBytes") ?? 128 * 1024;
builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.AddServerHeader = false;
    kestrel.Limits.MaxRequestBodySize = maxRequestBodyBytes;
});

builder.Services.AddOptions<ComparisonOptions>()
    .Bind(builder.Configuration.GetSection(ComparisonOptions.SectionName))
    .ValidateOnStart();
builder.Services.AddLrnAiApplication();
builder.Services.AddLrnAiInfrastructure(builder.Configuration);
builder.Services.AddLrnAiSecurity(builder.Configuration, builder.Environment);

builder.Services.AddControllers();
builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<AiExceptionHandler>();
builder.Services.AddHealthChecks()
    .AddCheck<OllamaHealthCheck>("ollama", tags: [OllamaHealthCheck.Tag]);

if (builder.Environment.IsDevelopment())
{
    builder.Services.AddEndpointsApiExplorer();
    builder.Services.AddSwaggerGen();
}

var app = builder.Build();

app.UseExceptionHandler();
if (!app.Environment.IsDevelopment())
{
    // HIPAA transmission security: TLS only outside local development.
    app.UseHsts();
    app.UseHttpsRedirection();
}
app.UseMiddleware<SecurityHeadersMiddleware>();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();
app.UseRateLimiter();

app.MapControllers();

// /health is API liveness only; /health/ollama reports the model provider. Neither returns model names or details.
app.MapHealthChecks("/health", new HealthCheckOptions { Predicate = _ => false }).AllowAnonymous();
app.MapHealthChecks("/health/ollama", new HealthCheckOptions { Predicate = check => check.Tags.Contains(OllamaHealthCheck.Tag) }).AllowAnonymous();

app.Run();

public partial class Program;
