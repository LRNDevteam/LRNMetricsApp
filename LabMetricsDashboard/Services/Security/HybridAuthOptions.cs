namespace LabMetricsDashboard.Services.Security;

/// <summary>
/// The "HybridAuth" section: local username/password sign-in plus "Sign in with Microsoft"
/// (Entra ID, MFA enforced by Entra). Both paths end in the same auth cookie with the same claims.
/// </summary>
public sealed class HybridAuthOptions
{
    public const string Section = "HybridAuth";

    /// <summary>Shows the Microsoft button and registers the OpenID Connect handler. The rollback switch.</summary>
    public bool EnableMicrosoftLogin { get; set; }

    /// <summary>
    /// Refuses the password form for organization accounts (a username or account email in
    /// <see cref="OrganizationDomains"/>) and points them at the Microsoft button. Leave off until
    /// every staff member has been linked to their Microsoft account, or they are locked out.
    /// </summary>
    public bool BlockOrganizationLocalLogin { get; set; }

    public string[] OrganizationDomains { get; set; } = Array.Empty<string>();

    /// <summary>How often a signed-in cookie is re-checked against LabUsers (roles, labs, active, security stamp).</summary>
    public int RevalidateMinutes { get; set; } = 5;

    public bool IsOrganizationEmail(string? value)
    {
        var v = (value ?? string.Empty).Trim();
        return v.Length > 0 && OrganizationDomains.Any(d =>
            !string.IsNullOrWhiteSpace(d) && v.EndsWith("@" + d.Trim(), StringComparison.OrdinalIgnoreCase));
    }
}

public static class LrnAuth
{
    /// <summary>Short-lived cookie that holds the Entra result for one redirect, before the database decides.</summary>
    public const string ExternalScheme = "LRN.External";
    public const string EntraScheme = "Entra";

    public const string ProviderClaim = "auth_provider";
    public const string StampClaim = "lrn_ss";
    public const string ValidatedItem = ".lrn.validated";

    public const string LocalProvider = "Local";
    public const string EntraProvider = "Entra";

    /// <summary>Per deployment (Authentication:CookieName): Test and Production share the host and path "/".</summary>
    public static string AuthCookieName(IConfiguration configuration)
    {
        var name = configuration["Authentication:CookieName"]?.Trim();
        return string.IsNullOrEmpty(name) ? "LRN.Auth" : name;
    }

    public static string ExternalCookieName(IConfiguration configuration) => AuthCookieName(configuration) + ".External";
}
