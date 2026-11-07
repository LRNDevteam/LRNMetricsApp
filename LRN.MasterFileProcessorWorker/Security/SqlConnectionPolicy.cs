using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.Security;

/// <summary>One connection string that breaks the policy. Never carries the string itself.</summary>
/// <param name="Key">Configuration key, e.g. <c>ConnectionStrings:CoveConnection</c>.</param>
/// <param name="Target">Server/database, for finding it - no credentials.</param>
/// <param name="Problem">What is wrong and how to fix it.</param>
/// <param name="Corrected">True when the worker fixed it in memory and it needs no action to run.</param>
public sealed record SqlConnectionFinding(string Key, string Target, string Problem, bool Corrected);

/// <summary>
/// HIPAA checklist CC-08 / MF-04: every SQL connection - LRNMaster and each lab database, all of
/// which hold PHI - must be encrypted in transit, must validate the server certificate, and must not
/// use <c>sa</c>.
/// <para>
/// The connection strings live in Key Vault, so this cannot fix them at the source. What it does, at
/// startup and before any connection is opened:
/// </para>
/// <list type="bullet">
///   <item><b>Encrypt</b> off is switched on in memory. Always safe: SqlClient still connects, and
///         it is what every lab string already asks for.</item>
///   <item><b>TrustServerCertificate=True</b> and an <b>sa</b> login are reported. They are not
///         changed, because the fix (a trusted certificate, a dedicated login) is outside this
///         process and changing them here would stop the lab connecting. In
///         <c>Security:SqlConnectionPolicy = Enforce</c> the service refuses to start until the vault
///         secret is fixed; in <c>Warn</c> it starts and logs each one.</item>
/// </list>
/// </summary>
public static class SqlConnectionPolicy
{
    public const string ModeKey = "Security:SqlConnectionPolicy";
    public const string Enforce = "Enforce";
    public const string Warn = "Warn";

    /// <summary>Enforce unless configuration explicitly says Warn.</summary>
    public static bool IsEnforced(IConfiguration configuration) =>
        !string.Equals(configuration[ModeKey]?.Trim(), Warn, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Checks every <c>ConnectionStrings:*</c> value, switches encryption on where it is off, and
    /// returns what it found. Writing the corrected value back through <see cref="IConfiguration"/>
    /// means every <c>GetConnectionString</c> after this call sees it - the call must run after the
    /// host is built and before the worker starts.
    /// </summary>
    public static IReadOnlyList<SqlConnectionFinding> Apply(IConfiguration configuration)
    {
        var findings = new List<SqlConnectionFinding>();

        foreach (var entry in configuration.GetSection("ConnectionStrings").GetChildren())
        {
            if (string.IsNullOrWhiteSpace(entry.Value))
                continue;

            var (hardened, problems) = Evaluate(entry.Path, entry.Value);
            findings.AddRange(problems);

            if (hardened is not null)
                configuration[entry.Path] = hardened;
        }

        return findings;
    }

    /// <summary>
    /// The policy for one connection string: the corrected string when something was switched on
    /// (null when nothing changed), and every finding.
    /// </summary>
    public static (string? Hardened, IReadOnlyList<SqlConnectionFinding> Findings) Evaluate(string key, string connectionString)
    {
        SqlConnectionStringBuilder builder;

        try
        {
            builder = new SqlConnectionStringBuilder(connectionString);
        }
        catch (ArgumentException)
        {
            // Not a SQL Server connection string - not ours to judge.
            return (null, Array.Empty<SqlConnectionFinding>());
        }

        var target = $"{builder.DataSource}/{builder.InitialCatalog}";
        var findings = new List<SqlConnectionFinding>();
        string? hardened = null;

        if (builder.Encrypt == SqlConnectionEncryptOption.Optional)
        {
            builder.Encrypt = SqlConnectionEncryptOption.Mandatory;
            hardened = builder.ConnectionString;
            findings.Add(new SqlConnectionFinding(key, target,
                "Encrypt was off; switched to Encrypt=True for this process. Set Encrypt=True in the vault secret.",
                Corrected: true));
        }

        if (builder.TrustServerCertificate)
        {
            findings.Add(new SqlConnectionFinding(key, target,
                "TrustServerCertificate=True: the server certificate is not validated. Set TrustServerCertificate=False " +
                "in the vault secret (the server needs a certificate this machine trusts).",
                Corrected: false));
        }

        if (string.Equals(builder.UserID?.Trim(), "sa", StringComparison.OrdinalIgnoreCase))
        {
            findings.Add(new SqlConnectionFinding(key, target,
                "Connects as 'sa'. Use a dedicated least-privilege login or the service's managed identity.",
                Corrected: false));
        }

        return (hardened, findings);
    }
}
