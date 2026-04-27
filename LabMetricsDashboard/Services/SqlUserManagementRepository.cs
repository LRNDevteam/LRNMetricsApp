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

    public async Task<int> CreateUserAsync(LabUser user)
    {
        const string sql = @"INSERT INTO dbo.LabUsers
            (UserName, PasswordHash, FirstName, LastName, MiddleName, Email, Mobile, IsExternalUser, IsActive, CreatedBy)
            VALUES (@UserName, @PasswordHash, @FirstName, @LastName, @MiddleName, @Email, @Mobile, @IsExternalUser, @IsActive, @CreatedBy);
            SELECT SCOPE_IDENTITY();";

        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@UserName", user.UserName);
        cmd.Parameters.AddWithValue("@PasswordHash", (object)user.PasswordHash ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FirstName", (object)user.FirstName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LastName", (object)user.LastName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@MiddleName", (object)user.MiddleName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Email", (object)user.Email ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Mobile", (object)user.Mobile ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@IsExternalUser", user.IsExternalUser);
        cmd.Parameters.AddWithValue("@IsActive", user.IsActive);
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

    public async Task<IEnumerable<LabUser>> GetAllUsersAsync()
    {
        const string sql = "SELECT LabUserID, UserName, FirstName, LastName, Email, Mobile, IsExternalUser, IsActive FROM dbo.LabUsers ORDER BY UserName";
        var result = new List<LabUser>();
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            result.Add(new LabUser
            {
                LabUserID = r.GetInt32(r.GetOrdinal("LabUserID")),
                UserName = r.GetString(r.GetOrdinal("UserName")),
                FirstName = r.IsDBNull(r.GetOrdinal("FirstName")) ? string.Empty : r.GetString(r.GetOrdinal("FirstName")),
                LastName = r.IsDBNull(r.GetOrdinal("LastName")) ? string.Empty : r.GetString(r.GetOrdinal("LastName")),
                Email = r.IsDBNull(r.GetOrdinal("Email")) ? string.Empty : r.GetString(r.GetOrdinal("Email")),
                Mobile = r.IsDBNull(r.GetOrdinal("Mobile")) ? string.Empty : r.GetString(r.GetOrdinal("Mobile")),
                IsExternalUser = r.GetBoolean(r.GetOrdinal("IsExternalUser")),
                IsActive = r.GetBoolean(r.GetOrdinal("IsActive"))
            });
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
        const string sql = "SELECT LabUserID, UserName, FirstName, LastName, MiddleName, Email, Mobile, IsExternalUser, IsActive FROM dbo.LabUsers WHERE LabUserID = @LabUserID";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@LabUserID", labUserId);
        await using var r = await cmd.ExecuteReaderAsync();
        if (await r.ReadAsync())
        {
            return new LabUser
            {
                LabUserID = r.GetInt32(r.GetOrdinal("LabUserID")),
                UserName = r.GetString(r.GetOrdinal("UserName")),
                FirstName = r.IsDBNull(r.GetOrdinal("FirstName")) ? string.Empty : r.GetString(r.GetOrdinal("FirstName")),
                LastName = r.IsDBNull(r.GetOrdinal("LastName")) ? string.Empty : r.GetString(r.GetOrdinal("LastName")),
                MiddleName = r.IsDBNull(r.GetOrdinal("MiddleName")) ? string.Empty : r.GetString(r.GetOrdinal("MiddleName")),
                Email = r.IsDBNull(r.GetOrdinal("Email")) ? string.Empty : r.GetString(r.GetOrdinal("Email")),
                Mobile = r.IsDBNull(r.GetOrdinal("Mobile")) ? string.Empty : r.GetString(r.GetOrdinal("Mobile")),
                IsExternalUser = r.GetBoolean(r.GetOrdinal("IsExternalUser")),
                IsActive = r.GetBoolean(r.GetOrdinal("IsActive"))
            };
        }

        return null;
    }

    public async Task<LabUser?> GetUserByUserNameAsync(string userName)
    {
        if (string.IsNullOrWhiteSpace(userName)) return null;
        const string sql = @"SELECT LabUserID, UserName, PasswordHash, FirstName, LastName, MiddleName, Email, Mobile, IsExternalUser, IsActive
                             FROM dbo.LabUsers WHERE UserName = @UserName";
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@UserName", userName);
        await using var r = await cmd.ExecuteReaderAsync();
        if (await r.ReadAsync())
        {
            return new LabUser
            {
                LabUserID      = r.GetInt32(r.GetOrdinal("LabUserID")),
                UserName       = r.GetString(r.GetOrdinal("UserName")),
                PasswordHash   = r.IsDBNull(r.GetOrdinal("PasswordHash")) ? string.Empty : r.GetString(r.GetOrdinal("PasswordHash")),
                FirstName      = r.IsDBNull(r.GetOrdinal("FirstName")) ? string.Empty : r.GetString(r.GetOrdinal("FirstName")),
                LastName       = r.IsDBNull(r.GetOrdinal("LastName")) ? string.Empty : r.GetString(r.GetOrdinal("LastName")),
                MiddleName     = r.IsDBNull(r.GetOrdinal("MiddleName")) ? string.Empty : r.GetString(r.GetOrdinal("MiddleName")),
                Email          = r.IsDBNull(r.GetOrdinal("Email")) ? string.Empty : r.GetString(r.GetOrdinal("Email")),
                Mobile         = r.IsDBNull(r.GetOrdinal("Mobile")) ? string.Empty : r.GetString(r.GetOrdinal("Mobile")),
                IsExternalUser = r.GetBoolean(r.GetOrdinal("IsExternalUser")),
                IsActive       = r.GetBoolean(r.GetOrdinal("IsActive"))
            };
        }
        return null;
    }

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
            ModifiedDate = SYSUTCDATETIME(),
            ModifiedBy = @ModifiedBy";

        if (!string.IsNullOrEmpty(passwordHash))
        {
            sql += ", PasswordHash = @PasswordHash";
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
        cmd.Parameters.AddWithValue("@ModifiedBy", (object)user.ModifiedBy ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LabUserID", user.LabUserID);
        if (!string.IsNullOrEmpty(passwordHash))
        {
            cmd.Parameters.AddWithValue("@PasswordHash", passwordHash);
        }

        await cmd.ExecuteNonQueryAsync();
    }
}
