using System.Text;
using System.Threading.RateLimiting;
using Azure;
using Azure.AI.Agents.Persistent;
using Azure.Identity;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

// ---------------------------------------------------------------------
// Azure Key Vault
// The three secrets this app needs — Foundry--ProjectEndpoint, Foundry--AgentId and
// ChatToken--SigningKey — live in kv-lrnmetrics-prod, the same vault LabMetricsDashboard
// already uses. Keeping them in one vault is what stops ChatToken:SigningKey from drifting
// between the two apps: a mismatch there rejects every /api/ask call with a 401.
//
// Vault secret names use "--" wherever configuration uses ":" — ChatToken--SigningKey binds
// to ChatToken:SigningKey. That is AddAzureKeyVault's own convention, so no custom
// KeyVaultSecretManager is needed.
//
// Registered last, so the vault WINS over App Service application settings wherever both
// define a key — same precedence LabMetricsDashboard uses. That is deliberate: a stale
// Foundry__AgentId or placeholder ChatToken__SigningKey left behind on the App Service can no
// longer silently shadow the vault. An empty or absent KeyVault:Uri skips this entirely and
// falls back to appsettings/environment values, so local runs need no vault access.
// ---------------------------------------------------------------------
ApplyKeyVault(builder.Configuration, builder.Configuration["KeyVault:Uri"]);

// ---------------------------------------------------------------------
// Configuration
// Values come from Key Vault above, or from App Service > Configuration > Application
// settings (double underscores for nested keys, e.g. Foundry__ProjectEndpoint).
// Never commit real values to source control.
// ---------------------------------------------------------------------
var allowedOriginConfig = builder.Configuration["AllowedOrigin"]
    ?? throw new InvalidOperationException("AllowedOrigin is not configured.");
var projectEndpoint = builder.Configuration["Foundry:ProjectEndpoint"]
    ?? throw new InvalidOperationException("Foundry:ProjectEndpoint is not configured.");
var agentId = builder.Configuration["Foundry:AgentId"]
    ?? throw new InvalidOperationException("Foundry:AgentId is not configured.");

// Foundry requires the assistant id, which always begins with "asst". The agent's page in
// ai.azure.com also shows GUIDs for other things, and pasting one of those is accepted by every
// check above — the mistake only surfaces on the first real question, as a 400 buried inside a
// generic 500. Startup is where a bad value should be caught, not the first user's question.
if (!agentId.StartsWith("asst", StringComparison.OrdinalIgnoreCase))
{
    throw new InvalidOperationException(
        $"Foundry:AgentId is '{agentId}', which is not an assistant id — Foundry expects a value " +
        "beginning with 'asst'. Copy the Agent ID from ai.azure.com > your project > Agents > " +
        "ReimbursementAnalyst. If it is held in Key Vault as Foundry--AgentId, add a new version " +
        "there and restart this app: vault secrets are read only at startup.");
}

// The chat token is a short-lived ticket your EXISTING web app issues to a
// signed-in user; this API checks it before answering any question. The
// SigningKey value must be the exact same string here and in the existing
// web app's configuration — it is how the two apps trust each other.
var chatTokenKey = builder.Configuration["ChatToken:SigningKey"]
    ?? throw new InvalidOperationException("ChatToken:SigningKey is not configured.");
var chatTokenIssuer = builder.Configuration["ChatToken:Issuer"] ?? "ReimbursementWebApp";
var chatTokenAudience = builder.Configuration["ChatToken:Audience"] ?? "ReimbursementAgentProxy";

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = chatTokenIssuer,
            ValidateAudience = true,
            ValidAudience = chatTokenAudience,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(chatTokenKey)),
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(30)
        };
    });

builder.Services.AddAuthorization();

// Supports a comma-separated list if you ever need more than one calling origin
// (e.g. a staging site alongside production).
var allowedOrigins = allowedOriginConfig.Split(
    ',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

// CORS: only requests from the existing web app's origin(s) are accepted.
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowExistingSite", policy =>
        policy.WithOrigins(allowedOrigins)
              .AllowAnyHeader()
              .WithMethods("POST", "GET"));
});

// Basic rate limiting so a burst of requests can't drive up model costs —
// 10 questions per minute per caller IP. Tune PermitLimit/Window as needed.
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.AddPolicy("PerIp", httpContext =>
        RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            factory: _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 10,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0
            }));
});

var app = builder.Build();

// DefaultAzureCredential resolves to this App Service's managed identity in
// production, and to your `az login` session when running locally.
var agentsClient = new PersistentAgentsClient(projectEndpoint, new DefaultAzureCredential());

app.UseCors("AllowExistingSite");
app.UseAuthentication();
app.UseAuthorization();
app.UseRateLimiter();

app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.MapPost("/api/ask", async (AskRequest request, ILogger<Program> logger) =>
{
    if (string.IsNullOrWhiteSpace(request.Question))
    {
        return Results.BadRequest(new { error = "A question is required." });
    }

    try
    {
        PersistentAgentThread thread = await agentsClient.Threads.CreateThreadAsync();

        await agentsClient.Messages.CreateMessageAsync(
            thread.Id, MessageRole.User, request.Question);

        ThreadRun run = await agentsClient.Runs.CreateRunAsync(thread.Id, agentId);

        // Poll until the agent finishes reasoning and, if needed, calling its tool.
        while (run.Status == RunStatus.Queued || run.Status == RunStatus.InProgress)
        {
            await Task.Delay(500);
            run = await agentsClient.Runs.GetRunAsync(thread.Id, run.Id);
        }

        if (run.Status != RunStatus.Completed)
        {
            logger.LogWarning(
                "Agent run for thread {ThreadId} ended with status {Status}: {Error}",
                thread.Id, run.Status, run.LastError?.Message);
            return Results.Problem("The reimbursement agent could not complete this request.");
        }

        var allMessages = new List<PersistentThreadMessage>();
        await foreach (var message in agentsClient.Messages.GetMessagesAsync(thread.Id))
        {
            allMessages.Add(message);
        }

        var latestAgentMessage = allMessages
            .Where(m => m.Role == MessageRole.Agent)
            .OrderByDescending(m => m.CreatedAt)
            .FirstOrDefault();

        string? answer = null;
        if (latestAgentMessage is not null)
        {
            foreach (var content in latestAgentMessage.ContentItems)
            {
                if (content is MessageTextContent textContent)
                {
                    answer = textContent.Text;
                }
            }
        }

        return Results.Ok(new { answer = answer ?? "No response was returned." });
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Failed to reach the reimbursement agent.");

        // Name the failure in the response, not just in App Service's logs. Everything reaching
        // this catch looks identical from the caller's side — a managed identity with no Foundry
        // role, a mistyped project endpoint, and an agent id that does not exist all arrive here
        // as one opaque 500. The exception type plus the Azure status code separates them:
        // 401/403 is access, 404 is a wrong endpoint or agent id.
        //
        // Safe to include: /api/ask already requires a valid signed ticket, so only a signed-in
        // user of the web app can reach this at all, and the calling app logs this detail
        // server-side rather than showing it to the person who asked the question.
        var azureStatus = ex is RequestFailedException failed ? failed.Status : 0;
        var diagnosis = azureStatus is 401 or 403
            ? " This is an access failure: confirm the App Service's managed identity is enabled and "
              + "holds the Foundry User role on the Foundry project resource."
            : azureStatus == 404
                ? " Not found: confirm Foundry:ProjectEndpoint and Foundry:AgentId."
                : string.Empty;

        return Results.Problem(
            $"Unable to reach the reimbursement agent. {ex.GetType().Name}"
            + (azureStatus != 0 ? $" (Azure status {azureStatus})" : string.Empty)
            + $": {ex.Message}{diagnosis}");
    }
}).RequireAuthorization().RequireRateLimiting("PerIp");

app.Run();

/// <summary>
/// Layers Azure Key Vault over the configuration already loaded, when KeyVault:Uri names one.
/// Mirrors the same helper in LabMetricsDashboard so both apps behave identically.
/// </summary>
static void ApplyKeyVault(IConfigurationBuilder configuration, string? uri)
{
    var trimmed = uri?.Trim();
    if (string.IsNullOrEmpty(trimmed)) return;

    // Validated rather than handed straight to the SDK: a typo in the hand-maintained URI
    // ("https: //…") otherwise surfaces much later as a signing key that is simply missing.
    if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var vaultUri) || vaultUri.Scheme != Uri.UriSchemeHttps)
        throw new InvalidOperationException(
            $"KeyVault:Uri must be an absolute https URI, e.g. https://kv-lrnmetrics-prod.vault.azure.net/ — got '{trimmed}'.");

    try
    {
        // DefaultAzureCredential so one build authenticates everywhere it is deployed: this App
        // Service's system-assigned managed identity in Azure, and the developer's `az login`
        // session locally. It is the same credential already used to reach the Foundry agent.
        configuration.AddAzureKeyVault(vaultUri, new DefaultAzureCredential());
    }
    catch (Exception ex)
    {
        // Continuing would boot the app with no Foundry endpoint and no signing key — every
        // question would then fail deep inside the agent call, or be rejected as unauthorized,
        // naming anything but the vault that never loaded. Stop here, where the message can
        // name the real cause.
        throw new InvalidOperationException(
            $"Could not load secrets from Azure Key Vault '{vaultUri}'. The vault uses RBAC (not access " +
            $"policies), so the identity running this process needs the 'Key Vault Secrets User' role on it, " +
            $"and this host must be able to reach the vault.", ex);
    }
}

record AskRequest(string Question);
