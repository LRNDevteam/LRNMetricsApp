using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LRN.ReportsApi.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Token endpoint for external (machine-to-machine) API clients.
///
/// Interactive users get their JWT from LabMetricsDashboard when they open a workflow, which
/// needs a browser session. An external integrator has none, so this exchanges a client id and
/// secret for the same kind of token — signed with the same key, issuer and audience, so
/// <see cref="WorkflowJwt"/> validates it with no special case.
///
/// This controller is deliberately outside the authenticated path in Program.cs: it is how a
/// caller gets a token in the first place. It authenticates on the client secret instead.
/// </summary>
[ApiController]
[Route("api/auth")]
public sealed class AuthController : ControllerBase
{
    private readonly ExternalApiClientOptions _options;
    private readonly IConfiguration _configuration;
    private readonly IMemoryCache _cache;
    private readonly ILogger<AuthController> _logger;

    public AuthController(
        IOptions<ExternalApiClientOptions> options,
        IConfiguration configuration,
        IMemoryCache cache,
        ILogger<AuthController> logger)
    {
        _options = options.Value;
        _configuration = configuration;
        _cache = cache;
        _logger = logger;
    }

    public sealed class TokenRequest
    {
        public string? ClientId { get; set; }
        public string? ClientSecret { get; set; }
        /// <summary>Optional; only "client_credentials" is supported. Ignored when absent.</summary>
        public string? GrantType { get; set; }
    }

    /// <summary>POST /api/auth/token — exchange client credentials for a bearer token.</summary>
    [HttpPost("token")]
    [Consumes("application/json")]
    public IActionResult Token([FromBody] TokenRequest request)
    {
        var clientId = (request.ClientId ?? string.Empty).Trim();
        var secret = request.ClientSecret ?? string.Empty;

        if (!string.IsNullOrWhiteSpace(request.GrantType)
            && !request.GrantType.Equals("client_credentials", StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { error = "unsupported_grant_type", message = "Only client_credentials is supported." });

        if (clientId.Length == 0 || secret.Length == 0)
            return BadRequest(new { error = "invalid_request", message = "clientId and clientSecret are required." });

        if (IsLockedOut(clientId))
        {
            _logger.LogWarning("Token request for locked-out client {ClientId} from {Ip}.", clientId, RemoteIp());
            return StatusCode(StatusCodes.Status429TooManyRequests, new
            {
                error = "too_many_requests",
                message = $"Too many failed attempts. Try again in {_options.LockoutMinutes} minutes."
            });
        }

        var client = _options.Clients.FirstOrDefault(
            c => c.ClientId.Equals(clientId, StringComparison.Ordinal));

        // One message and one status for "no such client", "disabled" and "wrong secret" — telling
        // them apart lets an attacker enumerate valid client ids.
        if (client is null || !client.Enabled || !ApiSecretHasher.Verify(secret, client.SecretHash))
        {
            RecordFailure(clientId);
            _logger.LogWarning(
                "Failed token request for client {ClientId} from {Ip} (known: {Known}, enabled: {Enabled}).",
                clientId, RemoteIp(), client is not null, client?.Enabled ?? false);
            return Unauthorized(new { error = "invalid_client", message = "Client id or secret is not valid." });
        }

        var signingKey = _configuration["DenialWorkflowAuth:JwtSigningKey"] ?? string.Empty;
        if (signingKey.Length < 32)
        {
            _logger.LogError("Cannot issue token: DenialWorkflowAuth:JwtSigningKey is missing or under 32 characters.");
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                error = "server_misconfigured",
                message = "Token signing is not configured. Contact LRN support."
            });
        }

        ClearFailures(clientId);

        var now = DateTimeOffset.UtcNow;
        var expires = now.AddMinutes(Math.Clamp(_options.TokenMinutes, 5, 1440));
        var payload = new Dictionary<string, object?>
        {
            ["iss"] = _configuration["DenialWorkflowAuth:Issuer"] ?? WorkflowJwt.DefaultIssuer,
            ["aud"] = _configuration["DenialWorkflowAuth:Audience"] ?? WorkflowJwt.DefaultAudience,
            ["sub"] = client.ClientId,
            ["name"] = string.IsNullOrWhiteSpace(client.DisplayName) ? client.ClientId : client.DisplayName,
            ["display_name"] = string.IsNullOrWhiteSpace(client.DisplayName) ? client.ClientId : client.DisplayName,
            ["roles"] = client.Roles,
            ["labs"] = client.Labs.Select(l => new { labId = l.LabId, labName = l.LabName }).ToList(),
            ["client_type"] = "external",
            ["iat"] = now.ToUnixTimeSeconds(),
            ["exp"] = expires.ToUnixTimeSeconds()
        };

        _logger.LogInformation(
            "Issued token for external client {ClientId} from {Ip}, roles [{Roles}], expires {Expires:u}.",
            client.ClientId, RemoteIp(), string.Join(", ", client.Roles), expires.UtcDateTime);

        return Ok(new
        {
            access_token = Sign(payload, signingKey),
            token_type = "Bearer",
            expires_in = (int)(expires - now).TotalSeconds,
            expires_at_utc = expires.UtcDateTime,
            roles = client.Roles
        });
    }

    private string RemoteIp() => HttpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";

    private string LockKey(string clientId) => $"auth-fail:{clientId}";

    private bool IsLockedOut(string clientId) =>
        _cache.TryGetValue(LockKey(clientId), out int failures) && failures >= _options.MaxFailedAttempts;

    private void RecordFailure(string clientId)
    {
        var failures = _cache.TryGetValue(LockKey(clientId), out int current) ? current + 1 : 1;
        _cache.Set(LockKey(clientId), failures, TimeSpan.FromMinutes(Math.Max(1, _options.LockoutMinutes)));
    }

    private void ClearFailures(string clientId) => _cache.Remove(LockKey(clientId));

    /// <summary>
    /// Same HS256 construction as LabMetricsDashboard's WorkflowJwtIssuer, so one validator
    /// serves both token sources.
    /// </summary>
    private static string Sign(Dictionary<string, object?> payload, string key)
    {
        var header = new Dictionary<string, object?> { ["alg"] = "HS256", ["typ"] = "JWT" };
        var headerPart = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(header));
        var payloadPart = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(payload));
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(key));
        var signature = Base64UrlEncode(hmac.ComputeHash(Encoding.ASCII.GetBytes($"{headerPart}.{payloadPart}")));
        return $"{headerPart}.{payloadPart}.{signature}";
    }

    private static string Base64UrlEncode(byte[] value)
        => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
