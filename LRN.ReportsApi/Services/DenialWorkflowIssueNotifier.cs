using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public sealed class DenialWorkflowSupportOptions
{
    public string TeamsWebhookUrl { get; set; } = string.Empty;
    public string IssueLogFolder { get; set; } = "Logs/DenialWorkflowIssues";
    public List<string> AdminEmails { get; set; } = new();
    public string SmtpHost { get; set; } = string.Empty;
    public int SmtpPort { get; set; } = 587;
    public bool SmtpEnableSsl { get; set; } = true;
    public string SmtpUserName { get; set; } = string.Empty;
    public string SmtpPassword { get; set; } = string.Empty;
    public string SmtpFromEmail { get; set; } = string.Empty;
    public bool EnableSmtpEmail { get; set; }
}

public sealed record DenialWorkflowIssueReport(string CorrelationId, string? ErrorFilePath);

public interface IDenialWorkflowIssueNotifier
{
    Task<DenialWorkflowIssueReport> ReportAsync(HttpContext context, Exception exception, string action, CancellationToken ct = default);
}

public sealed class DenialWorkflowIssueNotifier : IDenialWorkflowIssueNotifier
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IOptions<DenialWorkflowSupportOptions> _options;
    private readonly IWebHostEnvironment _environment;
    private readonly ILogger<DenialWorkflowIssueNotifier> _logger;

    public DenialWorkflowIssueNotifier(
        IHttpClientFactory httpClientFactory,
        IOptions<DenialWorkflowSupportOptions> options,
        IWebHostEnvironment environment,
        ILogger<DenialWorkflowIssueNotifier> logger)
    {
        _httpClientFactory = httpClientFactory;
        _options = options;
        _environment = environment;
        _logger = logger;
    }

    // Throttle for the transient-infra path — static because the notifier is scoped (new per request).
    private static long _lastTransientLogTicks;
    private static readonly TimeSpan TransientLogThrottle = TimeSpan.FromSeconds(60);

    // A SQL connectivity/transient outage (server unreachable, connect/pool timeout, Azure SQL
    // throttling) is an infrastructure event, not a per-request application defect. Writing one
    // issue file + firing one (frequently dead) Teams webhook per failed request turns a single
    // outage into thousands of files and futile HTTP POSTs (observed 2026-07-22).
    private static bool IsTransientInfra(Exception ex) =>
        ex is Microsoft.Data.SqlClient.SqlException { Number: 53 or 40 or -2 or 258 or 10053 or 10054 or 10060 or 4060 or 40197 or 40501 or 40613 or 49918 or 49919 or 49920 or 233 or 64 }
        || (ex is InvalidOperationException && ex.Message.Contains("from the pool", StringComparison.OrdinalIgnoreCase));

    public async Task<DenialWorkflowIssueReport> ReportAsync(HttpContext context, Exception exception, string action, CancellationToken ct = default)
    {
        var correlationId = GetCorrelationId(context);

        if (IsTransientInfra(exception))
        {
            // Log a single throttled warning; skip the per-request file + webhook.
            var nowTicks = DateTime.UtcNow.Ticks;
            var last = Interlocked.Read(ref _lastTransientLogTicks);
            if (nowTicks - last > TransientLogThrottle.Ticks
                && Interlocked.CompareExchange(ref _lastTransientLogTicks, nowTicks, last) == last)
            {
                _logger.LogWarning(exception,
                    "Denial workflow database connectivity issue (per-request issue files + Teams alerts suppressed for {ThrottleSeconds}s). Action: {Action}.",
                    (int)TransientLogThrottle.TotalSeconds, action);
            }
            await Task.CompletedTask;
            return new DenialWorkflowIssueReport(correlationId, null);
        }

        var userName = FirstClaim(context, ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn", ClaimTypes.Email, "email");
        var role = FirstClaim(context, ClaimTypes.Role, "role", "roles");
        var page = $"{context.Request.Method} {context.Request.Path}{SanitizeQueryString(context.Request.QueryString.Value)}";
        var errorFilePath = await SaveIssueTextFileAsync(correlationId, page, userName, role, action, exception, ct);

        _logger.LogError(exception,
            "Denial workflow issue {CorrelationId}. Page: {Page}. User: {User}. Action: {Action}. Error file: {ErrorFilePath}",
            correlationId,
            page,
            userName,
            action,
            errorFilePath);

        await SendTeamsAlertAsync(correlationId, page, userName, role, action, errorFilePath, exception, ct);
        return new DenialWorkflowIssueReport(correlationId, errorFilePath);
    }

    private static string SanitizeQueryString(string? query)
    {
        if (string.IsNullOrWhiteSpace(query)) return string.Empty;
        return Regex.Replace(
            query,
            @"(?i)(?<=[?&])([^=&]*(?:token|key|password|secret|authorization)[^=&]*)=[^&]*",
            "$1=[REDACTED]",
            RegexOptions.CultureInvariant);
    }

    private async Task<string?> SaveIssueTextFileAsync(string correlationId, string page, string userName, string role, string action, Exception exception, CancellationToken ct)
    {
        try
        {
            var configuredFolder = _options.Value.IssueLogFolder;
            var folder = Path.IsPathRooted(configuredFolder)
                ? configuredFolder
                : Path.Combine(_environment.ContentRootPath, configuredFolder);
            Directory.CreateDirectory(folder);

            var filePath = Path.Combine(folder, $"denial-workflow-issue-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{SafeFileName(correlationId)}.txt");
            var body = new StringBuilder()
                .AppendLine("LRN Denial Workflow Issue")
                .AppendLine($"Severity: IMPORTANT - IMMEDIATE ACTION REQUIRED")
                .AppendLine($"CorrelationId: {correlationId}")
                .AppendLine($"UtcTime: {DateTime.UtcNow:O}")
                .AppendLine($"Page: {page}")
                .AppendLine($"User: {userName}")
                .AppendLine($"Role: {role}")
                .AppendLine($"Action: {action}")
                .AppendLine()
                .AppendLine("Exception:")
                .AppendLine(exception.ToString())
                .ToString();

            await File.WriteAllTextAsync(filePath, body, Encoding.UTF8, ct);
            return filePath;
        }
        catch (Exception fileEx)
        {
            _logger.LogError(fileEx, "Unable to save denial workflow issue text file for {CorrelationId}.", correlationId);
            return null;
        }
    }

    private async Task SendTeamsAlertAsync(string correlationId, string page, string userName, string role, string action, string? errorFilePath, Exception exception, CancellationToken ct)
    {
        var webhookUrl = _options.Value.TeamsWebhookUrl;
        if (string.IsNullOrWhiteSpace(webhookUrl)) return;

        try
        {
            var payload = new Dictionary<string, object?>
            {
                ["@type"] = "MessageCard",
                ["@context"] = "https://schema.org/extensions",
                ["themeColor"] = "FF0000",
                ["summary"] = "IMPORTANT: Denial Workflow issue needs immediate action",
                ["title"] = "IMPORTANT - IMMEDIATE ACTION REQUIRED: Denial Workflow Issue",
                ["text"] = "**A denial workflow issue happened. Immediate admin support action required.**",
                ["sections"] = new[]
                {
                    new
                    {
                        activityTitle = "Issue Context",
                        facts = new[]
                        {
                            new { name = "Correlation ID", value = correlationId },
                            new { name = "Page", value = page },
                            new { name = "User", value = string.IsNullOrWhiteSpace(userName) ? "Unknown" : userName },
                            new { name = "Role", value = string.IsNullOrWhiteSpace(role) ? "Unknown" : role },
                            new { name = "Action", value = action },
                            new { name = "Error File", value = errorFilePath ?? "Unable to save issue text file" },
                            new { name = "Exception", value = exception.GetType().FullName ?? "Exception" },
                            new { name = "Message", value = Truncate(exception.Message, 800) }
                        },
                        markdown = true
                    }
                }
            };

            using var response = await _httpClientFactory.CreateClient().PostAsJsonAsync(webhookUrl, payload, cancellationToken: ct);
            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Teams webhook returned {StatusCode} for denial workflow issue {CorrelationId}.", response.StatusCode, correlationId);
            }
        }
        catch (Exception teamsEx)
        {
            _logger.LogError(teamsEx, "Unable to send Teams alert for denial workflow issue {CorrelationId}.", correlationId);
        }
    }

    private static string GetCorrelationId(HttpContext context)
    {
        var existing = context.TraceIdentifier;
        if (!string.IsNullOrWhiteSpace(existing)) return existing;
        return Guid.NewGuid().ToString("N");
    }

    private static string FirstClaim(HttpContext context, params string[] names)
    {
        foreach (var name in names)
        {
            var value = context.User.Claims.FirstOrDefault(c => string.Equals(c.Type, name, StringComparison.OrdinalIgnoreCase))?.Value;
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }
        return string.Empty;
    }

    private static string SafeFileName(string value)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) value = value.Replace(c, '_');
        return value;
    }

    private static string Truncate(string value, int maxLength)
        => string.IsNullOrEmpty(value) || value.Length <= maxLength ? value : value[..maxLength] + "...";
}
