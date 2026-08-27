using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using LRN.ReportsApi.Security;
using System.Security.Claims;
using System.IO.Compression;
using Azure.Identity;
using Microsoft.AspNetCore.ResponseCompression;
using Microsoft.Data.SqlClient;

// Utility mode: LRN.ReportsApi.exe --hash-secret <secret>
// Prints the ExternalApiClients:Clients[].SecretHash verifier for an external API client and
// exits. It runs the same ApiSecretHasher the token endpoint verifies with, so the generated
// value cannot drift from what the server accepts. See docs/external-api/ExternalApiAccess_Guide.md.
if (args.Length >= 1 && args[0].Equals("--hash-secret", StringComparison.OrdinalIgnoreCase))
{
    if (args.Length < 2 || string.IsNullOrWhiteSpace(args[1]))
    {
        Console.Error.WriteLine("Usage: LRN.ReportsApi --hash-secret <secret>");
        return 1;
    }
    Console.WriteLine(LRN.ReportsApi.Security.ApiSecretHasher.Hash(args[1]));
    return 0;
}

var builder = WebApplication.CreateBuilder(args);

// Secrets (connection strings, JWT signing key, import API key, webhook URLs) live in
// appsettings.Local.json, which is gitignored and machine/environment specific. The tracked
// appsettings*.json files must never contain credentials. Environment variables can also be
// used (e.g. ConnectionStrings__DefaultConnection).
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: true);

// ── Azure Key Vault ──────────────────────────────────────────────────────────────────────
// Production secrets live in kv-lrnmetrics-prod: every ConnectionStrings:* entry, the
// DenialWorkflowAuth:* block (JWT signing key, import API key, issuer/audience) and the
// ExternalApiClients client id and secret hash.
//
// Vault secret names use "--" wherever configuration uses ":" — ConnectionStrings--DefaultConnection
// binds to ConnectionStrings:DefaultConnection. That is AddAzureKeyVault's own convention, so
// nothing here needs a custom KeyVaultSecretManager. Indexed names work the same way, which is why
// ExternalApiClients--Clients--0--ClientId merges into the same Clients[0] entry that
// appsettings.json declares DisplayName and Roles on.
//
// Registered AFTER appsettings.Local.json so the vault wins wherever both define a key. A machine
// with no vault access blanks KeyVault:Uri in its appsettings.Local.json and keeps running on local
// secrets — an empty or absent URI skips this entirely.
if (ApplyKeyVault(builder.Configuration, builder.Configuration["KeyVault:Uri"]))
{
    RequireVaultSecrets(builder.Configuration,
        "ConnectionStrings:DefaultConnection",
        "DenialWorkflowAuth:JwtSigningKey");
}

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

builder.Services.Configure<ExternalApiClientOptions>(
    builder.Configuration.GetSection(ExternalApiClientOptions.Section));
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
builder.Services.AddScoped<IReportAuditLogService, ReportAuditLogService>();
builder.Services.AddScoped<IMenuRepository, SqlMenuRepository>();
builder.Services.AddScoped<ILabAnalyticsRepository, SqlLabAnalyticsRepository>();
builder.Services.AddScoped<ICptLookupRepository, SqlCptLookupRepository>();
builder.Services.AddMemoryCache();
builder.Services.AddScoped<IDenialDashboardRepository, SqlDenialDashboardRepository>();
builder.Services.AddScoped<IPayerMasterWorkflowService, PayerMasterWorkflowService>();
builder.Services.AddHostedService<PayerMasterSlaEscalationService>();

// ── Payer mapping intelligence (LRN.PayerPolicyMapper.Core) ──────────────────
// Same pipeline as the LRN.PayerPolicyMapper worker; the Step 0 index is a singleton
// snapshot that re-checks the rules version at most every 5 minutes.
builder.Services.AddSingleton(sp =>
    builder.Configuration.GetSection("PayerMatching").Get<LRN.PayerPolicyMapper.Core.MatchingOptions>()
    ?? new LRN.PayerPolicyMapper.Core.MatchingOptions());
builder.Services.AddSingleton<LRN.PayerPolicyMapper.Core.Abstractions.IReferenceDataRepository>(sp =>
    new LRN.PayerPolicyMapper.Core.Data.SqlReferenceDataRepository(
        builder.Configuration.GetConnectionString("DefaultConnection")
        ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.")));
builder.Services.AddSingleton<LRN.PayerPolicyMapper.Core.Abstractions.IPayerPolicyIndexProvider,
    LRN.PayerPolicyMapper.Core.CachedPayerPolicyIndexProvider>();
builder.Services.AddSingleton<LRN.PayerPolicyMapper.Core.Abstractions.ILabInsuranceRepository>(sp =>
    new LRN.PayerPolicyMapper.Core.Data.SqlLabInsuranceRepository(builder.Configuration.GetConnectionString("DefaultConnection")!));
builder.Services.AddSingleton<LRN.PayerPolicyMapper.Core.Abstractions.IAuditRepository>(sp =>
    new LRN.PayerPolicyMapper.Core.Data.SqlAuditRepository(builder.Configuration.GetConnectionString("DefaultConnection")!));
builder.Services.AddSingleton<LRN.PayerPolicyMapper.Core.Abstractions.IPayerMapperRunRepository>(sp =>
    new LRN.PayerPolicyMapper.Core.Data.SqlPayerMapperRunRepository(builder.Configuration.GetConnectionString("DefaultConnection")!));
builder.Services.AddSingleton<LRN.PayerPolicyMapper.Core.Abstractions.INotificationService>(sp =>
    new LRN.PayerPolicyMapper.Core.Data.PayerMasterNotificationService(
        builder.Configuration.GetConnectionString("DefaultConnection")!,
        sp.GetRequiredService<ILogger<LRN.PayerPolicyMapper.Core.Data.PayerMasterNotificationService>>()));
builder.Services.AddSingleton<LRN.PayerPolicyMapper.Core.MatchingPipeline>();
builder.Services.AddScoped<IPayerMappingService, PayerMappingService>();
builder.Services.AddScoped<IPayerRulesAdminService, PayerRulesAdminService>();
builder.Services.AddScoped<IDenialWorkflowIssueNotifier, DenialWorkflowIssueNotifier>();
builder.Services.AddScoped<IDenialWorkflowSupportService, DenialWorkflowSupportService>();
builder.Services.AddSingleton<IDenialWorkflowJobHistoryStore, DenialWorkflowJobHistoryStore>();
builder.Services.AddSingleton<IDenialWorkflowExportJobService, DenialWorkflowExportJobService>();
builder.Services.AddSingleton<IDenialMapperPushJobService, DenialMapperPushJobService>();
builder.Services.AddSingleton<IDenialWorkflowUploadJobService, DenialWorkflowUploadJobService>();
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
builder.Services.AddSwaggerGen(options =>
{
    // Schema ids default to the short type name, which collides when two types share a name
    // across namespaces (e.g. Models.AssignInsightRequest vs a controller-nested AssignInsightRequest),
    // making /swagger/v1/swagger.json fail with 500. Qualify ids with the namespace; keep the
    // readable "OfT" form for generics so refs stay valid.
    options.CustomSchemaIds(SwaggerSchemaId);
});

static string SwaggerSchemaId(Type type)
{
    if (!type.IsGenericType)
        return (type.FullName ?? type.Name).Replace('+', '.');
    var name = type.Name[..type.Name.IndexOf('`')];
    var args = string.Join("And", type.GetGenericArguments().Select(SwaggerSchemaId));
    return $"{type.Namespace}.{name}Of{args}".Replace('+', '.');
}
// Localhost origins are for local Vite/React debugging only. Allowing them in production
// with AllowCredentials would let any process listening on a user's localhost call the API
// with that user's credentials.
var corsOrigins = new List<string>
{
    "https://www.lrnanalytics.com",
    "https://lrnanalytics.com"
};
if (builder.Environment.IsDevelopment())
{
    corsOrigins.AddRange(new[]
    {
        "http://localhost:5173",
        "https://localhost:5173",
        "http://localhost:5174",
        "https://localhost:5174",
        "http://localhost:3000",
        "https://localhost:3000"
    });
}
builder.Services.AddCors(options =>
{
    options.AddPolicy("MetricsWeb", policy => policy
        .WithOrigins(corsOrigins.ToArray())
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
        || path.StartsWithSegments("/api/denial-dashboard")
        || path.StartsWithSegments("/api/master-values")
        || path.StartsWithSegments("/api/menu")
        || path.StartsWithSegments("/api/analytics")
        // Report Control Board landing page. Must be listed here: anything not matched below runs
        // with no authentication at all, and this endpoint exposes every lab's run status.
        || path.StartsWithSegments("/api/report-board");

    // client-logs exists to capture client-side errors, including ones caused by auth being
    // broken or expired. Requiring a valid JWT here creates a chicken-and-egg failure: exactly
    // when a user's session breaks (the case most worth reporting), the error report itself gets
    // rejected with 401, and the client silently retries reporting on every subsequent error.
    if (!isWorkflowApi
        || path.StartsWithSegments("/api/denialworkflow/health")
        || path.StartsWithSegments("/api/denial-workflow/health")
        || path.StartsWithSegments("/api/denial-dashboard/health")
        || path.StartsWithSegments("/api/denialworkflow/client-logs")
        || path.StartsWithSegments("/api/denial-workflow/client-logs"))
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
        // The two payer-mapper resolve APIs are deliberately public for external integrations
        // (no JWT). They run under a marked "public" identity with no roles - PayerMappingController
        // recognizes the LRNPublicResolve authentication type for exactly these two actions, so the
        // carve-out grants nothing else under /api/master-values.
        var isPublicResolveEndpoint = path.StartsWithSegments("/api/master-values/payer-mapper/resolve-lab-payer")
            || path.StartsWithSegments("/api/master-values/payer-mapper/resolve-payer-policy");

        // Constant-time comparison so response timing cannot be used to guess the key.
        var importKeyMatches = !string.IsNullOrWhiteSpace(importKey)
            && !string.IsNullOrEmpty(suppliedImportKey)
            && System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(
                System.Text.Encoding.UTF8.GetBytes(importKey),
                System.Text.Encoding.UTF8.GetBytes(suppliedImportKey));

        if (isImportEndpoint && importKeyMatches)
        {
            var identity = new ClaimsIdentity(new[]
            {
                new Claim(ClaimTypes.Name, "DenialWorker"),
                new Claim(ClaimTypes.Role, "Admin")
            }, "LRNWorkflowImportKey");
            principal = new ClaimsPrincipal(identity);
        }
        else if (isPublicResolveEndpoint)
        {
            var identity = new ClaimsIdentity(new[]
            {
                new Claim(ClaimTypes.Name, "PublicApiClient")
            }, "LRNPublicResolve");
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
return 0;

/// <summary>
/// Layers Azure Key Vault over the configuration already loaded, when KeyVault:Uri names one.
/// Returns true when a vault was actually added, so the caller can then check what it delivered.
/// </summary>
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
    }
    catch (Exception ex)
    {
        // Continuing would boot the app with no connection strings and no JWT signing key. It
        // would then answer every request with a failure raised deep inside a repository, naming
        // a missing connection string rather than the vault that never loaded. Stop here, where
        // the message can name the real cause.
        throw new InvalidOperationException(
            $"Could not load secrets from Azure Key Vault '{vaultUri}'. The vault uses RBAC (not access " +
            $"policies), so the identity running this process needs the 'Key Vault Secrets User' role on it, " +
            $"and this host must be able to reach the vault.", ex);
    }

    return true;
}

/// <summary>
/// Confirms the vault actually delivered the settings the app cannot run without.
///
/// A vault that authenticates but holds none of these is not a hypothetical: it is what a
/// deployment looks like when the identity and RBAC are in place but the secrets were never
/// created. Nothing fails at startup, so the app comes up clean and then throws
/// "DefaultConnection not configured" on the first request that touches a database - an error
/// that names the symptom and hides the cause. Checking here lets the message name the secret
/// that is missing, at the moment the app would otherwise have carried on.
/// </summary>
static void RequireVaultSecrets(IConfiguration configuration, params string[] requiredKeys)
{
    var missing = requiredKeys.Where(k => string.IsNullOrWhiteSpace(configuration[k])).ToArray();
    if (missing.Length == 0) return;

    // Config key -> the secret name to create, which is the only form that helps at 2am.
    var secretNames = string.Join(", ", missing.Select(k => k.Replace(":", "--")));
    throw new InvalidOperationException(
        $"Azure Key Vault was read successfully but is missing {missing.Length} required secret(s): {secretNames}. " +
        $"Create them in the vault (secret names use '--' where configuration uses ':'), or clear KeyVault:Uri to " +
        $"run from local settings instead. Values stored as vault TAGS are not secrets and are never loaded.");
}

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
