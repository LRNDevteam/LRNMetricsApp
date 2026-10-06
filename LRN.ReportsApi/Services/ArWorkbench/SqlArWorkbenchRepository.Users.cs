using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// AR Workbench User Management over the LRNMaster user tables. A user is "an AR Workbench user"
/// when they hold one of the "AR Workbench - ..." roles. Creating one writes dbo.LabUsers,
/// dbo.UserRoles and dbo.UserLabs in one transaction; editing replaces only the user's AR Workbench
/// role (other roles are kept) and only the labs the caller manages (other labs are kept).
/// Who may change whom is decided by <see cref="ArWorkbenchUserRules.CanManage"/>.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    /// <summary>Every active lab in dbo.Labs (what a Super Admin can grant).</summary>
    public async Task<IReadOnlyList<ArWorkbenchLabOption>> GetAllLabsAsync(CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand("SELECT LabId, LabName FROM dbo.Labs WHERE ISNULL(IsActive, 1) = 1 ORDER BY LabName;", master);
        var list = new List<ArWorkbenchLabOption>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            list.Add(new ArWorkbenchLabOption { LabId = r.GetInt32(0), LabName = r.IsDBNull(1) ? $"Lab {r.GetInt32(0)}" : r.GetString(1) });
        return list;
    }

    /// <summary>
    /// The labs assigned to a user in dbo.UserLabs - what a lab-scoped admin may grant. No row means
    /// no labs (never "all labs").
    /// </summary>
    public async Task<IReadOnlySet<int>> GetUserLabIdsAsync(int labUserId, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand("SELECT DISTINCT LabId FROM dbo.UserLabs WHERE LabUserID = @Id;", master);
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        var ids = new HashSet<int>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) ids.Add(r.GetInt32(0));
        return ids;
    }

    /// <summary>
    /// The AR Workbench roles a user can be given here. The Clinic and Provider Viewer roles carry
    /// their Scope: they need the clinic / provider per lab (dbo.ARWB_UserScope), which the access
    /// picker supplies; without it the user would be locked out (fails closed).
    /// </summary>
    public async Task<IReadOnlyList<ArWorkbenchRoleOption>> GetAssignableRolesAsync(CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
SELECT r.RoleID, r.RoleName,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.RoleFeatureAccess fa WHERE fa.RoleId = r.RoleID AND fa.FeatureKey = @ScopeClinic AND fa.IsEnabled = 1) THEN 'clinic'
            WHEN EXISTS (SELECT 1 FROM dbo.RoleFeatureAccess fa WHERE fa.RoleId = r.RoleID AND fa.FeatureKey = @ScopeProvider AND fa.IsEnabled = 1) THEN 'provider' END
FROM dbo.Roles r
WHERE ISNULL(r.IsActive, 0) = 1
  AND r.RoleName LIKE @RolePrefix + N'%'
  AND EXISTS (SELECT 1 FROM dbo.RoleFeatureAccess fa WHERE fa.RoleId = r.RoleID AND fa.FeatureKey = @Access AND fa.IsEnabled = 1)
ORDER BY r.RoleID;", master);
        cmd.Parameters.Add("@RolePrefix", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.RolePrefix;
        cmd.Parameters.Add("@Access", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.Access;
        cmd.Parameters.Add("@ScopeClinic", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.ScopeClinic;
        cmd.Parameters.Add("@ScopeProvider", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.ScopeProvider;
        var list = new List<ArWorkbenchRoleOption>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var name = r.GetString(1);
            list.Add(new ArWorkbenchRoleOption { RoleId = r.GetInt32(0), RoleName = name, Label = ArWorkbenchUserRules.RoleLabel(name), Scope = r.IsDBNull(2) ? null : r.GetString(2) });
        }
        return list;
    }

    /// <summary>The clinics or referring providers on a lab's claims - the access picker's choices.</summary>
    public async Task<IReadOnlyList<string>> GetScopeOptionsAsync(int labId, string level, CancellationToken ct)
    {
        var column = level == "provider" ? "ReferringProvider" : "ClinicName";
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand($@"
SELECT TOP (5000) v FROM (SELECT DISTINCT LTRIM(RTRIM({column})) AS v FROM dbo.ARWB_Claim WHERE NULLIF(LTRIM(RTRIM({column})), N'') IS NOT NULL) x
ORDER BY v;", connection) { CommandTimeout = 120 };
        var list = new List<string>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) list.Add(r.GetString(0));
        return list;
    }

    /// <summary>
    /// AR Workbench users the caller can see: every one for a Super Admin, otherwise those with at
    /// least one lab the caller manages. Each row says whether the caller may edit it.
    /// </summary>
    public async Task<IReadOnlyList<ArWorkbenchManagedUser>> GetManagedUsersAsync(
        int? callerLabUserId, bool allLabs, IReadOnlyList<ArWorkbenchLabOption> manageableLabs, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
SELECT DISTINCT ur.LabUserID
INTO #wb
FROM dbo.UserRoles ur
INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID
WHERE r.RoleName LIKE @RolePrefix + N'%';

SELECT u.LabUserID, u.UserName, u.Email, CAST(ISNULL(u.IsActive, 0) AS bit), u.CreatedBy,
       u.ManagerUserID, NULLIF(LTRIM(RTRIM(u.TeamName)), N''),
       COALESCE(NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(m.FirstName, N''), N' ', ISNULL(m.LastName, N'')))), N''), m.UserName)
FROM dbo.LabUsers u
INNER JOIN #wb w ON w.LabUserID = u.LabUserID
LEFT JOIN dbo.LabUsers m ON m.LabUserID = u.ManagerUserID
ORDER BY u.UserName;

SELECT ur.LabUserID, r.RoleID, r.RoleName
FROM dbo.UserRoles ur
INNER JOIN #wb w ON w.LabUserID = ur.LabUserID
INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID;

SELECT ul.LabUserID, ul.LabId
FROM dbo.UserLabs ul
INNER JOIN #wb w ON w.LabUserID = ul.LabUserID;

IF OBJECT_ID(N'dbo.ARWB_UserScope', N'U') IS NOT NULL
    SELECT s.LabUserID, s.LabId, s.ClinicName, s.ProviderName FROM dbo.ARWB_UserScope s INNER JOIN #wb w ON w.LabUserID = s.LabUserID;
ELSE
    SELECT CAST(NULL AS int), CAST(NULL AS int), CAST(NULL AS nvarchar(500)), CAST(NULL AS nvarchar(500)) WHERE 1 = 0;", master);
        cmd.Parameters.Add("@RolePrefix", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.RolePrefix;

        var users = new List<ArWorkbenchManagedUser>();
        var roles = new Dictionary<int, List<(int Id, string Name)>>();
        var labs = new Dictionary<int, List<int>>();
        var scopes = new Dictionary<int, List<ArWorkbenchUserScopeValue>>();
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                users.Add(new ArWorkbenchManagedUser
                {
                    LabUserId = r.GetInt32(0),
                    UserName = r.IsDBNull(1) ? string.Empty : r.GetString(1),
                    Email = r.IsDBNull(2) ? null : r.GetString(2),
                    IsActive = r.GetBoolean(3),
                    CreatedBy = r.IsDBNull(4) ? null : r.GetString(4),
                    ManagerUserId = r.IsDBNull(5) ? null : r.GetInt32(5),
                    TeamName = r.IsDBNull(6) ? null : r.GetString(6),
                    ManagerName = r.IsDBNull(7) ? null : r.GetString(7)
                });
            }
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var id = r.GetInt32(0);
                if (!roles.TryGetValue(id, out var list)) roles[id] = list = new();
                list.Add((r.GetInt32(1), r.GetString(2)));
            }
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var id = r.GetInt32(0);
                if (!labs.TryGetValue(id, out var list)) labs[id] = list = new();
                list.Add(r.GetInt32(1));
            }
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var id = r.GetInt32(0);
                if (!scopes.TryGetValue(id, out var list)) scopes[id] = list = new();
                list.Add(new ArWorkbenchUserScopeValue { LabId = r.GetInt32(1), ClinicName = r.IsDBNull(2) ? null : r.GetString(2), ProviderName = r.IsDBNull(3) ? null : r.GetString(3) });
            }
        }

        var manageable = manageableLabs.ToDictionary(l => l.LabId, l => l.LabName);
        var manageableIds = manageable.Keys.ToHashSet();
        var result = new List<ArWorkbenchManagedUser>();
        foreach (var u in users)
        {
            var userRoles = roles.GetValueOrDefault(u.LabUserId) ?? new();
            var userLabs = labs.GetValueOrDefault(u.LabUserId) ?? new();
            if (!allLabs && !userLabs.Any(manageableIds.Contains)) continue;

            var roleNames = userRoles.Select(x => x.Name).ToList();
            u.Roles = userRoles.Where(x => ArWorkbenchUserRules.IsWorkbenchRole(x.Name))
                .Select(x => new ArWorkbenchRoleOption { RoleId = x.Id, RoleName = x.Name, Label = ArWorkbenchUserRules.RoleLabel(x.Name) })
                .OrderBy(x => x.Label).ToList();
            u.Labs = userLabs.Where(manageableIds.Contains).Distinct()
                .Select(id => new ArWorkbenchLabOption { LabId = id, LabName = manageable[id] })
                .OrderBy(l => l.LabName).ToList();
            u.OtherLabCount = userLabs.Distinct().Count(id => !manageableIds.Contains(id));
            u.Scopes = (scopes.GetValueOrDefault(u.LabUserId) ?? new()).Where(s => manageableIds.Contains(s.LabId)).ToList();
            u.HasOtherRoles = roleNames.Any(n => !ArWorkbenchUserRules.IsWorkbenchRole(n));
            u.IsSiteAdmin = roleNames.Any(ArWorkbenchUserRules.IsSiteAdminRole);
            (u.CanEdit, u.ReadOnlyReason) = ArWorkbenchUserRules.CanManage(u.LabUserId, roleNames, userLabs, callerLabUserId, allLabs, manageableIds);
            result.Add(u);
        }
        return result;
    }

    /// <summary>
    /// T054: manager / team (dbo.LabUsers) and the clinic / provider scope per lab (dbo.ARWB_UserScope).
    /// Only scope rows for labs the caller manages are replaced; other labs' rows are kept.
    /// Returns false when scopes are needed but LRNMaster has no dbo.ARWB_UserScope.
    /// </summary>
    private static async Task<bool> WriteProfileAsync(SqlConnection master, SqlTransaction tx, int labUserId, ArWorkbenchUserProfile profile,
        IReadOnlyCollection<int> manageableLabIds, string user, CancellationToken ct)
    {
        await using var cmd = master.CreateCommand();
        cmd.Transaction = tx;
        var labs = manageableLabIds.Count > 0 ? AddIntList(cmd, "@Ml", manageableLabIds.ToList()) : "NULL";
        var inserts = new List<string>();
        for (var i = 0; i < profile.Scopes.Count; i++)
        {
            var s = profile.Scopes[i];
            cmd.Parameters.Add($"@SL{i}", SqlDbType.Int).Value = s.LabId;
            cmd.Parameters.Add($"@SC{i}", SqlDbType.NVarChar, 500).Value = (object?)s.ClinicName ?? DBNull.Value;
            cmd.Parameters.Add($"@SP{i}", SqlDbType.NVarChar, 500).Value = (object?)s.ProviderName ?? DBNull.Value;
            inserts.Add($"(@Id, @SL{i}, @SC{i}, @SP{i}, @User)");
        }
        cmd.CommandText = $@"
UPDATE dbo.LabUsers SET ManagerUserID = @Mgr, TeamName = @Team WHERE LabUserID = @Id;
IF OBJECT_ID(N'dbo.ARWB_UserScope', N'U') IS NULL
BEGIN
    SELECT CASE WHEN @HasScopes = 1 THEN 0 ELSE 1 END;
    RETURN;
END;
DELETE FROM dbo.ARWB_UserScope WHERE LabUserID = @Id AND LabId IN ({labs});
{(inserts.Count > 0 ? $"INSERT INTO dbo.ARWB_UserScope (LabUserID, LabId, ClinicName, ProviderName, CreatedBy) VALUES {string.Join(", ", inserts)};" : "")}
SELECT 1;";
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        cmd.Parameters.Add("@Mgr", SqlDbType.Int).Value = (object?)profile.ManagerUserId ?? DBNull.Value;
        cmd.Parameters.Add("@Team", SqlDbType.NVarChar, 100).Value = profile.TeamName ?? string.Empty;
        cmd.Parameters.Add("@HasScopes", SqlDbType.Bit).Value = profile.Scopes.Count > 0;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 100).Value = Truncate(user, 100);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    private static ArWorkbenchSaveResult ScopeTableMissing() =>
        ArWorkbenchSaveResult.Invalid("Clinic / Provider access needs dbo.ARWB_UserScope in LRNMaster. Run LRN.ReportsApi/Sql/ArWorkbench/LRNMaster_01_ARWB_Roles_Access.sql.");

    public async Task<(ArWorkbenchSaveResult Result, int? LabUserId)> CreateWorkbenchUserAsync(
        string userName, string passwordHash, string email, int roleId, IReadOnlyList<int> labIds, ArWorkbenchUserProfile profile,
        IReadOnlyCollection<int> manageableLabIds, string createdBy, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var tx = (SqlTransaction)await master.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = master.CreateCommand();
        cmd.Transaction = tx;
        var labParams = AddIntList(cmd, "@Lab", labIds);
        cmd.CommandText = $@"
IF EXISTS (SELECT 1 FROM dbo.LabUsers WITH (UPDLOCK, HOLDLOCK) WHERE UserName = @UserName)
BEGIN SELECT -1; RETURN; END;

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleID = @RoleId AND ISNULL(IsActive, 0) = 1 AND RoleName LIKE @RolePrefix + N'%')
BEGIN SELECT -2; RETURN; END;

IF (SELECT COUNT(*) FROM dbo.Labs WHERE LabId IN ({labParams})) <> @LabCount
BEGIN SELECT -3; RETURN; END;

-- Blank name fields as the LRN Metrics admin screen writes them.
INSERT INTO dbo.LabUsers (UserName, PasswordHash, FirstName, LastName, MiddleName, Email, Mobile, IsExternalUser, IsActive, ManagerUserID, TeamName, CreatedBy)
VALUES (@UserName, @PasswordHash, N'', N'', N'', @Email, N'', 0, 1, NULL, N'', @CreatedBy);
DECLARE @Id int = CAST(SCOPE_IDENTITY() AS int);

INSERT INTO dbo.UserRoles (LabUserID, RoleID) VALUES (@Id, @RoleId);

INSERT INTO dbo.UserLabs (LabId, LabUserID)
SELECT l.LabId, @Id FROM dbo.Labs l WHERE l.LabId IN ({labParams});

SELECT @Id;";
        cmd.Parameters.Add("@UserName", SqlDbType.NVarChar, 256).Value = userName;
        cmd.Parameters.Add("@PasswordHash", SqlDbType.NVarChar, 512).Value = passwordHash;
        cmd.Parameters.Add("@Email", SqlDbType.NVarChar, 256).Value = email;
        cmd.Parameters.Add("@RoleId", SqlDbType.Int).Value = roleId;
        cmd.Parameters.Add("@RolePrefix", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.RolePrefix;
        cmd.Parameters.Add("@LabCount", SqlDbType.Int).Value = labIds.Count;
        cmd.Parameters.Add("@CreatedBy", SqlDbType.NVarChar, 100).Value = Truncate(createdBy, 100);

        var outcome = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
        if (outcome <= 0)
        {
            await tx.RollbackAsync(ct);
            return (outcome switch
            {
                -1 => ArWorkbenchSaveResult.Conflict($"Username '{userName}' is already taken. If this person already uses LRN Metrics, ask a Super Admin to add the AR Workbench role to that account."),
                -2 => ArWorkbenchSaveResult.Invalid("Choose an AR Workbench role."),
                _ => ArWorkbenchSaveResult.Invalid("One of the chosen labs no longer exists.")
            }, null);
        }
        if (!await WriteProfileAsync(master, tx, outcome, profile, manageableLabIds, createdBy, ct))
        {
            await tx.RollbackAsync(ct);
            return (ScopeTableMissing(), null);
        }
        await tx.CommitAsync(ct);
        return (ArWorkbenchSaveResult.Ok($"User '{userName}' created."), outcome);
    }

    public async Task<ArWorkbenchSaveResult> UpdateWorkbenchUserAsync(
        int labUserId, string email, int roleId, IReadOnlyList<int> requestedLabIds, bool isActive, string? passwordHash, ArWorkbenchUserProfile profile,
        int? callerLabUserId, bool allLabs, IReadOnlySet<int> manageableLabIds, string modifiedBy, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var tx = (SqlTransaction)await master.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        // Read the user under lock, then decide in C# with the same rule the list used.
        string? userName = null;
        var roleNames = new List<(int Id, string Name)>();
        var currentLabs = new List<int>();
        await using (var read = master.CreateCommand())
        {
            read.Transaction = tx;
            read.CommandText = @"
SELECT UserName FROM dbo.LabUsers WITH (UPDLOCK, HOLDLOCK) WHERE LabUserID = @Id;
SELECT r.RoleID, r.RoleName FROM dbo.UserRoles ur INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID WHERE ur.LabUserID = @Id;
SELECT LabId FROM dbo.UserLabs WHERE LabUserID = @Id;";
            read.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
            await using var r = await read.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) userName = r.IsDBNull(0) ? string.Empty : r.GetString(0);
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) roleNames.Add((r.GetInt32(0), r.GetString(1)));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) currentLabs.Add(r.GetInt32(0));
        }

        if (userName is null || !roleNames.Any(x => ArWorkbenchUserRules.IsWorkbenchRole(x.Name)))
        {
            await tx.RollbackAsync(ct);
            return ArWorkbenchSaveResult.NotFound("That AR Workbench user no longer exists.");
        }
        var (allowed, reason) = ArWorkbenchUserRules.CanManage(labUserId, roleNames.Select(x => x.Name).ToList(), currentLabs,
            callerLabUserId, allLabs, manageableLabIds);
        if (!allowed)
        {
            await tx.RollbackAsync(ct);
            return ArWorkbenchSaveResult.Conflict(reason!);
        }

        var finalLabs = ArWorkbenchUserRules.MergeLabs(currentLabs, requestedLabIds, manageableLabIds).ToList();
        await using var cmd = master.CreateCommand();
        cmd.Transaction = tx;
        var labParams = AddIntList(cmd, "@Lab", finalLabs);
        cmd.CommandText = $@"
IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleID = @RoleId AND ISNULL(IsActive, 0) = 1 AND RoleName LIKE @RolePrefix + N'%')
BEGIN SELECT -2; RETURN; END;

UPDATE dbo.LabUsers
SET Email = @Email, IsActive = @IsActive, ModifiedBy = @ModifiedBy, ModifiedDate = SYSUTCDATETIME(),
    PasswordHash = COALESCE(@PasswordHash, PasswordHash)
WHERE LabUserID = @Id;

-- Replace the AR Workbench role only; LRN Metrics / Denial Workflow roles stay.
DELETE ur FROM dbo.UserRoles ur INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID
WHERE ur.LabUserID = @Id AND r.RoleName LIKE @RolePrefix + N'%' AND ur.RoleID <> @RoleId;
IF NOT EXISTS (SELECT 1 FROM dbo.UserRoles WHERE LabUserID = @Id AND RoleID = @RoleId)
    INSERT INTO dbo.UserRoles (LabUserID, RoleID) VALUES (@Id, @RoleId);

DELETE FROM dbo.UserLabs WHERE LabUserID = @Id AND LabId NOT IN ({labParams});
INSERT INTO dbo.UserLabs (LabId, LabUserID)
SELECT l.LabId, @Id FROM dbo.Labs l
WHERE l.LabId IN ({labParams}) AND NOT EXISTS (SELECT 1 FROM dbo.UserLabs x WHERE x.LabUserID = @Id AND x.LabId = l.LabId);

SELECT 1;";
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        cmd.Parameters.Add("@Email", SqlDbType.NVarChar, 256).Value = email;
        cmd.Parameters.Add("@IsActive", SqlDbType.Bit).Value = isActive;
        cmd.Parameters.Add("@ModifiedBy", SqlDbType.NVarChar, 100).Value = Truncate(modifiedBy, 100);
        cmd.Parameters.Add("@PasswordHash", SqlDbType.NVarChar, 512).Value = (object?)passwordHash ?? DBNull.Value;
        cmd.Parameters.Add("@RoleId", SqlDbType.Int).Value = roleId;
        cmd.Parameters.Add("@RolePrefix", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.RolePrefix;

        if (Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) != 1)
        {
            await tx.RollbackAsync(ct);
            return ArWorkbenchSaveResult.Invalid("Choose an AR Workbench role.");
        }
        if (!await WriteProfileAsync(master, tx, labUserId, profile, manageableLabIds, modifiedBy, ct))
        {
            await tx.RollbackAsync(ct);
            return ScopeTableMissing();
        }
        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok($"User '{userName}' updated.");
    }

    /// <summary>Adds @Prefix0..n int parameters and returns them comma-separated for an IN list.</summary>
    private static string AddIntList(SqlCommand cmd, string prefix, IReadOnlyList<int> values)
    {
        if (values.Count == 0) return "NULL";
        for (var i = 0; i < values.Count; i++) cmd.Parameters.Add($"{prefix}{i}", SqlDbType.Int).Value = values[i];
        return string.Join(", ", values.Select((_, i) => $"{prefix}{i}"));
    }
}
