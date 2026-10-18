using System.Collections.Generic;
using System.Threading.Tasks;

namespace LabMetricsDashboard.Services;

using LabMetricsDashboard.Models;

public interface IUserManagementRepository
{
    Task<int> CreateUserAsync(LabUser user);
    Task<int> CreateRoleAsync(Role role);
    Task AssignRoleAsync(int labUserId, int roleId);
    Task AssignUserLabAsync(UserLab userLab);
    Task<IEnumerable<LabUser>> GetAllUsersAsync();
    Task<IEnumerable<Role>> GetAllRolesAsync();
    Task<LabUser?> GetUserByIdAsync(int labUserId);
    Task<LabUser?> GetUserByUserNameAsync(string userName);
    Task UpdateUserAsync(LabUser user, string? passwordHash = null);
    Task<IEnumerable<UserRole>> GetUserRolesAsync(int labUserId);
    Task<IEnumerable<UserLab>> GetUserLabsAsync(int labUserId);
    Task DeactivateUserAsync(int labUserId, string? modifiedBy = null);
    Task RemoveUserRoleAsync(int userRoleId);
    Task RemoveUserLabAsync(int ulid);
    Task<IEnumerable<LabMetricsDashboard.Models.Lab>> GetAllLabsAsync();
    Task<IEnumerable<ReviewerOption>> GetUsersByRoleNamesAsync(IEnumerable<string> roleNames);

    /// <summary>Same as <see cref="GetUsersByRoleNamesAsync(IEnumerable{string})"/> but scoped to users
    /// assigned to the given lab via dbo.UserLabs - the AR Reviewer picker on Denial Insight uses
    /// this so it never offers a reviewer from a different lab.</summary>
    Task<IEnumerable<ReviewerOption>> GetUsersByRoleNamesAsync(IEnumerable<string> roleNames, int labId);

    /// <summary>
    /// AR Reporting Requirements GAP-2: username -&gt; manager username / team, for reports to
    /// LEFT JOIN against a lab's free-text DenialTaskBoard.AssignedTo. Matches case-insensitively
    /// on the report side, the same convention AssignedTo comparisons already use elsewhere.
    /// </summary>
    Task<IEnumerable<AnalystManagerTeam>> GetAnalystManagerTeamMapAsync();

    Task<UserRole?> GetUserRoleByIdAsync(int userRoleId);
    Task<UserLab?> GetUserLabByIdAsync(int ulid);

    // ── Hybrid sign-in (local password + Microsoft Entra ID) ─────────────────────────────
    Task<LabUser?> GetUserByEntraObjectIdAsync(Guid objectId);

    /// <summary>Returns the Entra user for <paramref name="objectId"/>, creating it - active, no roles, no labs - on first sign-in.</summary>
    Task<LabUser> GetOrCreateEntraUserAsync(Guid objectId, Guid tenantId, string upn, string? email, string? displayName);

    /// <summary>Persistent per-account lockout: after <paramref name="maxAttempts"/> failures the account is locked for <paramref name="lockoutMinutes"/>.</summary>
    Task RecordFailedLoginAsync(int labUserId, int maxAttempts, int lockoutMinutes);
    Task RecordSuccessfulLoginAsync(int labUserId);
    Task WriteLoginAuditAsync(int? labUserId, string? loginValue, string provider, bool succeeded, string? reason, string? ipAddress);

    /// <summary>Moves a pending Microsoft sign-in onto an existing local account (dbo.usp_LinkEntraUser).</summary>
    Task LinkEntraUserAsync(int existingLabUserId, int pendingLabUserId, string linkedBy);

    // ?? Lab management (LabMaster) ?????????????????????????????????
    Task<LabMetricsDashboard.Models.Lab?> GetLabByIdAsync(int labId);
    Task<LabMetricsDashboard.Models.Lab?> GetLabByNameAsync(string labName);
    Task<int> CreateLabAsync(LabMetricsDashboard.Models.Lab lab);
    Task UpdateLabAsync(LabMetricsDashboard.Models.Lab lab);
}
