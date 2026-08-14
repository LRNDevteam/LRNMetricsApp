using System.Security.Cryptography;
using System.Text;

namespace LRN.ReportsApi.Security;

/// <summary>
/// Machine-to-machine API clients (external integrators), bound to the
/// "ExternalApiClients" configuration section.
///
/// These are NOT interactive users. Interactive users get their JWT from LabMetricsDashboard
/// when they open a workflow; an external system has no browser session, so before this there
/// was no way for one to obtain a token at all.
/// </summary>
public sealed class ExternalApiClientOptions
{
    public const string Section = "ExternalApiClients";

    /// <summary>Token lifetime. Kept short — these tokens are cheap to re-mint.</summary>
    public int TokenMinutes { get; set; } = 60;

    /// <summary>Consecutive failures for one client id before it is locked out.</summary>
    public int MaxFailedAttempts { get; set; } = 10;

    /// <summary>How long a lockout lasts.</summary>
    public int LockoutMinutes { get; set; } = 15;

    public List<ExternalApiClient> Clients { get; set; } = new();
}

public sealed class ExternalApiClient
{
    public string ClientId { get; set; } = string.Empty;

    public string DisplayName { get; set; } = string.Empty;

    /// <summary>
    /// PBKDF2 verifier, format <c>pbkdf2$&lt;iterations&gt;$&lt;base64 salt&gt;$&lt;base64 hash&gt;</c>.
    /// The plaintext secret is never stored — see <see cref="ApiSecretHasher"/>.
    /// </summary>
    public string SecretHash { get; set; } = string.Empty;

    /// <summary>
    /// Roles written into the token. Use <c>ETL</c> for read-only: PayerMasterRoles grants it
    /// CanViewPolicy and CanViewLab but neither write capability, so a leaked external token
    /// cannot modify master data.
    /// </summary>
    public List<string> Roles { get; set; } = new();

    /// <summary>Labs the token is scoped to; each entry becomes a lab_id / lab_name claim.</summary>
    public List<ExternalApiClientLab> Labs { get; set; } = new();

    public bool Enabled { get; set; } = true;
}

public sealed class ExternalApiClientLab
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
}

/// <summary>
/// PBKDF2-SHA256 hashing for client secrets. Config files are backed up, copied between
/// environments and read by more people than intended, so the secret is stored only as a
/// verifier — a leaked config cannot be replayed against the token endpoint.
/// </summary>
public static class ApiSecretHasher
{
    private const int DefaultIterations = 210_000;
    private const int SaltBytes = 16;
    private const int HashBytes = 32;

    public static string Hash(string secret, int iterations = DefaultIterations)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var hash = Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(secret), salt, iterations, HashAlgorithmName.SHA256, HashBytes);
        return $"pbkdf2${iterations}${Convert.ToBase64String(salt)}${Convert.ToBase64String(hash)}";
    }

    /// <summary>
    /// Constant-time verify. Returns false rather than throwing on a malformed stored hash so a
    /// bad config line reads as "wrong secret" to the caller and is diagnosed from the log.
    /// </summary>
    public static bool Verify(string secret, string storedHash)
    {
        if (string.IsNullOrWhiteSpace(secret) || string.IsNullOrWhiteSpace(storedHash))
            return false;

        var parts = storedHash.Split('$');
        if (parts.Length != 4 || !parts[0].Equals("pbkdf2", StringComparison.Ordinal))
            return false;
        if (!int.TryParse(parts[1], out var iterations) || iterations < 1000)
            return false;

        byte[] salt, expected;
        try
        {
            salt = Convert.FromBase64String(parts[2]);
            expected = Convert.FromBase64String(parts[3]);
        }
        catch (FormatException)
        {
            return false;
        }
        if (salt.Length == 0 || expected.Length == 0)
            return false;

        var actual = Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(secret), salt, iterations, HashAlgorithmName.SHA256, expected.Length);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }
}
