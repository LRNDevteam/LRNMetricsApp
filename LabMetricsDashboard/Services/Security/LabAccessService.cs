using System.Security.Claims;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services.Security;

/// <summary>
/// The single answer to "which labs may this user see, and may they see this one".
///
/// <para>
/// HIPAA finding F3. Before this existed, each controller built its own lab list straight from
/// <c>LabSettings.Labs.Keys</c> - every configured lab, for every user - and
/// <see cref="LabSelectionHelper"/> accepted whatever <c>?lab=</c> was passed. Any authenticated
/// user could read any lab's data by editing the query string. The lab picker in the layout showed
/// the correct, narrower list, so the UI and the server disagreed and only the UI was right.
/// </para>
/// <para>
/// The rule itself is not new and is not reimplemented here:
/// <see cref="LabConfigOptions.VisibleLabs"/> already encodes it, including the demo-lab carve-out.
/// This service is where that rule gets applied consistently.
/// </para>
/// </summary>
public interface ILabAccessService
{
    /// <summary>Every lab name this user may use, in configuration order.</summary>
    IReadOnlyList<string> GetAllowedLabNames(ClaimsPrincipal user);

    /// <summary>Whether this user may use the named lab. False for null, blank or unknown names.</summary>
    bool CanAccess(ClaimsPrincipal user, string? labName);

    /// <summary>Whether this user may use the lab with this id.</summary>
    bool CanAccess(ClaimsPrincipal user, int labId);

    /// <summary>
    /// The named lab, or the user's first allowed lab when the name is blank.
    /// Throws <see cref="LabAccessDeniedException"/> when the user may not use the named lab.
    /// </summary>
    string RequireAccess(ClaimsPrincipal user, string? labName);
}

/// <summary>
/// Thrown when a request names a lab the caller is not entitled to. Translated to 403 by
/// <c>LabAccessDeniedExceptionFilter</c> - never to 404, which would leak whether the lab exists,
/// and never to 500, which would read as a fault in our code rather than a refusal.
/// </summary>
public sealed class LabAccessDeniedException : Exception
{
    public LabAccessDeniedException(string? labName)
        : base($"Access to lab '{labName}' is denied for this user.")
        => LabName = labName;

    public string? LabName { get; }
}

public sealed class LabAccessService : ILabAccessService
{
    // Matches the role names AccountController issues and the rest of the app checks.
    private static readonly string[] AdminRoles = { "Admin", "LRN Admin", "LRNAdmin" };

    // The same singleton every controller already holds. Its Labs dictionary is swapped wholesale
    // when a lab JSON file changes, so reading Keys here always reflects current configuration
    // without this service needing to know about reloads.
    private readonly LabSettings _labSettings;
    private readonly LabConfigOptions _labConfig;

    public LabAccessService(LabSettings labSettings, LabConfigOptions labConfig)
    {
        _labSettings = labSettings;
        _labConfig = labConfig;
    }

    public IReadOnlyList<string> GetAllowedLabNames(ClaimsPrincipal user)
    {
        // An unauthenticated principal gets nothing. [Authorize] should have stopped the request
        // long before this, but a service that returns every lab when handed an empty principal is
        // one misconfigured endpoint away from being the whole vulnerability again.
        if (user?.Identity?.IsAuthenticated != true)
            return Array.Empty<string>();

        var configured = _labSettings.Labs.Keys;

        var assigned = user.Claims
            .Where(c => c.Type == "LabName")
            .Select(c => c.Value)
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        // Deliberately delegated: VisibleLabs is where the demo-lab rule lives, and an admin must
        // not pick up a demo lab they were never assigned.
        return _labConfig.VisibleLabs(configured, assigned, IsAdmin(user));
    }

    public bool CanAccess(ClaimsPrincipal user, string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName)) return false;

        return GetAllowedLabNames(user)
            .Contains(labName.Trim(), StringComparer.OrdinalIgnoreCase);
    }

    public bool CanAccess(ClaimsPrincipal user, int labId)
    {
        // An id that maps to no lab is refused rather than ignored. Treating it as "no lab named,
        // so nothing to check" is how an unmapped id becomes a way past the filter.
        var name = _labConfig.GetLabNameById(labId);
        return !string.IsNullOrWhiteSpace(name) && CanAccess(user, name);
    }

    public string RequireAccess(ClaimsPrincipal user, string? labName)
    {
        var allowed = GetAllowedLabNames(user);

        if (string.IsNullOrWhiteSpace(labName))
        {
            // No lab named: fall back to the user's own first lab, never to the first CONFIGURED
            // lab, which is how a user with no assignment used to land on somebody else's data.
            return allowed.Count > 0 ? allowed[0] : string.Empty;
        }

        var match = allowed.FirstOrDefault(
            l => string.Equals(l, labName.Trim(), StringComparison.OrdinalIgnoreCase));

        if (match is null) throw new LabAccessDeniedException(labName);

        // The configured spelling, not the caller's. Downstream lookups are keyed by lab name and
        // some of those dictionaries are case-sensitive.
        return match;
    }

    private static bool IsAdmin(ClaimsPrincipal user) =>
        AdminRoles.Any(user.IsInRole);
}
