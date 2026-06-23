using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LRN.ReportsApi.Security;

public static class WorkflowJwt
{
    public const string DefaultIssuer = "LRNMetrics";
    public const string DefaultAudience = "LRNReportsApi";

    public static bool TryValidate(HttpRequest request, IConfiguration configuration, out ClaimsPrincipal principal)
        => TryValidate(request, configuration, out principal, out _);

    public static bool TryValidate(HttpRequest request, IConfiguration configuration, out ClaimsPrincipal principal, out string reason)
    {
        principal = new ClaimsPrincipal(new ClaimsIdentity());
        reason = string.Empty;

        var token = ExtractToken(request);
        if (string.IsNullOrWhiteSpace(token))
        {
            reason = "Missing workflow JWT. Expected Authorization: Bearer token, X-LRN-Workflow-Jwt header, or __workflowToken query string.";
            return false;
        }

        token = token.Trim();
        if (token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            token = token["Bearer ".Length..].Trim();

        var parts = token.Split('.');
        if (parts.Length != 3)
        {
            reason = "JWT is not in header.payload.signature format.";
            return false;
        }

        var signingKey = configuration["DenialWorkflowAuth:JwtSigningKey"] ?? string.Empty;
        if (string.IsNullOrWhiteSpace(signingKey) || signingKey.Length < 32)
        {
            reason = "Reports API DenialWorkflowAuth:JwtSigningKey is missing or less than 32 characters.";
            return false;
        }

        var signedPayload = $"{parts[0]}.{parts[1]}";
        var expected = Base64UrlEncode(HmacSha256(signingKey, signedPayload));
        if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(expected), Encoding.ASCII.GetBytes(parts[2])))
        {
            reason = "JWT signature mismatch. JwtSigningKey is not identical in LabMetricsDashboard and LRN.ReportsApi.";
            return false;
        }

        JsonElement root;
        try
        {
            using var payloadDoc = JsonDocument.Parse(Encoding.UTF8.GetString(Base64UrlDecode(parts[1])));
            root = payloadDoc.RootElement.Clone();
        }
        catch
        {
            reason = "JWT payload could not be decoded.";
            return false;
        }

        var expectedIssuer = configuration["DenialWorkflowAuth:Issuer"] ?? DefaultIssuer;
        var expectedAudience = configuration["DenialWorkflowAuth:Audience"] ?? DefaultAudience;
        var issuer = GetString(root, "iss");
        var audience = GetString(root, "aud");

        if (!string.Equals(issuer, expectedIssuer, StringComparison.Ordinal))
        {
            reason = $"JWT issuer mismatch. Token issuer '{issuer}', API expected '{expectedIssuer}'.";
            return false;
        }

        if (!string.Equals(audience, expectedAudience, StringComparison.Ordinal))
        {
            reason = $"JWT audience mismatch. Token audience '{audience}', API expected '{expectedAudience}'.";
            return false;
        }

        var exp = GetLong(root, "exp");
        if (exp <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
        {
            reason = "JWT is expired.";
            return false;
        }

        var claims = new List<Claim>();
        AddClaim(claims, ClaimTypes.NameIdentifier, GetString(root, "sub"));
        AddClaim(claims, ClaimTypes.Name, GetString(root, "name"));
        AddClaim(claims, ClaimTypes.Email, GetString(root, "email"));
        AddClaim(claims, "display_name", GetString(root, "display_name"));

        AddArrayClaims(root, "roles", ClaimTypes.Role, claims);
        AddArrayClaims(root, "labs", "lab", claims);

        var identity = new ClaimsIdentity(claims, "LRNWorkflowJwt", ClaimTypes.Name, ClaimTypes.Role);
        principal = new ClaimsPrincipal(identity);
        reason = "OK";
        return identity.IsAuthenticated;
    }

    private static string ExtractToken(HttpRequest request)
    {
        var auth = request.Headers.Authorization.ToString();
        if (!string.IsNullOrWhiteSpace(auth))
        {
            return auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
                ? auth["Bearer ".Length..].Trim()
                : auth.Trim();
        }

        var headerNames = new[]
        {
            "X-LRN-Workflow-Jwt",
            "X-Authorization",
            "X-Access-Token",
            "X-Workflow-Token"
        };

        foreach (var headerName in headerNames)
        {
            var header = request.Headers[headerName].ToString();
            if (!string.IsNullOrWhiteSpace(header))
            {
                return header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
                    ? header["Bearer ".Length..].Trim()
                    : header.Trim();
            }
        }

        var queryNames = new[]
        {
            "__workflowToken",
            "workflowToken",
            "access_token",
            "token"
        };

        foreach (var queryName in queryNames)
        {
            var value = request.Query[queryName].ToString();
            if (!string.IsNullOrWhiteSpace(value)) return value.Trim();
        }

        return string.Empty;
    }

    private static void AddClaim(List<Claim> claims, string type, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value)) claims.Add(new Claim(type, value));
    }

    private static void AddArrayClaims(JsonElement root, string propertyName, string claimType, List<Claim> claims)
    {
        if (!root.TryGetProperty(propertyName, out var arr) || arr.ValueKind != JsonValueKind.Array) return;
        foreach (var item in arr.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                var value = item.GetString();
                if (!string.IsNullOrWhiteSpace(value)) claims.Add(new Claim(claimType, value));
            }
            else if (item.ValueKind == JsonValueKind.Object)
            {
                var id = GetString(item, "labId");
                var name = GetString(item, "labName");
                if (!string.IsNullOrWhiteSpace(id)) claims.Add(new Claim("lab_id", id));
                if (!string.IsNullOrWhiteSpace(name)) claims.Add(new Claim("lab_name", name));
            }
        }
    }

    private static string? GetString(JsonElement root, string name)
        => root.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null ? v.ToString() : null;

    private static long GetLong(JsonElement root, string name)
        => root.TryGetProperty(name, out var v) && v.TryGetInt64(out var n) ? n : 0;

    private static byte[] HmacSha256(string key, string value)
    {
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(key));
        return hmac.ComputeHash(Encoding.ASCII.GetBytes(value));
    }

    private static byte[] Base64UrlDecode(string value)
    {
        var padded = value.Replace('-', '+').Replace('_', '/');
        switch (padded.Length % 4)
        {
            case 2: padded += "=="; break;
            case 3: padded += "="; break;
        }
        return Convert.FromBase64String(padded);
    }

    private static string Base64UrlEncode(byte[] value)
        => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
