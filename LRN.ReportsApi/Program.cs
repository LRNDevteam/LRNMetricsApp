using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using LRN.ReportsApi.Security;
using System.Security.Claims;
using System.IO.Compression;
using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

var apiFileLogSection = builder.Configuration.GetSection("Logging:File");
try
{
    builder.Logging.AddProvider(new FileLoggerProvider(new FileLoggerOptions
    {
        LogDirectory = apiFileLogSection["LogDirectory"] ?? "Logs/Api",
        MinLevel = Enum.TryParse<LogLevel>(apiFileLogSection["LogLevel"], true, out var apiLogLevel) ? apiLogLevel : LogLevel.Information,
        RetainDays = int.TryParse(apiFileLogSection["RetainDays"], out var apiRetainDays) ? apiRetainDays : 30
    }));
}
catch (Exception ex)
{
    Console.Error.WriteLine($"API file logger initialization failed: {ex}");
}

builder.Services.Configure<DenialWorkflowOptions>(builder.Configuration.GetSection("Workflow"));
builder.Services.Configure<DenialWorkflowSupportOptions>(builder.Configuration.GetSection("DenialWorkflowSupport"));
builder.Services.Configure<DenialCodeMasterExportOptions>(builder.Configuration.GetSection("DenialCodeMasterExport"));
builder.Services.AddScoped<IDenialWorkflowRepository, SqlDenialWorkflowRepository>();
builder.Services.AddScoped<IDenialWorkflowService, DenialWorkflowService>();
builder.Services.AddScoped<IDenialCodeMasterRepository, SqlDenialCodeMasterRepository>();
builder.Services.AddScoped<IDenialCodeMasterExcelService, DenialCodeMasterExcelService>();
builder.Services.AddScoped<IDenialActionChangeVerificationRepository, SqlDenialActionChangeVerificationRepository>();
builder.Services.AddScoped<IDenialMapperRepository, SqlDenialMapperRepository>();
builder.Services.AddScoped<IMasterValuesRepository, SqlMasterValuesRepository>();
builder.Services.AddScoped<IDenialWorkflowIssueNotifier, DenialWorkflowIssueNotifier>();
builder.Services.AddScoped<IDenialWorkflowSupportService, DenialWorkflowSupportService>();
builder.Services.AddSingleton<IDenialWorkflowExportJobService, DenialWorkflowExportJobService>();
builder.Services.AddHttpClient();
builder.Services.AddAuthorization();
builder.Services.AddControllers();
builder.Services.AddResponseCompression(options =>
{
    options.EnableForHttps = true;
    options.Providers.Add<GzipCompressionProvider>();
});
builder.Services.Configure<GzipCompressionProviderOptions>(options =>
{
    options.Level = CompressionLevel.Fastest;
});
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddCors(options =>
{
    options.AddPolicy("MetricsWeb", policy => policy
        .WithOrigins(
            "https://www.lrnanalytics.com",
            "https://lrnanalytics.com",
            "http://localhost:5173",
            "https://localhost:5173",
            "http://localhost:5174",
            "https://localhost:5174",
            "http://localhost:3000",
            "https://localhost:3000")
        .AllowAnyHeader()
        .AllowAnyMethod()
        .AllowCredentials());
});

var app = builder.Build();
app.Use(async (context, next) =>
{
    ApplySecurityHeaders(context, app.Environment.IsDevelopment());
    await next();
});

if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}

app.UseResponseCompression();
app.UseCors("MetricsWeb");
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

// Auth is required only for Denial Workflow API endpoints.
// Do not block React static files, fonts, swagger, health, favicon, etc.
app.Use(async (context, next) =>
{
    var path = context.Request.Path;
    var isWorkflowApi = path.StartsWithSegments("/api/denialworkflow")
        || path.StartsWithSegments("/api/denial-workflow")
        || path.StartsWithSegments("/api/master-values");

    if (!isWorkflowApi
        || path.StartsWithSegments("/api/denialworkflow/health")
        || path.StartsWithSegments("/api/denial-workflow/health"))
    {
        await next();
        return;
    }

    var configuration = context.RequestServices.GetRequiredService<IConfiguration>();

    if (!WorkflowJwt.TryValidate(context.Request, configuration, out var principal, out var authFailureReason))
    {
        var importKey = configuration["DenialWorkflowAuth:ImportApiKey"] ?? string.Empty;
        var suppliedImportKey = context.Request.Headers["X-LRN-Workflow-Key"].ToString();
        var isImportEndpoint = path.StartsWithSegments("/api/denialworkflow/import")
            || path.StartsWithSegments("/api/denial-workflow/import");

        if (isImportEndpoint && !string.IsNullOrWhiteSpace(importKey) && string.Equals(importKey, suppliedImportKey, StringComparison.Ordinal))
        {
            var identity = new ClaimsIdentity(new[]
            {
                new Claim(ClaimTypes.Name, "DenialWorker"),
                new Claim(ClaimTypes.Role, "Admin")
            }, "LRNWorkflowImportKey");
            principal = new ClaimsPrincipal(identity);
        }
        else
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new
            {
                message = "Unauthorized. Login through LRN Metrics and open the workflow again.", reason = authFailureReason
            });
            return;
        }
    }

    try
    {
        context.User = principal;
        await next();
    }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
    {
        // The caller disconnected or deliberately superseded the request. This is not an
        // application incident and must not generate an error file or Teams notification.
        return;
    }
    catch (SqlException ex) when (
        context.RequestAborted.IsCancellationRequested &&
        ex.Message.Contains("Operation cancelled by user", StringComparison.OrdinalIgnoreCase))
    {
        // SqlClient can report cancellation of ExecuteReaderAsync as a SqlException instead
        // of OperationCanceledException after it has sent ATTENTION to SQL Server. React
        // intentionally aborts stale workflow loads, so this is also a normal disconnect.
        return;
    }
    catch (UnauthorizedAccessException ex)
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        await context.Response.WriteAsJsonAsync(new { message = ex.Message });
    }
    catch (InvalidOperationException ex) when (ex.Message.Contains("LabId", StringComparison.OrdinalIgnoreCase))
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        await context.Response.WriteAsJsonAsync(new { message = ex.Message });
    }
    catch (Exception ex)
    {
        var notifier = context.RequestServices.GetRequiredService<IDenialWorkflowIssueNotifier>();
        var report = await notifier.ReportAsync(context, ex, $"{context.Request.Method} {context.Request.Path}", CancellationToken.None);
        var support = context.RequestServices.GetRequiredService<IConfiguration>()
            .GetSection("DenialWorkflowSupport:AdminEmails")
            .Get<string[]>() ?? Array.Empty<string>();

        context.Response.StatusCode = StatusCodes.Status500InternalServerError;
        context.Response.Headers["X-Correlation-ID"] = report.CorrelationId;
        await context.Response.WriteAsJsonAsync(new
        {
            message = "Issue happened. Please contact admin support.",
            correlationId = report.CorrelationId,
            supportEmails = support
        });
    }
});

app.UseAuthorization();
app.MapGet("/", () => Results.Ok("LRN.ReportsApi running"));
app.MapGet("/health", () => Results.Ok("LRN.ReportsApi running"));
app.MapControllers();
app.Run();

static void ApplySecurityHeaders(HttpContext context, bool isDevelopment)
{
    var headers = context.Response.Headers;
    headers["X-Content-Type-Options"] = "nosniff";
    headers["X-Frame-Options"] = "DENY";
    headers["Referrer-Policy"] = "no-referrer";
    headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=()";
    headers["Content-Security-Policy"] = isDevelopment
        ? "default-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self' http://localhost:* https://localhost:* ws://localhost:* wss://localhost:* http://127.0.0.1:* https://127.0.0.1:* ws://127.0.0.1:* wss://127.0.0.1:*"
        : "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

    if (context.Request.IsHttps)
    {
        headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains";
    }
}
