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

        var isAdmin = roles.Any(r => string.Equals(r, "Admin", StringComparison.OrdinalIgnoreCase));

        var labs = new List<object>();
        if (isAdmin)
        {
            // A demo lab is excluded from the admin shortcut: it reaches the token only for a
            // user actually assigned it, so the Denial Workflow app scopes it the same way the
            // dashboard's lab picker does. See LabConfigOptions.DemoLabs.
            var assignedLabNames = user.Claims
                .Where(c => c.Type == "LabName")
                .Select(c => c.Value)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            labs = (_labConfig.LabsID ?? new List<LabIdInfo>())
                .Where(l => l.Id > 0 && !string.IsNullOrWhiteSpace(l.Name))
                .Where(l => assignedLabNames.Contains(l.Name) || !_labConfig.IsDemoLab(l.Name))
                .OrderBy(l => l.Name)
                .DistinctBy(l => l.Id)
                .Select(l => new { labId = l.Id, labName = l.Name })
                .Cast<object>()
                .ToList();
        }
        else if (labUserId > 0)
        {
            var userLabs = (await _users.GetUserLabsAsync(labUserId)).ToList();
            labs = userLabs
                .Select(ul => new { labId = ul.LabId, labName = _labConfig.GetLabNameById(ul.LabId) ?? ul.LabName ?? string.Empty })
                .Where(x => x.labId > 0 && !string.IsNullOrWhiteSpace(x.labName))
                .OrderBy(x => x.labName)
                .DistinctBy(x => x.labId)
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
