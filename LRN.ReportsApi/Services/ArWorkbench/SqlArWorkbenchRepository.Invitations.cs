using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>A user as User Management needs them for invite / activate / delete / password decisions.</summary>
public sealed record ArWorkbenchManageTarget(int LabUserId, string UserName, string? Email, bool IsActive,
    IReadOnlyList<string> RoleNames, IReadOnlyList<int> LabIds, bool IsMicrosoftAccount = false);

/// <summary>
/// User Management's deactivate / delete actions. Invitations and the email log are shared with LRN
/// Metrics and live in Services/UserMail (dbo.UserInvitation, dbo.UserEmailLog).
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    /// <summary>
    /// One row, one bit: whether the user in <paramref name="idExpression"/> signs in with Microsoft
    /// (dbo.LabUsers.AuthProvider = 'Entra'). Always 0 on an LRNMaster without HybridAuth_Setup.sql.
    /// </summary>
    private static string MicrosoftAccountSql(string idExpression) => $@"
IF COL_LENGTH(N'dbo.LabUsers', N'AuthProvider') IS NULL
    SELECT CAST(0 AS bit);
ELSE
    EXEC sp_executesql N'SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.LabUsers WHERE LabUserID = @Uid AND AuthProvider = ''Entra'') THEN 1 ELSE 0 END AS bit);',
        N'@Uid int', @Uid = {idExpression};";

    public async Task<ArWorkbenchManageTarget?> GetManageTargetAsync(int labUserId, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
SELECT UserName, Email, CAST(ISNULL(IsActive, 0) AS bit) FROM dbo.LabUsers WHERE LabUserID = @Id;
SELECT r.RoleName FROM dbo.UserRoles ur INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID WHERE ur.LabUserID = @Id;
SELECT DISTINCT LabId FROM dbo.UserLabs WHERE LabUserID = @Id;" + MicrosoftAccountSql("@Id"), master);
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        var userName = r.IsDBNull(0) ? string.Empty : r.GetString(0);
        var email = r.IsDBNull(1) ? null : r.GetString(1);
        var isActive = r.GetBoolean(2);
        var roles = new List<string>();
        var labs = new List<int>();
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) roles.Add(r.GetString(0));
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) labs.Add(r.GetInt32(0));
        await r.NextResultAsync(ct);
        var microsoft = await r.ReadAsync(ct) && r.GetBoolean(0);
        return new ArWorkbenchManageTarget(labUserId, userName, email, isActive, roles, labs, microsoft);
    }

    public async Task<ArWorkbenchSaveResult> SetWorkbenchUserActiveAsync(int labUserId, bool isActive, string modifiedBy, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
UPDATE dbo.LabUsers SET IsActive = @Active, ModifiedBy = @By, ModifiedDate = SYSUTCDATETIME() WHERE LabUserID = @Id;
-- A deactivated user must not be able to finish an outstanding invitation.
IF @Active = 0 AND OBJECT_ID(N'dbo.UserInvitation', N'U') IS NOT NULL
    UPDATE dbo.UserInvitation SET RevokedUtc = SYSUTCDATETIME() WHERE LabUserID = @Id AND UsedUtc IS NULL AND RevokedUtc IS NULL;", master);
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = isActive;
        cmd.Parameters.Add("@By", SqlDbType.NVarChar, 100).Value = Truncate(modifiedBy, 100);
        await cmd.ExecuteNonQueryAsync(ct);
        return ArWorkbenchSaveResult.Ok(isActive ? "User activated." : "User deactivated. They can no longer sign in.");
    }

    /// <summary>
    /// Removes the user and their roles, labs, scope and invitations. Users who report to them lose
    /// their manager. Any other table that still references the user (FK error 547) blocks the
    /// delete, and the caller is told to deactivate instead. The email log is kept.
    /// </summary>
    public async Task<ArWorkbenchSaveResult> DeleteWorkbenchUserAsync(int labUserId, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var tx = (SqlTransaction)await master.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = master.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
UPDATE dbo.LabUsers SET ManagerUserID = NULL WHERE ManagerUserID = @Id;
IF OBJECT_ID(N'dbo.ARWB_UserScope', N'U') IS NOT NULL DELETE FROM dbo.ARWB_UserScope WHERE LabUserID = @Id;
IF OBJECT_ID(N'dbo.UserInvitation', N'U') IS NOT NULL DELETE FROM dbo.UserInvitation WHERE LabUserID = @Id;
DELETE FROM dbo.UserRoles WHERE LabUserID = @Id;
DELETE FROM dbo.UserLabs WHERE LabUserID = @Id;
DELETE FROM dbo.LabUsers WHERE LabUserID = @Id;
SELECT @@ROWCOUNT;";
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        try
        {
            var deleted = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
            if (deleted == 0)
            {
                await tx.RollbackAsync(ct);
                return ArWorkbenchSaveResult.NotFound("That user no longer exists.");
            }
            await tx.CommitAsync(ct);
            return ArWorkbenchSaveResult.Ok("User deleted.");
        }
        catch (SqlException ex) when (ex.Number == 547)
        {
            await tx.RollbackAsync(ct);
            return ArWorkbenchSaveResult.Conflict("This user is referenced by other records and cannot be deleted. Deactivate the user instead.");
        }
    }
}
