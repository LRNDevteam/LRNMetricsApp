using System.Security.Claims;
using LabMetricsDashboard.Models;
using Microsoft.AspNetCore.Authentication.Cookies;

namespace LabMetricsDashboard.Services.Security;

public enum LrnSignInOutcome { Ok, Inactive, NoRole, NoLabs, LabsNotMapped }

public sealed record LrnSignInResult(
    LrnSignInOutcome Outcome,
    ClaimsPrincipal? Principal = null,
    string? DefaultLabName = null,
    bool IsAdmin = false,
    bool IsDenialWorkflowUser = false);

/// <summary>
/// The one place a LabUsers row becomes a signed-in principal, for both providers. Entra proves who
/// the user is; this decides what they may do. Also rebuilds the cookie on each periodic
/// re-validation (<see cref="LrnCookieRevalidation"/>), so role and lab changes reach users who are
/// already signed in.
/// </summary>
public sealed class LrnSignInService
{
    private readonly IUserManagementRepository _repo;
    private readonly LabConfigOptions _labConfig;
    private readonly LabSettings _labSettings;
    private readonly ILogger<LrnSignInService> _logger;

    public LrnSignInService(IUserManagementRepository repo, LabConfigOptions labConfig, LabSettings labSettings, ILogger<LrnSignInService> logger)
    {
        _repo = repo;
        _labConfig = labConfig;
        _labSettings = labSettings;
        _logger = logger;
    }

    /// <param name="logWarnings">False on re-validation, so a config gap is logged once per sign-in rather than every few minutes.</param>
    public async Task<LrnSignInResult> BuildAsync(LabUser user, bool logWarnings = true)
    {
        if (!user.IsActive) return new(LrnSignInOutcome.Inactive);

        // Independent queries, run concurrently: each opens its own pooled connection, and against a
        // remote SQL server this saves two round trips on every sign-in.
        var rolesForUserTask = _repo.GetUserRolesAsync(user.LabUserID);
        var allRolesTask     = _repo.GetAllRolesAsync();
        var userLabsTask     = _repo.GetUserLabsAsync(user.LabUserID);
        await Task.WhenAll(rolesForUserTask, allRolesTask, userLabsTask);

        var allRoles = (await allRolesTask).ToDictionary(r => r.RoleID, r => r.RoleName);
        var roleNames = (await rolesForUserTask)
            .Select(r => allRoles.TryGetValue(r.RoleID, out var n) ? n : string.Empty)
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        // Signed in (by password or by Microsoft) but not yet authorized: no cookie is issued and the
        // user sees Access pending until an administrator assigns a role.
        if (roleNames.Count == 0) return new(LrnSignInOutcome.NoRole);

        var userLabs = (await userLabsTask).ToList();

        // For login redirects and lab claims, rely on LabConfig:LabsID mapping from appsettings.json.
        // This makes the behavior consistent across environments even if dbo.Labs entries differ.
        var mappedLabs = userLabs
            .Select(ul => new { ul.ULID, ul.LabId, Name = _labConfig.GetLabNameById(ul.LabId) })
            .Where(x => !string.IsNullOrWhiteSpace(x.Name))
            // Newest UserLabs row (highest ULID) first: that is the default lab after sign-in.
            .OrderByDescending(x => x.ULID)
            .DistinctBy(x => x.LabId)
            .ToList();

        if (logWarnings)
        {
            var unmappedLabIds = userLabs
                .Select(ul => ul.LabId)
                .Where(id => string.IsNullOrWhiteSpace(_labConfig.GetLabNameById(id)))
                .Distinct()
                .ToList();
            if (unmappedLabIds.Count > 0)
                _logger.LogWarning(
                    "User {UserName} has UserLabs assignments with LabId(s) not found in LabConfig:LabsID: [{LabIds}]",
                    user.UserName, string.Join(",", unmappedLabIds));

            var mappedButMissingJson = mappedLabs.Where(x => !_labSettings.Labs.ContainsKey(x.Name!)).ToList();
            if (mappedButMissingJson.Count > 0)
                _logger.LogWarning(
                    "User {UserName} mapped labs [{Labs}] are not present in LabSettings.Labs (missing per-lab JSON / LabConfig:Labs).",
                    user.UserName, string.Join(",", mappedButMissingJson.Select(l => $"{l.LabId}:{l.Name}")));
        }

        // The same admin set as MenuAccessFilter and WorkflowJwtIssuer. "Lab Admin" is deliberately NOT
        // here: a lab admin is scoped to a lab by definition, so it keeps going through the lab check.
        var isAdmin = roleNames.Any(r => IsRole(r, "Admin") || IsRole(r, "Super Admin") || IsRole(r, "LRN Admin"));
        var isArManager = roleNames.Any(r => IsRole(r, "AR Manager"));
        var isArReviewer = roleNames.Any(r => IsRole(r, "AR Reviewer") || IsRole(r, "AR Analyser") || IsRole(r, "AR Analyzer"));
        var isClientManager = roleNames.Any(r => IsRole(r, "Client Manager"));
        var isAccountManager = roleNames.Any(r => IsRole(r, "Account Manager"));
        // The AR Workbench roles in dbo.Roles all start with "AR Workbench - " (the same prefix
        // LRN.ReportsApi uses to find them - see LRNMaster_01_ARWB_Roles_Access.sql).
        var isArWorkbenchUser = roleNames.Any(r => (r ?? string.Empty).TrimStart().StartsWith("AR Workbench - ", StringComparison.OrdinalIgnoreCase));
        var isDenialWorkflowUser = isArManager || isArReviewer || isClientManager || isAccountManager || isArWorkbenchUser;

        // Only an admin without a Denial Workflow / AR Workbench role may sign in without labs.
        var requiresLabs = !(isAdmin && !isDenialWorkflowUser);
        if (requiresLabs && userLabs.Count == 0)
        {
            if (logWarnings)
                _logger.LogWarning(
                    "Login blocked for {UserName}: no rows in UserLabs. Roles: [{Roles}]. "
                    + "Assign the user a lab, or the account cannot sign in.",
                    user.UserName, string.Join(", ", roleNames));
            return new(LrnSignInOutcome.NoLabs);
        }
        if (requiresLabs && mappedLabs.Count == 0)
        {
            if (logWarnings)
                _logger.LogWarning(
                    "Login blocked for {UserName}: UserLabs has LabId(s) [{LabIds}] but none resolve "
                    + "through LabConfig:LabsID. Roles: [{Roles}]. Add the mapping to appsettings.",
                    user.UserName,
                    string.Join(", ", userLabs.Select(l => l.LabId).Distinct()),
                    string.Join(", ", roleNames));
            return new(LrnSignInOutcome.LabsNotMapped);
        }

        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.LabUserID.ToString()),
            new(ClaimTypes.Name,           user.UserName),
            new("FullName",                $"{user.FirstName} {user.LastName}".Trim()),
            new(LrnAuth.ProviderClaim,     user.IsEntra ? LrnAuth.EntraProvider : LrnAuth.LocalProvider),
            new(LrnAuth.StampClaim,        user.SecurityStamp.ToString()),
        };
        claims.AddRange(roleNames.Select(rn => new Claim(ClaimTypes.Role, rn)));
        claims.AddRange(mappedLabs.Select(l => new Claim("LabName", l.Name!)));

        var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
        return new(LrnSignInOutcome.Ok, new ClaimsPrincipal(identity), mappedLabs.FirstOrDefault()?.Name, isAdmin, isDenialWorkflowUser);
    }

    /// <summary>Role names compared ignoring case, spaces and punctuation: "AR Manager" = "ARManager".</summary>
    public static bool IsRole(string? actual, string expected)
        => string.Equals(Normalize(actual), Normalize(expected), StringComparison.OrdinalIgnoreCase);

    private static string Normalize(string? value)
        => new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
}
