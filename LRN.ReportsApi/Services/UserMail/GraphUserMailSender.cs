using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services.UserMail;

/// <summary>
/// "UserMail" section - user emails for LRN Metrics and the AR Workbench. The Graph app registration
/// is read from Azure Key Vault first - the one the SharePoint workers use, stored as
/// MasterFileProcessor--SharePoint--TenantId / --ClientId / --ClientSecret (configuration
/// MasterFileProcessor:SharePoint:*). UserMail:TenantId / ClientId / ClientSecret are only a fallback
/// for a machine without the vault. Sending needs the Microsoft Graph Mail.Send APPLICATION
/// permission (admin consented) on that registration, and SenderMailbox must be a real mailbox in its tenant.
/// </summary>
public sealed class UserMailOptions
{
    public bool Enabled { get; set; } = true;
    public string? TenantId { get; set; }
    public string? ClientId { get; set; }
    public string? ClientSecret { get; set; }
    /// <summary>The mailbox emails are sent from (Graph /users/{SenderMailbox}/sendMail).</summary>
    public string? SenderMailbox { get; set; }
    /// <summary>LRN Metrics set-password page, e.g. https://www.lrnanalytics.com/lrnAnalytics/Account/SetPassword.</summary>
    public string? FirstLoginUrl { get; set; }
    /// <summary>LRN Metrics sign-in page, shown in the email for later visits.</summary>
    public string? SignInUrl { get; set; }
    /// <summary>AR Workbench address, shown in the email when the user has an AR Workbench role.</summary>
    public string? ArWorkbenchUrl { get; set; }
    public int InvitationExpiryHours { get; set; } = 72;
    /// <summary>Support contacts shown in every user email (Need help? ...). Several allowed.</summary>
    public List<string> SupportEmails { get; set; } = new();
    /// <summary>Older single-address setting; still honoured, added to <see cref="SupportEmails"/>.</summary>
    public string? SupportEmail { get; set; }

    /// <summary>SupportEmails plus the legacy SupportEmail, trimmed, blanks and duplicates removed.</summary>
    public IReadOnlyList<string> AllSupportEmails() =>
        SupportEmails.Append(SupportEmail ?? string.Empty)
            .Select(e => e?.Trim() ?? string.Empty)
            .Where(e => e.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
}

public interface IUserMailSender
{
    /// <summary>The From address that will be used (for the log), or null when none is configured.</summary>
    string? SenderAddress { get; }
    /// <returns>(true, null) when Graph accepted the message; otherwise false and the reason.</returns>
    Task<(bool Sent, string? Error)> SendAsync(string to, string subject, string htmlBody, CancellationToken ct);
}

/// <summary>
/// Microsoft Graph sendMail with an app-only (client credentials) token. Never throws: a missing or
/// wrong tenant / client / secret, an unreachable Graph or any other failure comes back as
/// (false, reason), which the caller writes to the email log as a failed send.
/// </summary>
public sealed class GraphUserMailSender : IUserMailSender
{
    private static readonly string[] GraphScope = ["https://graph.microsoft.com/.default"];
    private readonly IHttpClientFactory _httpFactory;
    private readonly IOptionsMonitor<UserMailOptions> _options;
    private readonly IConfiguration _configuration;
    private readonly ILogger<GraphUserMailSender> _logger;

    public GraphUserMailSender(IHttpClientFactory httpFactory, IOptionsMonitor<UserMailOptions> options,
        IConfiguration configuration, ILogger<GraphUserMailSender> logger)
    {
        _httpFactory = httpFactory;
        _options = options;
        _configuration = configuration;
        _logger = logger;
    }

    private string? Setting(string? value, string fallbackKey)
        => !string.IsNullOrWhiteSpace(value) ? value.Trim() : _configuration[fallbackKey]?.Trim() is { Length: > 0 } v ? v : null;

    // Key Vault first (MasterFileProcessor--SharePoint--*), then the UserMail:* fallback.
    private string? VaultFirst(string vaultKey, string? fallback)
        => _configuration[vaultKey]?.Trim() is { Length: > 0 } v ? v : string.IsNullOrWhiteSpace(fallback) ? null : fallback.Trim();

    public string? SenderAddress => Setting(_options.CurrentValue.SenderMailbox, "DenialWorkflowSupport:SmtpFromEmail");

    /// <summary>Why the Graph credentials cannot work, or null when they look usable (testable, no network).</summary>
    public static string? CredentialProblem(string? tenantId, string? clientId, string? secret, string? sender)
    {
        var missing = new List<string>();
        if (string.IsNullOrWhiteSpace(tenantId)) missing.Add("TenantId");
        if (string.IsNullOrWhiteSpace(clientId)) missing.Add("ClientId");
        if (string.IsNullOrWhiteSpace(secret)) missing.Add("ClientSecret");
        if (string.IsNullOrWhiteSpace(sender)) missing.Add("SenderMailbox");
        if (missing.Count > 0)
            return $"Graph mail is not configured: {string.Join(", ", missing)} missing (Key Vault MasterFileProcessor--SharePoint--* / UserMail:SenderMailbox).";
        // A tenant is a GUID or a verified domain (contoso.onmicrosoft.com); the client is always a GUID.
        if (!Guid.TryParse(tenantId, out _) && !tenantId!.Contains('.'))
            return "Graph mail tenant ID is not valid (MasterFileProcessor--SharePoint--TenantId must be a GUID or a tenant domain).";
        if (!Guid.TryParse(clientId, out _))
            return "Graph mail client ID is not valid (MasterFileProcessor--SharePoint--ClientId must be a GUID).";
        return null;
    }

    public async Task<(bool Sent, string? Error)> SendAsync(string to, string subject, string htmlBody, CancellationToken ct)
    {
        var o = _options.CurrentValue;
        if (!o.Enabled) return (false, "Email sending is switched off (UserMail:Enabled = false).");

        var tenantId = VaultFirst("MasterFileProcessor:SharePoint:TenantId", o.TenantId);
        var clientId = VaultFirst("MasterFileProcessor:SharePoint:ClientId", o.ClientId);
        var secret = VaultFirst("MasterFileProcessor:SharePoint:ClientSecret", o.ClientSecret);
        var sender = SenderAddress;
        if (CredentialProblem(tenantId, clientId, secret, sender) is { } problem)
        {
            _logger.LogWarning("User mail to {To} not sent: {Problem}", to, problem);
            return (false, problem);
        }

        try
        {
            var credential = new ClientSecretCredential(tenantId, clientId, secret);
            var token = await credential.GetTokenAsync(new TokenRequestContext(GraphScope), ct);

            var payload = new
            {
                message = new
                {
                    subject,
                    body = new { contentType = "HTML", content = htmlBody },
                    toRecipients = new[] { new { emailAddress = new { address = to } } }
                },
                saveToSentItems = true
            };

            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"https://graph.microsoft.com/v1.0/users/{Uri.EscapeDataString(sender!)}/sendMail")
            {
                Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

            var client = _httpFactory.CreateClient(nameof(GraphUserMailSender));
            client.Timeout = TimeSpan.FromSeconds(30);
            using var response = await client.SendAsync(request, ct);
            if (response.IsSuccessStatusCode) return (true, null);

            var detail = await response.Content.ReadAsStringAsync(ct);
            _logger.LogWarning("Graph sendMail to {To} failed: {Status} {Detail}", to, (int)response.StatusCode, detail);
            return (false, $"Graph returned {(int)response.StatusCode}: {Shorten(detail, 600)}");
        }
        catch (AuthenticationFailedException ex)
        {
            _logger.LogError(ex, "Graph token request failed for user mail.");
            return (false, $"Could not get a Graph token: {Shorten(ex.Message, 600)}");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            _logger.LogError(ex, "Graph sendMail to {To} failed.", to);
            return (false, $"Could not reach Microsoft Graph: {Shorten(ex.Message, 600)}");
        }
        catch (Exception ex)
        {
            // Anything else (a malformed tenant / client the SDK rejects, a bad address ...) is still
            // just a failed send: it is logged and reported, never thrown into user creation.
            _logger.LogError(ex, "User mail to {To} failed.", to);
            return (false, $"Email could not be sent: {Shorten(ex.Message, 600)}");
        }
    }

    private static string Shorten(string value, int max) => value.Length <= max ? value : value[..max] + "…";
}
