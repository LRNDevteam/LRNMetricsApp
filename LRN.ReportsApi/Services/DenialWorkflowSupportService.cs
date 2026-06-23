using System.Net;
using System.Net.Http.Json;
using System.Net.Mail;
using System.Security.Claims;
using System.Text;
using LRN.ReportsApi.Models;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public interface IDenialWorkflowSupportService
{
    Task<DenialWorkflowSupportRequestResult> SubmitAsync(HttpContext context, DenialWorkflowSupportRequest request, CancellationToken ct = default);
}

public sealed class DenialWorkflowSupportService : IDenialWorkflowSupportService
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IOptions<DenialWorkflowSupportOptions> _options;
    private readonly IWebHostEnvironment _environment;
    private readonly ILogger<DenialWorkflowSupportService> _logger;

    public DenialWorkflowSupportService(
        IHttpClientFactory httpClientFactory,
        IOptions<DenialWorkflowSupportOptions> options,
        IWebHostEnvironment environment,
        ILogger<DenialWorkflowSupportService> logger)
    {
        _httpClientFactory = httpClientFactory;
        _options = options;
        _environment = environment;
        _logger = logger;
    }

    public async Task<DenialWorkflowSupportRequestResult> SubmitAsync(HttpContext context, DenialWorkflowSupportRequest request, CancellationToken ct = default)
    {
        var supportEmails = CleanEmails(_options.Value.AdminEmails);
        if (supportEmails.Count == 0)
            throw new InvalidOperationException("DenialWorkflowSupport:AdminEmails is not configured.");

        var requestId = Guid.NewGuid().ToString("N");
        var userName = FirstClaim(context, ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn", ClaimTypes.Email, "email");
        var role = FirstClaim(context, ClaimTypes.Role, "role", "roles");
        var contactEmail = string.IsNullOrWhiteSpace(request.ContactEmail)
            ? FirstClaim(context, ClaimTypes.Email, "email")
            : request.ContactEmail.Trim();
        var page = string.IsNullOrWhiteSpace(request.Page) ? $"{context.Request.Method} {context.Request.Path}" : request.Page.Trim();
        var subject = string.IsNullOrWhiteSpace(request.Subject) ? "Denial Workflow support request" : request.Subject.Trim();
        var issueType = string.IsNullOrWhiteSpace(request.IssueType) ? "General" : request.IssueType.Trim();
        var priority = string.IsNullOrWhiteSpace(request.Priority) ? "Normal" : request.Priority.Trim();
        var message = request.Message.Trim();

        var body = BuildBody(requestId, userName, role, contactEmail, page, issueType, priority, subject, message);
        await SaveSupportRequestAsync(requestId, body, ct);

        var teamsSent = await SendTeamsMessageAsync(requestId, userName, role, contactEmail, page, issueType, priority, subject, message, ct);
        var emailSent = _options.Value.EnableSmtpEmail
            && await SendEmailAsync(supportEmails, contactEmail, subject, body, ct);

        return new DenialWorkflowSupportRequestResult
        {
            Success = true,
            EmailSent = emailSent,
            TeamsSent = teamsSent,
            RequestId = requestId,
            SupportEmails = supportEmails,
            Message = teamsSent
                ? "Support request sent to Teams successfully."
                : "Support request recorded. Teams webhook is not configured yet."
        };
    }

    private async Task SaveSupportRequestAsync(string requestId, string body, CancellationToken ct)
    {
        var configuredFolder = _options.Value.IssueLogFolder;
        var folder = Path.IsPathRooted(configuredFolder)
            ? configuredFolder
            : Path.Combine(_environment.ContentRootPath, configuredFolder);
        Directory.CreateDirectory(folder);

        var filePath = Path.Combine(folder, $"denial-workflow-support-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{requestId}.txt");
        await File.WriteAllTextAsync(filePath, body, Encoding.UTF8, ct);
    }

    private async Task<bool> SendEmailAsync(IReadOnlyList<string> supportEmails, string contactEmail, string subject, string body, CancellationToken ct)
    {
        var options = _options.Value;
        if (string.IsNullOrWhiteSpace(options.SmtpHost) || string.IsNullOrWhiteSpace(options.SmtpFromEmail))
            return false;

        using var message = new MailMessage
        {
            From = new MailAddress(options.SmtpFromEmail),
            Subject = $"Denial Workflow Support: {subject}",
            Body = body,
            IsBodyHtml = false
        };

        foreach (var email in supportEmails) message.To.Add(email);
        if (!string.IsNullOrWhiteSpace(contactEmail)) message.ReplyToList.Add(contactEmail);

        using var client = new SmtpClient(options.SmtpHost, options.SmtpPort)
        {
            EnableSsl = options.SmtpEnableSsl
        };

        if (!string.IsNullOrWhiteSpace(options.SmtpUserName))
            client.Credentials = new NetworkCredential(options.SmtpUserName, options.SmtpPassword);

        try
        {
            using var registration = ct.Register(client.SendAsyncCancel);
            await client.SendMailAsync(message, ct);
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unable to send denial workflow support email to {SupportEmails}.", string.Join(", ", supportEmails));
            return false;
        }
    }

    private async Task<bool> SendTeamsMessageAsync(
        string requestId,
        string userName,
        string role,
        string contactEmail,
        string page,
        string issueType,
        string priority,
        string subject,
        string message,
        CancellationToken ct)
    {
        var webhookUrl = _options.Value.TeamsWebhookUrl;
        if (string.IsNullOrWhiteSpace(webhookUrl)) return false;

        var isUrgent = priority.Contains("urgent", StringComparison.OrdinalIgnoreCase)
            || priority.Contains("high", StringComparison.OrdinalIgnoreCase);
        var nowUtc = DateTime.UtcNow;
        var nowLocal = DateTime.Now;
        var title = isUrgent ? "IMPORTANT - Denial Workflow Support Request" : "Denial Workflow Support Request";
        var summaryText = $"**{subject}**\n\n{Truncate(message, 1200)}";
        var payload = new Dictionary<string, object?>
        {
            ["@type"] = "MessageCard",
            ["@context"] = "https://schema.org/extensions",
            ["themeColor"] = isUrgent ? "FF0000" : "1ABC9C",
            ["summary"] = $"Denial Workflow support request: {subject}",
            ["title"] = title,
            ["text"] = isUrgent
                ? "**Immediate review requested.** A denial workflow user submitted a high-priority support request."
                : "A denial workflow user submitted a support request.",
            ["sections"] = new[]
            {
                new
                {
                    activityTitle = isUrgent ? "**X Error**" : "**Support Request**",
                    activitySubtitle = $"{nowUtc:yyyy-MM-dd HH:mm:ss} UTC | {nowLocal:HH:mm:ss}",
                    text = summaryText,
                    facts = new[]
                    {
                        new { name = "Request ID", value = requestId },
                        new { name = "Priority", value = priority },
                        new { name = "Issue Type", value = issueType },
                        new { name = "Subject", value = subject },
                        new { name = "Page", value = page },
                        new { name = "User", value = string.IsNullOrWhiteSpace(userName) ? "Unknown" : userName },
                        new { name = "Role", value = string.IsNullOrWhiteSpace(role) ? "Unknown" : role },
                        new { name = "Contact Email", value = string.IsNullOrWhiteSpace(contactEmail) ? "Not provided" : contactEmail }
                    },
                    markdown = true
                }
            },
            ["potentialAction"] = new[]
            {
                new Dictionary<string, object?>
                {
                    ["@type"] = "OpenUri",
                    ["name"] = "Open Denial Workflow",
                    ["targets"] = new[]
                    {
                        new { os = "default", uri = "https://www.lrnanalytics.com/DenialWorkflow" }
                    }
                }
            }
        };

        try
        {
            using var response = await _httpClientFactory.CreateClient().PostAsJsonAsync(webhookUrl, payload, cancellationToken: ct);
            if (response.IsSuccessStatusCode) return true;

            _logger.LogWarning("Teams webhook returned {StatusCode} for support request {RequestId}.", response.StatusCode, requestId);
            return false;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unable to send Teams support request {RequestId}.", requestId);
            return false;
        }
    }

    private static string BuildBody(string requestId, string userName, string role, string contactEmail, string page, string issueType, string priority, string subject, string message)
        => new StringBuilder()
            .AppendLine("LRN Denial Workflow Support Request")
            .AppendLine($"RequestId: {requestId}")
            .AppendLine($"UtcTime: {DateTime.UtcNow:O}")
            .AppendLine($"User: {userName}")
            .AppendLine($"Role: {role}")
            .AppendLine($"ContactEmail: {contactEmail}")
            .AppendLine($"Page: {page}")
            .AppendLine($"IssueType: {issueType}")
            .AppendLine($"Priority: {priority}")
            .AppendLine($"Subject: {subject}")
            .AppendLine()
            .AppendLine("Message:")
            .AppendLine(message)
            .ToString();

    private static IReadOnlyList<string> CleanEmails(IEnumerable<string>? emails)
        => (emails ?? Array.Empty<string>())
            .Select(x => x.Trim())
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

    private static string FirstClaim(HttpContext context, params string[] names)
    {
        foreach (var name in names)
        {
            var value = context.User.Claims.FirstOrDefault(c => string.Equals(c.Type, name, StringComparison.OrdinalIgnoreCase))?.Value;
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }
        return string.Empty;
    }

    private static string Truncate(string value, int maxLength)
        => string.IsNullOrEmpty(value) || value.Length <= maxLength ? value : value[..maxLength] + "...";
}
