using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services.UserMail;

/// <summary>
/// "UserMail" section - user emails for LRN Metrics and the AR Workbench. TenantId / ClientId /
/// ClientSecret are optional here: when blank they fall back to the app registration the SharePoint
/// workers already use, which Key Vault (kv-lrnmetrics-prod) supplies as
/// MasterFileProcessor--SharePoint--TenantId / --ClientId / --ClientSecret. Sending needs the
/// Microsoft Graph Mail.Send APPLICATION permission (admin consented) on that registration, and
/// SenderMailbox must be a real mailbox in its tenant.
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
    public string? SupportEmail { get; set; }
}

public interface IUserMailSender
{
    /// <summary>The From address that will be used (for the log), or null when none is configured.</summary>
    string? SenderAddress { get; }
    /// <returns>(true, null) when Graph accepted the message; otherwise false and the reason.</returns>
    Task<(bool Sent, string? Error)> SendAsync(string to, string subject, string htmlBody, CancellationToken ct);
}

/// <summary>Microsoft Graph sendMail with an app-only (client credentials) token.</summary>
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

    public string? SenderAddress => Setting(_options.CurrentValue.SenderMailbox, "DenialWorkflowSupport:SmtpFromEmail");

    public async Task<(bool Sent, string? Error)> SendAsync(string to, string subject, string htmlBody, CancellationToken ct)
    {
        var o = _options.CurrentValue;
        if (!o.Enabled) return (false, "Email sending is switched off (UserMail:Enabled = false).");

        var tenantId = Setting(o.TenantId, "MasterFileProcessor:SharePoint:TenantId");
        var clientId = Setting(o.ClientId, "MasterFileProcessor:SharePoint:ClientId");
        var secret = Setting(o.ClientSecret, "MasterFileProcessor:SharePoint:ClientSecret");
        var sender = SenderAddress;
        var missing = new List<string>();
        if (tenantId is null) missing.Add("TenantId");
        if (clientId is null) missing.Add("ClientId");
        if (secret is null) missing.Add("ClientSecret");
        if (sender is null) missing.Add("SenderMailbox");
        if (missing.Count > 0)
            return (false, $"Graph mail is not configured: {string.Join(", ", missing)} missing (UserMail:* or MasterFileProcessor:SharePoint:* in Key Vault).");

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
    }

    private static string Shorten(string value, int max) => value.Length <= max ? value : value[..max] + "…";
}
