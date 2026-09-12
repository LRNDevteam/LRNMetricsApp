using System.Security.Claims;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;

namespace LRN.ReportsApi.Security;

/// <summary>
/// The one thing <see cref="LabAccess"/> needs from the workflow service: which labs a named user
/// is assigned.
///
/// <para>
/// Split out rather than depending on IDenialWorkflowService directly. That interface has around
/// thirty members covering dashboards, imports and snapshots, none of which an access check has
/// any business reaching. Depending on all of it would also mean anything testing the access rule
/// has to stub thirty methods to exercise one.
/// </para>
/// </summary>
public interface IUserLabLookup
{
    Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct);
}

/// <summary>Adapts the workflow service to the one member the access check uses.</summary>
public sealed class DenialWorkflowUserLabLookup : IUserLabLookup
{
    private readonly IDenialWorkflowService _service;

    public DenialWorkflowUserLabLookup(IDenialWorkflowService service) => _service = service;

    public Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct)
        => _service.GetLabsForUserAsync(userName, ct);
}

/// <summary>
/// Whether the caller may act on a given lab.
///
/// <para>
/// HIPAA finding F4. This logic existed, but only inside DenialActionVerificationController, and
/// only that controller called it. Every other workflow endpoint took a labId and used it: notes,
/// claim history, document download, document upload and delete, bulk import and the export jobs.
/// A token issued for lab 1 could read lab 2 by changing a query-string number.
/// </para>
/// <para>
/// Lifted here so the same answer serves the whole API, and so
/// <see cref="Filters.RequireLabAccessFilter"/> can apply it without each controller having to
/// remember.
/// </para>
/// </summary>
public interface ILabAccess
{
    /// <summary>True when this caller may act on this lab.</summary>
    Task<bool> CanAccessAsync(ClaimsPrincipal user, int labId, CancellationToken ct);

    /// <summary>True when the caller holds an admin role, matched exactly.</summary>
    bool IsAdmin(ClaimsPrincipal user);
}

public sealed class LabAccess : ILabAccess
{
    /// <summary>The message returned on refusal. Identical everywhere so a caller cannot tell
    /// "this lab is not yours" from "no such lab", which would confirm the lab exists.</summary>
    public const string DeniedMessage = "You do not have access to this lab.";

    private readonly IUserLabLookup _userLabs;

    public LabAccess(IUserLabLookup userLabs) => _userLabs = userLabs;

    public async Task<bool> CanAccessAsync(ClaimsPrincipal user, int labId, CancellationToken ct)
    {
        if (labId <= 0) return false;
        if (IsAdmin(user)) return true;

        // The token is authoritative when it carries lab claims. It is signed, so the caller cannot
        // edit it, and it reflects the assignment at sign-in.
        var tokenLabIds = LabIdsFromToken(user);
        if (tokenLabIds.Count > 0) return tokenLabIds.Contains(labId);

        // Fallback for tokens issued before lab claims existed. A database round trip per request,
        // which is why it is second and not first.
        var name = UserName(user);
        if (string.IsNullOrWhiteSpace(name)) return false;

        var labs = await _userLabs.GetLabsForUserAsync(name, ct);
        return labs.Any(l => l.LabId == labId);
    }

    /// <summary>
    /// Exact role matching, against EVERY role claim.
    ///
    /// <para>
    /// HIPAA finding F10. The original check normalised the FIRST role claim to letters and digits
    /// and asked whether it CONTAINED "ADMIN". Two faults in one line: a user whose first claim was
    /// some other role lost their admin rights, and any role whose name merely contains the word -
    /// "Non Admin", "Admin Assistant", "Administrative Reviewer" - was granted them.
    /// </para>
    /// </summary>
    public bool IsAdmin(ClaimsPrincipal user) => HasRole(user, "Admin", "LRN Admin", "LRNAdmin");

    /// <summary>Whether the caller holds any of these roles, compared exactly after normalising.</summary>
    public static bool HasRole(ClaimsPrincipal user, params string[] roles)
    {
        if (user is null) return false;

        var held = user.Claims
            .Where(c => IsRoleClaim(c.Type))
            // One claim can carry several comma-separated roles.
            .SelectMany(c => c.Value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Select(Normalize)
            .Where(v => v.Length > 0)
            .ToHashSet(StringComparer.Ordinal);

        return roles.Select(Normalize).Any(held.Contains);
    }

    /// <summary>The lab ids the token asserts, from either claim spelling.</summary>
    public static HashSet<int> LabIdsFromToken(ClaimsPrincipal user)
    {
        if (user is null) return new HashSet<int>();

        return user.Claims
            .Where(c => string.Equals(c.Type, "lab_id", StringComparison.OrdinalIgnoreCase)
                     || string.Equals(c.Type, "labs", StringComparison.OrdinalIgnoreCase))
            .SelectMany(c => c.Value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Select(v => int.TryParse(v, out var id) ? id : 0)
            .Where(id => id > 0)
            .ToHashSet();
    }

    public static string? UserName(ClaimsPrincipal user) =>
        FirstClaim(user, ClaimTypes.Name, "name", "preferred_username", "unique_name", "upn");

    public static string? FirstClaim(ClaimsPrincipal user, params string[] names)
    {
        if (user is null) return null;

        foreach (var name in names)
        {
            var value = user.Claims
                .FirstOrDefault(c => string.Equals(c.Type, name, StringComparison.OrdinalIgnoreCase))?.Value;

            if (!string.IsNullOrWhiteSpace(value)) return value;
        }

        return null;
    }

    private static bool IsRoleClaim(string type) =>
        string.Equals(type, ClaimTypes.Role, StringComparison.OrdinalIgnoreCase)
        || string.Equals(type, "role", StringComparison.OrdinalIgnoreCase)
        || string.Equals(type, "roles", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Letters and digits only, upper-cased, so "AR Manager", "ar-manager" and "ARManager" are one
    /// role. This is the same normalisation the old code used; what changed is that the result is
    /// compared for EQUALITY rather than containment.
    /// </summary>
    private static string Normalize(string? value) =>
        new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
}
