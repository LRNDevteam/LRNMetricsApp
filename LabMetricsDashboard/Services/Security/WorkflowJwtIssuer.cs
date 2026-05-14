using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services.Security;

public sealed record WorkflowJwtTokenResult(string Token, DateTime ExpiresUtc, string UserName, string DisplayName, string Role, IReadOnlyList<string> Roles, IReadOnlyList<object> Labs);

public sealed class WorkflowJwtIssuer
{
    private readonly IConfiguration _configuration;
    private readonly IUserManagementRepository _users;
    private readonly LabConfigOptions _labConfig;

    public WorkflowJwtIssuer(IConfiguration configuration, IUserManagementRepository users, LabConfigOptions labConfig)
    {
        _configuration = configuration;
        _users = users;
        _labConfig = labConfig;
    }

    public async Task<WorkflowJwtTokenResult> CreateTokenAsync(ClaimsPrincipal user, CancellationToken ct = default)
    {
        var userIdText = user.FindFirstValue(ClaimTypes.NameIdentifier) ?? "0";
        _ = int.TryParse(userIdText, out var labUserId);
        var userName = user.Identity?.Name ?? user.FindFirstValue(ClaimTypes.Name) ?? string.Empty;
        var displayName = user.FindFirstValue("FullName") ?? userName;
        var roles = user.Claims.Where(c => c.Type == ClaimTypes.Role).Select(c => c.Value).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        var isAdmin = roles.Any(IsAdminRole);

        // Admin must be able to see every configured lab in Denial Workflow.
        // Non-admin users must remain restricted to their UserLabs assignments.
        var labs = isAdmin
            ? _labConfig.LabsID
                .Where(l => l.Id > 0 && !string.IsNullOrWhiteSpace(l.Name))
                .OrderBy(l => l.Name)
                .GroupBy(l => l.Id)
                .Select(g => new { labId = g.Key, labName = g.First().Name.Trim() })
                .Cast<object>()
                .ToList()
            : new List<object>();

        if (!isAdmin && labUserId > 0)
        {
            var userLabs = (await _users.GetUserLabsAsync(labUserId)).ToList();
            labs = userLabs
                .Select(ul => new { labId = ul.LabId, labName = _labConfig.GetLabNameById(ul.LabId) ?? ul.LabName ?? string.Empty })
                .Where(x => x.labId > 0 && !string.IsNullOrWhiteSpace(x.labName))
                .OrderBy(x => x.labName)
                .GroupBy(x => x.labId)
                .Select(g => new { labId = g.Key, labName = g.First().labName.Trim() })
                .Cast<object>()
                .ToList();
        }

        var now = DateTimeOffset.UtcNow;
        var expires = now.AddMinutes(Math.Max(10, _configuration.GetValue<int?>("DenialWorkflowAuth:TokenMinutes") ?? 480));
        var payload = new Dictionary<string, object?>
        {
            ["iss"] = _configuration["DenialWorkflowAuth:Issuer"] ?? "LRNMetrics",
            ["aud"] = _configuration["DenialWorkflowAuth:Audience"] ?? "LRNReportsApi",
            ["sub"] = userIdText,
            ["name"] = userName,
            ["display_name"] = displayName,
            ["roles"] = roles,
            ["labs"] = labs,
            ["iat"] = now.ToUnixTimeSeconds(),
            ["exp"] = expires.ToUnixTimeSeconds()
        };

        var token = Sign(payload);
        return new WorkflowJwtTokenResult(token, expires.UtcDateTime, userName, displayName, roles.FirstOrDefault() ?? string.Empty, roles, labs);
    }


    private static bool IsAdminRole(string? role)
        => string.Equals(NormalizeRole(role), "ADMIN", StringComparison.OrdinalIgnoreCase);

    private static string NormalizeRole(string? role)
        => new string((role ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private string Sign(Dictionary<string, object?> payload)
    {
        var key = _configuration["DenialWorkflowAuth:JwtSigningKey"] ?? string.Empty;
        if (string.IsNullOrWhiteSpace(key) || key.Length < 32)
            throw new InvalidOperationException("DenialWorkflowAuth:JwtSigningKey must be configured in both LRN Metrics and LRN Reports API and must be at least 32 characters.");

        var header = new Dictionary<string, object?> { ["alg"] = "HS256", ["typ"] = "JWT" };
        var headerPart = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(header));
        var payloadPart = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(payload));
        var signature = Base64UrlEncode(HmacSha256(key, $"{headerPart}.{payloadPart}"));
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
