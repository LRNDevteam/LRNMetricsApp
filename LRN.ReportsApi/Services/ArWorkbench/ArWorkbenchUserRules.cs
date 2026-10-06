using System.Net.Mail;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// AR Workbench User Management rules. Users live in LRNMaster (dbo.LabUsers / dbo.UserRoles /
/// dbo.UserLabs) and sign in through LRN Metrics, so the password hash must be exactly the format
/// LabMetricsDashboard's PasswordHasher verifies.
///
/// Who may manage whom:
///   Super Admin (Admin / LRN Admin)    every lab
///   AR Workbench - System Administrator, Lab Admin    only the labs assigned to them
/// Nobody edits their own account or a site admin here, and a lab-scoped admin may only edit a user
/// whose labs and roles are all within their reach - otherwise they could reset the password of
/// someone with access they themselves do not have.
/// </summary>
public static partial class ArWorkbenchUserRules
{
    public const int MinPasswordLength = 8;
    public const int MaxPasswordLength = 128;
    public const int MaxUserNameLength = 100;
    public const int MaxEmailLength = 256;

    // Same as LabMetricsDashboard.Services.PasswordHasher: PBKDF2-SHA256, 100k iterations,
    // 16-byte salt, 32-byte hash, stored "iterations:salt:hash" (base64).
    private const int HashIterations = 100_000;

    public static string HashPassword(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = Rfc2898DeriveBytes.Pbkdf2(password, salt, HashIterations, HashAlgorithmName.SHA256, 32);
        return $"{HashIterations}:{Convert.ToBase64String(salt)}:{Convert.ToBase64String(hash)}";
    }

    [GeneratedRegex("^[A-Za-z0-9._@-]+$")]
    private static partial Regex UserNamePattern();

    public static (string? Value, string? Error) ValidateUserName(string? userName)
    {
        var name = userName?.Trim() ?? string.Empty;
        if (name.Length < 3 || name.Length > MaxUserNameLength)
            return (null, $"Username must be 3 to {MaxUserNameLength} characters.");
        if (!UserNamePattern().IsMatch(name))
            return (null, "Username can use letters, numbers and . _ @ - only (no spaces).");
        return (name, null);
    }

    public static (string? Value, string? Error) ValidateEmail(string? email)
    {
        var value = email?.Trim() ?? string.Empty;
        if (value.Length == 0) return (null, "Email is required.");
        if (value.Length > MaxEmailLength) return (null, "Email is too long.");
        try
        {
            var parsed = new MailAddress(value);
            if (!string.Equals(parsed.Address, value, StringComparison.OrdinalIgnoreCase) || !value.Contains('.', StringComparison.Ordinal))
                return (null, "Enter a valid email address.");
        }
        catch (FormatException)
        {
            return (null, "Enter a valid email address.");
        }
        return (value, null);
    }

    public static string? ValidatePassword(string? password)
    {
        if (string.IsNullOrEmpty(password)) return "Password is required.";
        if (password.Length < MinPasswordLength || password.Length > MaxPasswordLength)
            return $"Password must be {MinPasswordLength} to {MaxPasswordLength} characters.";
        if (!password.Any(char.IsLetter) || !password.Any(char.IsDigit))
            return "Password must contain at least one letter and one number.";
        return null;
    }

    /// <summary>The site admin role names, compared with spaces removed and case ignored.</summary>
    private static readonly HashSet<string> SiteAdminRoleKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "SUPERADMIN", "ADMIN", "LRNADMIN", "LABADMIN"
    };

    public static bool IsSiteAdminRole(string roleName) => SiteAdminRoleKeys.Contains(roleName.Replace(" ", string.Empty));

    public static bool IsWorkbenchRole(string roleName)
        => roleName.StartsWith(ArWorkbenchFeatures.RolePrefix, StringComparison.OrdinalIgnoreCase);

    public static string RoleLabel(string roleName)
        => IsWorkbenchRole(roleName) ? roleName[ArWorkbenchFeatures.RolePrefix.Length..] : roleName;

    /// <summary>Whether the caller may change this user, and if not, why.</summary>
    public static (bool Allowed, string? Reason) CanManage(
        int targetLabUserId, IReadOnlyCollection<string> targetRoleNames, IReadOnlyCollection<int> targetLabIds,
        int? callerLabUserId, bool callerAllLabs, IReadOnlySet<int> manageableLabIds)
    {
        if (callerLabUserId == targetLabUserId)
            return (false, "This is your own account. Another administrator must change it.");
        if (targetRoleNames.Any(IsSiteAdminRole))
            return (false, "Site administrator accounts are managed in LRN Metrics Admin.");
        if (callerAllLabs) return (true, null);
        if (targetLabIds.Any(id => !manageableLabIds.Contains(id)))
            return (false, "This user has labs outside yours. A Super Admin must change it.");
        if (targetRoleNames.Any(r => !IsWorkbenchRole(r)))
            return (false, "This user also has LRN Metrics roles. A Super Admin must change it.");
        return (true, null);
    }

    /// <summary>
    /// The user's labs after an edit: the requested labs (all manageable), plus any labs the user
    /// already has outside the caller's reach, which the caller cannot see and must not remove.
    /// </summary>
    public static IReadOnlySet<int> MergeLabs(IEnumerable<int> currentLabIds, IEnumerable<int> requestedLabIds, IReadOnlySet<int> manageableLabIds)
    {
        var result = new HashSet<int>(currentLabIds.Where(id => !manageableLabIds.Contains(id)));
        result.UnionWith(requestedLabIds.Where(manageableLabIds.Contains));
        return result;
    }

    /// <summary>Requested labs: at least one, no duplicates, every one manageable by the caller.</summary>
    public static (IReadOnlyList<int>? LabIds, string? Error) ValidateLabs(IEnumerable<int>? labIds, IReadOnlySet<int> manageableLabIds)
    {
        var ids = (labIds ?? []).Where(id => id > 0).Distinct().ToList();
        if (ids.Count == 0) return (null, "Choose at least one lab.");
        if (ids.Any(id => !manageableLabIds.Contains(id))) return (null, "You can only grant labs you manage.");
        return (ids, null);
    }
}
