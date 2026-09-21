using System.Security.Claims;

namespace LabMetricsDashboard.Services.Security;

/// <summary>
/// The two administrative roles and the checks that decide what each may do.
///
/// <para><b>Super Admin</b> is the old "Admin" role renamed in place - same RoleID, same users, so
/// nobody had to be reassigned. The legacy spellings are still accepted here because they are
/// written into signed-in cookies and into other databases' role rows; dropping them would sign
/// every current admin out of the admin screens until their cookie expired.</para>
///
/// <para><b>Lab Admin</b> administers users, but only within the labs it has itself been assigned.
/// It is deliberately not a weaker Super Admin: it can never see, edit or create a user outside its
/// labs, never grant a lab it does not hold, and never grant an administrative role - which is what
/// stops a Lab Admin promoting someone (or themselves, through someone) past their own reach.</para>
/// </summary>
public static class AppRoles
{
    /// <summary>Canonical names, as stored in dbo.Roles.</summary>
    public const string SuperAdmin = "Super Admin";
    public const string LabAdmin = "Lab Admin";

    /// <summary>Authorization policy names, registered in Program.cs.</summary>
    public const string SuperAdminPolicy = "SuperAdminOnly";
    public const string UserAdministrationPolicy = "UserAdministration";

    /// <summary>
    /// Everything that has ever meant "full administrator". "Admin" is the pre-rename spelling and
    /// the LRN variants predate that; all three are still live in issued cookies and seed data.
    /// </summary>
    private static readonly string[] SuperAdminNames =
        ["Super Admin", "SuperAdmin", "Super-Admin", "Admin", "LRN Admin", "LRNAdmin"];

    private static readonly string[] LabAdminNames = ["Lab Admin", "LabAdmin", "Lab-Admin"];

    public static bool IsSuperAdmin(ClaimsPrincipal? user) => HasAny(user, SuperAdminNames);

    public static bool IsLabAdmin(ClaimsPrincipal? user) => HasAny(user, LabAdminNames);

    /// <summary>Who may open the user-management screens at all. Scope is applied separately.</summary>
    public static bool CanAdministerUsers(ClaimsPrincipal? user)
        => IsSuperAdmin(user) || IsLabAdmin(user);

    /// <summary>
    /// True for a role a Lab Admin must never hand out. Granting Super Admin would be a straight
    /// escalation; granting Lab Admin would let them widen their own reach through a second account.
    /// </summary>
    public static bool IsAdministrativeRole(string? roleName)
        => Matches(roleName, SuperAdminNames) || Matches(roleName, LabAdminNames);

    /// <summary>
    /// True when a role name is one of the full-administrator spellings. Lets a call site that
    /// asks for "Admin" keep working after the rename without listing every variant itself.
    /// </summary>
    public static bool IsSuperAdminName(string? roleName) => Matches(roleName, SuperAdminNames);

    /// <summary>True when a role name means Lab Admin.</summary>
    public static bool IsLabAdminName(string? roleName) => Matches(roleName, LabAdminNames);

    /// <summary>The lab names on the principal, as written by the login handler.</summary>
    public static IReadOnlyCollection<string> LabNames(ClaimsPrincipal? user)
        => user?.FindAll("LabName")
               .Select(c => c.Value)
               .Where(v => !string.IsNullOrWhiteSpace(v))
               .Distinct(StringComparer.OrdinalIgnoreCase)
               .ToArray()
           ?? [];

    private static bool HasAny(ClaimsPrincipal? user, string[] names)
        => user?.Identity?.IsAuthenticated == true && names.Any(user.IsInRole);

    private static bool Matches(string? roleName, string[] names)
        => !string.IsNullOrWhiteSpace(roleName)
           && names.Any(n => string.Equals(n, roleName.Trim(), StringComparison.OrdinalIgnoreCase));
}
