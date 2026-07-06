using System.Security.Claims;

namespace LRN.ReportsApi.Security;

/// <summary>
/// Role model for the Payer Master screens (Requirements Spec §2).
/// The legacy "Admin" role is treated as LRN Admin so existing users keep full access.
/// </summary>
public static class PayerMasterRoles
{
    public static bool HasAnyRole(ClaimsPrincipal user, params string[] roles)
        => user.Claims
            .Where(c => c.Type == ClaimTypes.Role || c.Type is "role" or "roles")
            .Any(c => roles.Any(r => string.Equals(c.Value, r, StringComparison.OrdinalIgnoreCase)));

    public static bool IsLrnAdmin(ClaimsPrincipal u) => HasAnyRole(u, "Admin", "LRN Admin", "LRNAdmin");
    public static bool IsPayerPolicyAdmin(ClaimsPrincipal u) => HasAnyRole(u, "Payer Policy Admin", "PayerPolicyAdmin");
    public static bool IsReportsAnalyst(ClaimsPrincipal u) => HasAnyRole(u, "Reports Analyst", "ReportsAnalyst");
    public static bool IsReportsManager(ClaimsPrincipal u) => HasAnyRole(u, "Reports Manager", "ReportsManager");
    public static bool IsEtl(ClaimsPrincipal u) => HasAnyRole(u, "ETL", "Etl");

    // Payer Policy Insurance Master
    public static bool CanViewPolicy(ClaimsPrincipal u) => IsLrnAdmin(u) || IsPayerPolicyAdmin(u) || IsReportsAnalyst(u) || IsEtl(u);
    public static bool CanWritePolicy(ClaimsPrincipal u) => IsLrnAdmin(u) || IsPayerPolicyAdmin(u) || IsReportsAnalyst(u);
    public static bool PolicyRequiresApproval(ClaimsPrincipal u) => IsReportsAnalyst(u) && !IsLrnAdmin(u) && !IsPayerPolicyAdmin(u);
    public static bool CanApprovePolicy(ClaimsPrincipal u) => IsLrnAdmin(u) || IsPayerPolicyAdmin(u);

    // Lab Insurance Master
    public static bool CanViewLab(ClaimsPrincipal u) => IsLrnAdmin(u) || IsReportsManager(u) || IsReportsAnalyst(u) || IsEtl(u);
    public static bool CanWriteLab(ClaimsPrincipal u) => IsLrnAdmin(u) || IsReportsManager(u) || IsReportsAnalyst(u);
    public static bool LabRequiresApproval(ClaimsPrincipal u) => IsReportsAnalyst(u) && !IsLrnAdmin(u) && !IsReportsManager(u);
    public static bool CanApproveLab(ClaimsPrincipal u) => IsLrnAdmin(u) || IsReportsManager(u);

    public static IReadOnlyList<string> RoleNames(ClaimsPrincipal u)
        => u.Claims
            .Where(c => c.Type == ClaimTypes.Role || c.Type is "role" or "roles")
            .Select(c => c.Value)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    public static string UserName(ClaimsPrincipal u)
        => u.Identity?.Name
           ?? u.Claims.FirstOrDefault(c => c.Type is "name" or "preferred_username" or "unique_name" or "upn")?.Value
           ?? "system";
}
