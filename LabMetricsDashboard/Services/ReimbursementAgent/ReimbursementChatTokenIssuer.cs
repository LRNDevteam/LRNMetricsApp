using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LabMetricsDashboard.Models;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services.ReimbursementAgent;

/// <summary>
/// Mints the short-lived HS256 ticket the Reimbursement Agent proxy demands on every /api/ask call.
///
/// The proxy validates it with stock ASP.NET Core JWT bearer authentication (issuer, audience,
/// lifetime, HMAC-SHA256 signature), so the three-part token is assembled by hand here — the same
/// approach <see cref="Security.WorkflowJwtIssuer"/> already uses for LRN.ReportsApi — rather than
/// pulling System.IdentityModel.Tokens.Jwt into this project for one token shape.
///
/// The ticket never leaves the server: <see cref="ReimbursementAgentApiClient"/> attaches it to a
/// server-to-server call. That is deliberate. The chat page itself is protected by the ordinary
/// LRN.Auth cookie, so the browser never holds a credential for the agent backend.
/// </summary>
public sealed class ReimbursementChatTokenIssuer
{
    private readonly IOptionsMonitor<ReimbursementChatTokenOptions> _options;

    public ReimbursementChatTokenIssuer(IOptionsMonitor<ReimbursementChatTokenOptions> options)
        => _options = options;

    public string CreateToken(ClaimsPrincipal user)
    {
        var options = _options.CurrentValue;

        // Checked here rather than at startup so a missing key breaks only the chat screen,
        // with a message naming the setting, instead of stopping the whole site from booting.
        if (string.IsNullOrWhiteSpace(options.SigningKey) || options.SigningKey.Length < 32)
        {
            throw new InvalidOperationException(
                "ChatToken:SigningKey is missing or too short. It must be at least 32 characters and " +
                "byte-identical to the ChatToken__SigningKey application setting on the reimb-agent-proxy " +
                "App Service. Store it in Key Vault as ChatToken--SigningKey or in appsettings.Local.json.");
        }

        var userName = user.Identity?.Name ?? user.FindFirstValue(ClaimTypes.Name) ?? "unknown";
        var now = DateTimeOffset.UtcNow;
        var expires = now.AddMinutes(Math.Max(1, options.LifetimeMinutes));

        var payload = new Dictionary<string, object?>
        {
            ["iss"] = options.Issuer,
            ["aud"] = options.Audience,
            // The proxy only checks that the ticket is valid, but it logs the caller — send the
            // signed-in user so an unexpected question can be traced back to a person.
            ["sub"] = userName,
            ["name"] = userName,
            ["iat"] = now.ToUnixTimeSeconds(),
            ["exp"] = expires.ToUnixTimeSeconds()
        };

        var header = new Dictionary<string, object?> { ["alg"] = "HS256", ["typ"] = "JWT" };
        var headerPart = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(header));
        var payloadPart = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(payload));
        var signature = Base64UrlEncode(HmacSha256(options.SigningKey, $"{headerPart}.{payloadPart}"));

        return $"{headerPart}.{payloadPart}.{signature}";
    }

    private static byte[] HmacSha256(string key, string value)
    {
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(key));
        return hmac.ComputeHash(Encoding.ASCII.GetBytes(value));
    }

    private static string Base64UrlEncode(byte[] value)
        => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
