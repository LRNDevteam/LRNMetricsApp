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
/// <summary>Validated manager / team / scope for a user (T054).</summary>
public sealed record ArWorkbenchUserProfile(int? ManagerUserId, string? TeamName, IReadOnlyList<ArWorkbenchUserScopeValue> Scopes);

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

    public const int MaxTeamNameLength = 100;
    public const int MaxScopeValueLength = 500;

    /// <summary>The role labels that can head a team (be another user's manager).</summary>
    public static readonly string[] ManagerRoleLabels = ["System Administrator", "RCM Manager", "Senior AR Analyst / Team Lead"];

    /// <summary>
    /// T054 manager / team / access scope. A Clinic or Provider Viewer role (roleScope clinic |
    /// provider) needs exactly one value for every selected lab, chosen from that lab's claims
    /// (scopeChoices); any other role keeps no scope. The manager must be one of the offered
    /// managers and not the user themselves.
    /// </summary>
    public static (ArWorkbenchUserProfile? Profile, string? Error) ValidateProfile(
        string? roleScope, IReadOnlyList<int> labIds, IReadOnlyList<ArWorkbenchUserScopeValue>? scopes,
        IReadOnlyDictionary<int, IReadOnlyList<string>> scopeChoices,
        int? managerUserId, IReadOnlyCollection<int> allowedManagerIds, int? targetLabUserId, string? teamName)
    {
        var team = string.IsNullOrWhiteSpace(teamName) ? null : string.Join(' ', teamName.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (team is { Length: > MaxTeamNameLength }) return (null, $"Team name must be {MaxTeamNameLength} characters or fewer.");

        int? manager = managerUserId is > 0 ? managerUserId : null;
        if (manager is not null)
        {
            if (manager == targetLabUserId) return (null, "A user cannot be their own manager.");
            if (!allowedManagerIds.Contains(manager.Value)) return (null, "Choose the manager from the list (a System Administrator, RCM Manager or Team Lead in these labs).");
        }

        var result = new List<ArWorkbenchUserScopeValue>();
        if (roleScope is "clinic" or "provider")
        {
            var byLab = (scopes ?? []).GroupBy(s => s.LabId).ToDictionary(g => g.Key, g => g.Last());
            foreach (var labId in labIds)
            {
                var raw = byLab.TryGetValue(labId, out var s) ? (roleScope == "clinic" ? s.ClinicName : s.ProviderName) : null;
                var value = raw?.Trim();
                if (string.IsNullOrEmpty(value))
                    return (null, $"Choose the {(roleScope == "clinic" ? "clinic" : "referring provider")} for every selected lab.");
                if (value.Length > MaxScopeValueLength) return (null, "That clinic / provider name is too long.");
                var choices = scopeChoices.TryGetValue(labId, out var c) ? c : [];
                var match = choices.FirstOrDefault(x => string.Equals(x, value, StringComparison.OrdinalIgnoreCase));
                if (match is null) return (null, $"\"{value}\" is not a {(roleScope == "clinic" ? "clinic" : "referring provider")} on that lab's claims.");
                result.Add(roleScope == "clinic"
                    ? new ArWorkbenchUserScopeValue { LabId = labId, ClinicName = match }
                    : new ArWorkbenchUserScopeValue { LabId = labId, ProviderName = match });
            }
        }
        return (new ArWorkbenchUserProfile(manager, team, result), null);
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
