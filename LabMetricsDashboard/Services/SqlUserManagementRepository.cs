using System.Collections.Generic;
using System.Data;
using System.Threading.Tasks;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace LabMetricsDashboard.Services;

public sealed class SqlUserManagementRepository : IUserManagementRepository
{
    private readonly string _conn;

    public SqlUserManagementRepository(IConfiguration cfg)
    {
        _conn = cfg.GetConnectionString("DefaultConnection") ?? throw new ArgumentException("DefaultConnection not configured");
    }

    public async Task<IEnumerable<UserRole>> GetUserRolesAsync(int labUserId)
    {
        const string sql = "SELECT UserRoleId, LabUserID, RoleID FROM dbo.UserRoles WHERE LabUserID = @LabUserID";
        var result = new List<UserRole>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabUserID", labUserId);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(new UserRole
            {
                UserRoleId = r.GetInt32(r.GetOrdinal("UserRoleId")),
                LabUserID = r.GetInt32(r.GetOrdinal("LabUserID")),
                RoleID = r.GetInt32(r.GetOrdinal("RoleID"))
            });
        }
        return result;
    }


    public async Task<IEnumerable<ReviewerOption>> GetUsersByRoleNamesAsync(IEnumerable<string> roleNames)
    {
        var roles = roleNames?.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).ToList() ?? new List<string>();
        if (roles.Count == 0) return Array.Empty<ReviewerOption>();

        var roleParams = roles.Select((_, i) => "@Role" + i).ToList();
        var sql = $@"
SELECT DISTINCT
    u.LabUserID,
    ISNULL(u.UserName, '') AS UserName,
    LTRIM(RTRIM(CONCAT(ISNULL(u.FirstName, ''), ' ', ISNULL(u.LastName, '')))) AS FullName,
    ISNULL(u.Email, '') AS Email
FROM dbo.LabUsers u
INNER JOIN dbo.UserRoles ur ON ur.LabUserID = u.LabUserID
INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID
WHERE ISNULL(u.IsActive, 0) = 1
  AND ISNULL(r.IsActive, 0) = 1
  AND r.RoleName IN ({string.Join(",", roleParams)})
ORDER BY FullName, UserName;";

        var result = new List<ReviewerOption>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        for (var i = 0; i < roles.Count; i++) cmd.Parameters.AddWithValue("@Role" + i, roles[i]);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(new ReviewerOption
            {
                LabUserId = r.GetInt32(r.GetOrdinal("LabUserID")),
                UserName = r.GetString(r.GetOrdinal("UserName")),
                FullName = r.GetString(r.GetOrdinal("FullName")),
                Email = r.GetString(r.GetOrdinal("Email"))
            });
        }
        return result;
    }

    public async Task<IEnumerable<ReviewerOption>> GetUsersByRoleNamesAsync(IEnumerable<string> roleNames, int labId)
    {
        var roles = roleNames?.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).ToList() ?? new List<string>();
        if (roles.Count == 0 || labId <= 0) return Array.Empty<ReviewerOption>();

        var roleParams = roles.Select((_, i) => "@Role" + i).ToList();
        var sql = $@"
SELECT DISTINCT
    u.LabUserID,
    ISNULL(u.UserName, '') AS UserName,
    LTRIM(RTRIM(CONCAT(ISNULL(u.FirstName, ''), ' ', ISNULL(u.LastName, '')))) AS FullName,
    ISNULL(u.Email, '') AS Email
FROM dbo.LabUsers u
INNER JOIN dbo.UserRoles ur ON ur.LabUserID = u.LabUserID
INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID
INNER JOIN dbo.UserLabs ul ON ul.LabUserID = u.LabUserID
WHERE ISNULL(u.IsActive, 0) = 1
  AND ISNULL(r.IsActive, 0) = 1
  AND ul.LabId = @LabId
  AND r.RoleName IN ({string.Join(",", roleParams)})
ORDER BY FullName, UserName;";

        var result = new List<ReviewerOption>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabId", labId);
        for (var i = 0; i < roles.Count; i++) cmd.Parameters.AddWithValue("@Role" + i, roles[i]);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(new ReviewerOption
            {
                LabUserId = r.GetInt32(r.GetOrdinal("LabUserID")),
                UserName = r.GetString(r.GetOrdinal("UserName")),
                FullName = r.GetString(r.GetOrdinal("FullName")),
                Email = r.GetString(r.GetOrdinal("Email"))
            });
        }
        return result;
    }

    public async Task<IEnumerable<LabMetricsDashboard.Models.Lab>> GetAllLabsAsync()
    {
        const string sql = @"SELECT LabId, LabName, IsActive, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
                              FROM dbo.Labs ORDER BY LabName";
        var result = new List<LabMetricsDashboard.Models.Lab>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(MapLab(r));
        }
        return result;
    }

    // ?? Lab management (LabMaster) ?????????????????????????????????
    public async Task<LabMetricsDashboard.Models.Lab?> GetLabByIdAsync(int labId)
    {
        const string sql = @"SELECT LabId, LabName, IsActive, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
                              FROM dbo.Labs WHERE LabId = @LabId";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabId", labId);
        await using var r = await cmd.ExecuteReaderAsync();
        return await r.ReadAsync() ? MapLab(r) : null;
    }

    public async Task<LabMetricsDashboard.Models.Lab?> GetLabByNameAsync(string labName)
    {
        if (string.IsNullOrWhiteSpace(labName)) return null;
        const string sql = @"SELECT LabId, LabName, IsActive, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
                              FROM dbo.Labs WHERE LTRIM(RTRIM(LabName)) = LTRIM(RTRIM(@LabName))";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabName", labName);
        await using var r = await cmd.ExecuteReaderAsync();
        return await r.ReadAsync() ? MapLab(r) : null;
    }

    public async Task<int> CreateLabAsync(LabMetricsDashboard.Models.Lab lab)
    {
        const string sql = @"INSERT INTO dbo.Labs (LabName, IsActive, CreatedBy, CreatedDate)
                             VALUES (@LabName, @IsActive, @CreatedBy, SYSUTCDATETIME());
                             SELECT CONVERT(INT, SCOPE_IDENTITY());";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabName", lab.LabName?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@IsActive", lab.IsActive);
        cmd.Parameters.AddWithValue("@CreatedBy", (object?)lab.CreatedBy ?? DBNull.Value);
        var result = await cmd.ExecuteScalarAsync();
        return Convert.ToInt32(result);
    }

    public async Task UpdateLabAsync(LabMetricsDashboard.Models.Lab lab)
    {
        const string sql = @"UPDATE dbo.Labs SET
                                LabName     = @LabName,
                                IsActive    = @IsActive,
                                ModifiedBy  = @ModifiedBy,
                                ModifiedDate = SYSUTCDATETIME()
                             WHERE LabId = @LabId";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabName", lab.LabName?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@IsActive", lab.IsActive);
        cmd.Parameters.AddWithValue("@ModifiedBy", (object?)lab.ModifiedBy ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LabId", lab.LabId);
        await cmd.ExecuteNonQueryAsync();
    }

    private static LabMetricsDashboard.Models.Lab MapLab(System.Data.Common.DbDataReader r)
    {
        return new LabMetricsDashboard.Models.Lab
        {
            LabId        = r.GetInt32(r.GetOrdinal("LabId")),
            LabName      = r.IsDBNull(r.GetOrdinal("LabName")) ? string.Empty : r.GetString(r.GetOrdinal("LabName")),
            IsActive     = SafeGetBool(r, "IsActive", true),
            CreatedBy    = SafeGetString(r, "CreatedBy"),
            CreatedDate  = SafeGetDateTime(r, "CreatedDate"),
            ModifiedBy   = SafeGetString(r, "ModifiedBy"),
            ModifiedDate = SafeGetDateTime(r, "ModifiedDate")
        };
    }

    private static bool SafeGetBool(System.Data.Common.DbDataReader r, string column, bool defaultValue)
    {
        try
        {
            var ord = r.GetOrdinal(column);
            return r.IsDBNull(ord) ? defaultValue : r.GetBoolean(ord);
        }
        catch (IndexOutOfRangeException) { return defaultValue; }
    }

    private static string? SafeGetString(System.Data.Common.DbDataReader r, string column)
    {
        try
        {
            var ord = r.GetOrdinal(column);
            return r.IsDBNull(ord) ? null : r.GetString(ord);
        }
        catch (IndexOutOfRangeException) { return null; }
    }

    private static DateTime? SafeGetDateTime(System.Data.Common.DbDataReader r, string column)
    {
        try
        {
            var ord = r.GetOrdinal(column);
            return r.IsDBNull(ord) ? (DateTime?)null : r.GetDateTime(ord);
        }
        catch (IndexOutOfRangeException) { return null; }
    }

    public async Task<IEnumerable<UserLab>> GetUserLabsAsync(int labUserId)
    {
        // Join with Labs table to include LabName for display
        const string sql = @"SELECT ul.ULID, ul.LabId, ul.LabUserID, l.LabName
                             FROM dbo.UserLabs ul
                             LEFT JOIN dbo.Labs l ON l.LabId = ul.LabId
                             WHERE ul.LabUserID = @LabUserID";
        var result = new List<UserLab>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabUserID", labUserId);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(new UserLab
            {
                ULID = r.GetInt32(r.GetOrdinal("ULID")),
                LabId = r.GetInt32(r.GetOrdinal("LabId")),
                LabUserID = r.GetInt32(r.GetOrdinal("LabUserID")),
                LabName = r.IsDBNull(r.GetOrdinal("LabName")) ? string.Empty : r.GetString(r.GetOrdinal("LabName"))
            });
        }
        return result;
    }

    public async Task RemoveUserRoleAsync(int userRoleId)
    {
        const string sql = "DELETE FROM dbo.UserRoles WHERE UserRoleId = @UserRoleId";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@UserRoleId", userRoleId);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task RemoveUserLabAsync(int ulid)
    {
        const string sql = "DELETE FROM dbo.UserLabs WHERE ULID = @ULID";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@ULID", ulid);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task DeactivateUserAsync(int labUserId, string? modifiedBy = null)
    {
        const string sql = @"UPDATE dbo.LabUsers
                             SET IsActive = 0,
                                 ModifiedBy = @ModifiedBy,
                                 ModifiedDate = SYSUTCDATETIME()
                             WHERE LabUserID = @LabUserID";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabUserID", labUserId);
        cmd.Parameters.AddWithValue("@ModifiedBy", (object?)modifiedBy ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task<int> CreateUserAsync(LabUser user)
    {
        const string sql = @"INSERT INTO dbo.LabUsers
            (UserName, PasswordHash, FirstName, LastName, MiddleName, Email, Mobile, IsExternalUser, IsActive, ManagerUserID, TeamName, CreatedBy)
            VALUES (@UserName, @PasswordHash, @FirstName, @LastName, @MiddleName, @Email, @Mobile, @IsExternalUser, @IsActive, @ManagerUserID, @TeamName, @CreatedBy);
            SELECT SCOPE_IDENTITY();";

        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@UserName", user.UserName);
        // NULL for an invited user: they set the password from the invitation email (Account/SetPassword).
        cmd.Parameters.AddWithValue("@PasswordHash", string.IsNullOrEmpty(user.PasswordHash) ? DBNull.Value : user.PasswordHash);
        cmd.Parameters.AddWithValue("@FirstName", (object)user.FirstName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LastName", (object)user.LastName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@MiddleName", (object)user.MiddleName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Email", (object)user.Email ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Mobile", (object)user.Mobile ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@IsExternalUser", user.IsExternalUser);
        cmd.Parameters.AddWithValue("@IsActive", user.IsActive);
        cmd.Parameters.AddWithValue("@ManagerUserID", (object?)user.ManagerUserID ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@TeamName", (object)user.TeamName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@CreatedBy", (object)user.CreatedBy ?? DBNull.Value);

        var result = await cmd.ExecuteScalarAsync();
        return Convert.ToInt32(result);
    }

    public async Task<int> CreateRoleAsync(Role role)
    {
        const string sql = @"INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy)
            VALUES (@RoleName, @IsActive, @CreatedBy); SELECT SCOPE_IDENTITY();";

        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@RoleName", role.RoleName);
        cmd.Parameters.AddWithValue("@IsActive", role.IsActive);
        cmd.Parameters.AddWithValue("@CreatedBy", (object)role.CreatedBy ?? DBNull.Value);

        var result = await cmd.ExecuteScalarAsync();
        return Convert.ToInt32(result);
    }

    public async Task AssignRoleAsync(int labUserId, int roleId)
    {
        const string sql = @"INSERT INTO dbo.UserRoles (LabUserID, RoleID) VALUES (@LabUserID, @RoleID);";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabUserID", labUserId);
        cmd.Parameters.AddWithValue("@RoleID", roleId);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task AssignUserLabAsync(UserLab userLab)
    {
        const string sql = @"INSERT INTO dbo.UserLabs (LabId, LabUserID) VALUES (@LabId, @LabUserID);";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabId", userLab.LabId);
        cmd.Parameters.AddWithValue("@LabUserID", userLab.LabUserID);
        await cmd.ExecuteNonQueryAsync();
    }

    // Every LabUsers read goes through these two, so a new column cannot reach one query and not
    // another. ManagerUserID / TeamName must stay: Admin > Edit reads a user and writes them back.
    // PasswordHash is selected only by the login lookup (GetUserByUserNameAsync).
    private const string UserColumns = @"LabUserID, UserName, FirstName, LastName, MiddleName, Email, Mobile,
        IsExternalUser, IsActive, ManagerUserID, TeamName,
        AuthProvider, EntraObjectId, EntraTenantId, FailedLoginCount, LockoutEndUtc, SecurityStamp, LastLoginUtc";

    private static LabUser MapUser(SqlDataReader r)
    {
        string S(string c) { var o = r.GetOrdinal(c); return r.IsDBNull(o) ? string.Empty : r.GetString(o); }
        Guid? G(string c) { var o = r.GetOrdinal(c); return r.IsDBNull(o) ? null : r.GetGuid(o); }
        DateTime? D(string c) { var o = r.GetOrdinal(c); return r.IsDBNull(o) ? null : r.GetDateTime(o); }

        return new LabUser
        {
            LabUserID        = r.GetInt32(r.GetOrdinal("LabUserID")),
            UserName         = S("UserName"),
            PasswordHash     = SafeGetString(r, "PasswordHash") ?? string.Empty,
            FirstName        = S("FirstName"),
            LastName         = S("LastName"),
            MiddleName       = S("MiddleName"),
            Email            = S("Email"),
            Mobile           = S("Mobile"),
            IsExternalUser   = r.GetBoolean(r.GetOrdinal("IsExternalUser")),
            IsActive         = r.GetBoolean(r.GetOrdinal("IsActive")),
            ManagerUserID    = r.IsDBNull(r.GetOrdinal("ManagerUserID")) ? null : r.GetInt32(r.GetOrdinal("ManagerUserID")),
            TeamName         = S("TeamName"),
            AuthProvider     = S("AuthProvider") is { Length: > 0 } provider ? provider : "Local",
            EntraObjectId    = G("EntraObjectId"),
            EntraTenantId    = G("EntraTenantId"),
            FailedLoginCount = r.GetInt32(r.GetOrdinal("FailedLoginCount")),
            LockoutEndUtc    = D("LockoutEndUtc"),
            SecurityStamp    = r.GetGuid(r.GetOrdinal("SecurityStamp")),
            LastLoginUtc     = D("LastLoginUtc")
        };
    }

    public async Task<IEnumerable<LabUser>> GetAllUsersAsync()
    {
        var sql = $"SELECT {UserColumns} FROM dbo.LabUsers ORDER BY UserName";
        var result = new List<LabUser>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(MapUser(r));
        }

        return result;
    }

    public async Task<IEnumerable<Role>> GetAllRolesAsync()
    {
        const string sql = "SELECT RoleID, RoleName, IsActive FROM dbo.Roles ORDER BY RoleName";
        var result = new List<Role>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(new Role
            {
                RoleID = r.GetInt32(r.GetOrdinal("RoleID")),
                RoleName = r.GetString(r.GetOrdinal("RoleName")),
                IsActive = r.GetBoolean(r.GetOrdinal("IsActive"))
            });
        }

        return result;
    }

    public async Task<LabUser?> GetUserByIdAsync(int labUserId)
    {
        var sql = $"SELECT {UserColumns} FROM dbo.LabUsers WHERE LabUserID = @LabUserID";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabUserID", labUserId);
        await using var r = await cmd.ExecuteReaderAsync();
        return await r.ReadAsync() ? MapUser(r) : null;
    }

    public async Task<LabUser?> GetUserByUserNameAsync(string userName)
    {
        if (string.IsNullOrWhiteSpace(userName)) return null;
        var sql = $"SELECT {UserColumns}, PasswordHash FROM dbo.LabUsers WHERE UserName = @UserName";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@UserName", userName);
        await using var r = await cmd.ExecuteReaderAsync();
        return await r.ReadAsync() ? MapUser(r) : null;
    }

    public async Task<LabUser?> GetUserByEntraObjectIdAsync(Guid objectId)
    {
        var sql = $"SELECT {UserColumns} FROM dbo.LabUsers WHERE EntraObjectId = @Oid";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@Oid", SqlDbType.UniqueIdentifier).Value = objectId;
        await using var r = await cmd.ExecuteReaderAsync();
        return await r.ReadAsync() ? MapUser(r) : null;
    }

    public async Task<LabUser> GetOrCreateEntraUserAsync(Guid objectId, Guid tenantId, string upn, string? email, string? displayName)
    {
        // A new Microsoft user starts active with NO roles and NO labs, so they stop at Access pending
        // until an administrator assigns them - or links them to their existing local account. When a
        // local account already uses the UPN as its UserName, the new row is suffixed so both can exist
        // until that link is made.
        const string sql = @"
DECLARE @Name NVARCHAR(200) = @UserName;
IF EXISTS (SELECT 1 FROM dbo.LabUsers WHERE UserName = @Name) SET @Name = LEFT(@Name, 188) + N' (Microsoft)';
INSERT INTO dbo.LabUsers (UserName, PasswordHash, FirstName, LastName, Email, IsExternalUser, IsActive,
                          CreatedBy, AuthProvider, EntraObjectId, EntraTenantId)
VALUES (@Name, NULL, @FirstName, @LastName, @Email, 0, 1, N'EntraAutoProvision', 'Entra', @Oid, @Tid);";

        var parts = (displayName ?? string.Empty).Trim().Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        var mail = string.IsNullOrWhiteSpace(email) ? upn : email.Trim();
        try
        {
            await using var conn = new SqlConnection(_conn);
            await conn.OpenAsync();
            await using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.Add("@UserName", SqlDbType.NVarChar, 200).Value = Truncate(upn, 200);
            cmd.Parameters.Add("@FirstName", SqlDbType.NVarChar, 200).Value = (object?)Truncate(parts.ElementAtOrDefault(0), 200) ?? DBNull.Value;
            cmd.Parameters.Add("@LastName", SqlDbType.NVarChar, 200).Value = (object?)Truncate(parts.ElementAtOrDefault(1), 200) ?? DBNull.Value;
            cmd.Parameters.Add("@Email", SqlDbType.NVarChar, 255).Value = (object?)Truncate(mail, 255) ?? DBNull.Value;
            cmd.Parameters.Add("@Oid", SqlDbType.UniqueIdentifier).Value = objectId;
            cmd.Parameters.Add("@Tid", SqlDbType.UniqueIdentifier).Value = tenantId;
            await cmd.ExecuteNonQueryAsync();
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            // Two first sign-ins raced and the other request created the row: read that one.
        }

        return await GetUserByEntraObjectIdAsync(objectId)
            ?? throw new InvalidOperationException($"Microsoft user {objectId} could not be provisioned.");
    }

    public Task RecordFailedLoginAsync(int labUserId, int maxAttempts, int lockoutMinutes) => ExecAsync(
        // Right-hand values are the pre-update ones, so both CASEs see the same count. Survives an
        // app-pool recycle, unlike the per-IP lockout kept in memory by AccountController.
        @"UPDATE dbo.LabUsers SET
              FailedLoginCount = CASE WHEN FailedLoginCount + 1 >= @Max THEN 0 ELSE FailedLoginCount + 1 END,
              LockoutEndUtc    = CASE WHEN FailedLoginCount + 1 >= @Max
                                      THEN DATEADD(MINUTE, @Minutes, SYSUTCDATETIME()) ELSE LockoutEndUtc END
          WHERE LabUserID = @Id",
        ("@Id", labUserId), ("@Max", Math.Max(1, maxAttempts)), ("@Minutes", Math.Max(1, lockoutMinutes)));

    public Task RecordSuccessfulLoginAsync(int labUserId) => ExecAsync(
        @"UPDATE dbo.LabUsers SET FailedLoginCount = 0, LockoutEndUtc = NULL, LastLoginUtc = SYSUTCDATETIME()
          WHERE LabUserID = @Id",
        ("@Id", labUserId));

    public Task WriteLoginAuditAsync(int? labUserId, string? loginValue, string provider, bool succeeded, string? reason, string? ipAddress) => ExecAsync(
        @"INSERT INTO dbo.LoginAudit (LabUserID, LoginValue, AuthProvider, Succeeded, Reason, IpAddress)
          VALUES (@Id, @Login, @Provider, @Ok, @Reason, @Ip)",
        ("@Id", (object?)labUserId ?? DBNull.Value),
        ("@Login", (object?)Truncate(loginValue, 256) ?? DBNull.Value),
        ("@Provider", provider),
        ("@Ok", succeeded),
        ("@Reason", (object?)Truncate(reason, 200) ?? DBNull.Value),
        ("@Ip", (object?)Truncate(ipAddress, 64) ?? DBNull.Value));

    public async Task LinkEntraUserAsync(int existingLabUserId, int pendingLabUserId, string linkedBy)
    {
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand("dbo.usp_LinkEntraUser", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@ExistingLabUserID", existingLabUserId);
        cmd.Parameters.AddWithValue("@PendingLabUserID", pendingLabUserId);
        cmd.Parameters.AddWithValue("@LinkedBy", Truncate(linkedBy, 100) ?? "admin");
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task<UserRole?> GetUserRoleByIdAsync(int userRoleId)
    {
        const string sql = "SELECT UserRoleId, LabUserID, RoleID FROM dbo.UserRoles WHERE UserRoleId = @Id";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", userRoleId);
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync()) return null;
        return new UserRole
        {
            UserRoleId = r.GetInt32(r.GetOrdinal("UserRoleId")),
            LabUserID = r.GetInt32(r.GetOrdinal("LabUserID")),
            RoleID = r.GetInt32(r.GetOrdinal("RoleID"))
        };
    }

    public async Task<UserLab?> GetUserLabByIdAsync(int ulid)
    {
        const string sql = "SELECT ULID, LabId, LabUserID FROM dbo.UserLabs WHERE ULID = @Id";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", ulid);
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync()) return null;
        return new UserLab
        {
            ULID = r.GetInt32(r.GetOrdinal("ULID")),
            LabId = r.GetInt32(r.GetOrdinal("LabId")),
            LabUserID = r.GetInt32(r.GetOrdinal("LabUserID"))
        };
    }

    private async Task ExecAsync(string sql, params (string Name, object Value)[] parameters)
    {
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        foreach (var (name, value) in parameters) cmd.Parameters.AddWithValue(name, value);
        await cmd.ExecuteNonQueryAsync();
    }

    private static string? Truncate(string? value, int max) => value is null || value.Length <= max ? value : value[..max];

    public async Task UpdateUserAsync(LabUser user, string? passwordHash = null)
    {
        var sql = @"UPDATE dbo.LabUsers SET
            UserName = @UserName,
            FirstName = @FirstName,
            LastName = @LastName,
            MiddleName = @MiddleName,
            Email = @Email,
            Mobile = @Mobile,
            IsExternalUser = @IsExternalUser,
            IsActive = @IsActive,
            ManagerUserID = @ManagerUserID,
            TeamName = @TeamName,
            ModifiedDate = SYSUTCDATETIME(),
            ModifiedBy = @ModifiedBy";

        if (!string.IsNullOrEmpty(passwordHash))
        {
            // Never gives a Microsoft (Entra) account a password, and ends the user's other sessions
            // at their next cookie re-validation.
            sql += @", PasswordHash = CASE WHEN AuthProvider = 'Local' THEN @PasswordHash ELSE PasswordHash END,
                     SecurityStamp = CASE WHEN AuthProvider = 'Local' THEN NEWID() ELSE SecurityStamp END,
                     FailedLoginCount = 0, LockoutEndUtc = NULL";
        }

        sql += " WHERE LabUserID = @LabUserID";

        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@UserName", user.UserName);
        cmd.Parameters.AddWithValue("@FirstName", (object)user.FirstName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LastName", (object)user.LastName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@MiddleName", (object)user.MiddleName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Email", (object)user.Email ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Mobile", (object)user.Mobile ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@IsExternalUser", user.IsExternalUser);
        cmd.Parameters.AddWithValue("@IsActive", user.IsActive);
        cmd.Parameters.AddWithValue("@ManagerUserID", (object?)user.ManagerUserID ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@TeamName", (object)user.TeamName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ModifiedBy", (object)user.ModifiedBy ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LabUserID", user.LabUserID);
        if (!string.IsNullOrEmpty(passwordHash))
        {
            cmd.Parameters.AddWithValue("@PasswordHash", passwordHash);
        }

        await cmd.ExecuteNonQueryAsync();
    }

    public async Task<IEnumerable<AnalystManagerTeam>> GetAnalystManagerTeamMapAsync()
    {
        const string sql = @"
            SELECT u.UserName, ISNULL(m.UserName, '') AS ManagerUserName, ISNULL(u.TeamName, '') AS TeamName
            FROM dbo.LabUsers u
            LEFT JOIN dbo.LabUsers m ON m.LabUserID = u.ManagerUserID
            WHERE u.IsActive = 1;";

        var result = new List<AnalystManagerTeam>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(new AnalystManagerTeam
            {
                UserName = r.GetString(r.GetOrdinal("UserName")),
                ManagerUserName = r.GetString(r.GetOrdinal("ManagerUserName")),
                TeamName = r.GetString(r.GetOrdinal("TeamName"))
            });
        }

        return result;
    }
}
