using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LRN.AI.Api.Security;

/// <summary>
/// Validates the HS256 LRN workflow JWT that LabMetricsDashboard issues (the same token LRN.ReportsApi accepts in
/// LRN.ReportsApi/Security/WorkflowJwt.cs), so the React apps can call the AI API with the token they already hold.
/// Claims are mapped the same way: roles to <see cref="ClaimTypes.Role"/>, lab objects to lab_id / lab_name.
/// </summary>
internal static class LrnJwtValidator
{
    public const string DefaultIssuer = "LRNMetrics";
    public const string DefaultAudience = "LRNReportsApi";
    public const int MinimumKeyLength = 32;
    public const string AuthenticationType = "LrnWorkflowJwt";

    private static readonly TimeSpan ClockSkew = TimeSpan.FromMinutes(1);

    public static bool TryValidate(
        string token, string signingKey, string issuer, string audience, DateTimeOffset now,
        out ClaimsPrincipal? principal, out string failure)
    {
        principal = null;

        if (string.IsNullOrWhiteSpace(signingKey) || signingKey.Length < MinimumKeyLength)
        {
            failure = "The JWT signing key is not configured.";
            return false;
        }

        var parts = token.Split('.');
        if (parts.Length != 3)
        {
            failure = "The token is not a JWT.";
            return false;
        }

        JsonElement header, payload;
        byte[] signature;
        try
        {
            header = ParseJson(parts[0]);
            payload = ParseJson(parts[1]);
            signature = Base64UrlDecode(parts[2]);
        }
        catch (Exception ex) when (ex is FormatException or JsonException or ArgumentException)
        {
            failure = "The token could not be decoded.";
            return false;
        }

        if (header.ValueKind != JsonValueKind.Object || payload.ValueKind != JsonValueKind.Object)
        {
            failure = "The token could not be decoded.";
            return false;
        }

        // Pin the algorithm before checking the signature so "alg":"none" or an RS/HS swap can never be accepted.
        if (!string.Equals(GetString(header, "alg"), "HS256", StringComparison.Ordinal))
        {
            failure = "The token algorithm is not supported.";
            return false;
        }

        using (var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(signingKey)))
        {
            var expected = hmac.ComputeHash(Encoding.ASCII.GetBytes($"{parts[0]}.{parts[1]}"));
            if (!CryptographicOperations.FixedTimeEquals(expected, signature))
            {
                failure = "The token signature is invalid.";
                return false;
            }
        }

        if (!string.Equals(GetString(payload, "iss"), issuer, StringComparison.Ordinal))
        {
            failure = "The token issuer is not accepted.";
            return false;
        }

        if (!HasAudience(payload, audience))
        {
            failure = "The token audience is not accepted.";
            return false;
        }

        var exp = GetLong(payload, "exp");
        if (exp is null || DateTimeOffset.FromUnixTimeSeconds(exp.Value) + ClockSkew <= now)
        {
            failure = "The token is expired.";
            return false;
        }

        var nbf = GetLong(payload, "nbf");
        if (nbf is not null && DateTimeOffset.FromUnixTimeSeconds(nbf.Value) - ClockSkew > now)
        {
            failure = "The token is not valid yet.";
            return false;
        }

        var claims = new List<Claim>();
        AddClaim(claims, ClaimTypes.NameIdentifier, GetString(payload, "sub"));
        AddClaim(claims, ClaimTypes.Name, GetString(payload, "name"));
        AddClaim(claims, ClaimTypes.Email, GetString(payload, "email"));
        AddClaim(claims, "display_name", GetString(payload, "display_name"));
        AddArrayClaims(payload, "roles", ClaimTypes.Role, claims);
        AddArrayClaims(payload, "labs", "lab", claims);

        if (!claims.Any(c => c.Type is ClaimTypes.NameIdentifier or ClaimTypes.Name))
        {
            // HIPAA unique user identification (164.312(a)(2)(i)): every action must be attributable to a user.
            failure = "The token does not identify a user.";
            return false;
        }

        principal = new ClaimsPrincipal(new ClaimsIdentity(claims, AuthenticationType, ClaimTypes.Name, ClaimTypes.Role));
        failure = string.Empty;
        return true;
    }

    private static bool HasAudience(JsonElement payload, string audience)
    {
        if (!payload.TryGetProperty("aud", out var aud)) return false;
        return aud.ValueKind switch
        {
            JsonValueKind.String => string.Equals(aud.GetString(), audience, StringComparison.Ordinal),
            JsonValueKind.Array => aud.EnumerateArray().Any(a => a.ValueKind == JsonValueKind.String && string.Equals(a.GetString(), audience, StringComparison.Ordinal)),
            _ => false
        };
    }

    private static void AddClaim(List<Claim> claims, string type, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value)) claims.Add(new Claim(type, value));
    }

    private static void AddArrayClaims(JsonElement root, string propertyName, string claimType, List<Claim> claims)
    {
        if (!root.TryGetProperty(propertyName, out var array) || array.ValueKind != JsonValueKind.Array) return;
        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                AddClaim(claims, claimType, item.GetString());
            }
            else if (item.ValueKind == JsonValueKind.Object)
            {
                AddClaim(claims, "lab_id", GetString(item, "labId"));
                AddClaim(claims, "lab_name", GetString(item, "labName"));
            }
        }
    }

    private static JsonElement ParseJson(string segment)
    {
        using var document = JsonDocument.Parse(Base64UrlDecode(segment));
        return document.RootElement.Clone();
    }

    private static string? GetString(JsonElement root, string name) =>
        root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null
            ? value.ToString()
            : null;

    private static long? GetLong(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) ? number : null;

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
}
