using System.Data;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>An open first-login invitation, as the set-password page needs it.</summary>
public sealed record UserInvitation(long InvitationId, int LabUserId, string UserName, string OtpHash, int FailedAttempts);

public enum SetPasswordOutcome { Ok, InvalidLink, WrongOtp, TooManyAttempts }

/// <summary>
/// First-login invitations created by AR Workbench User Management (LRN.ReportsApi,
/// dbo.UserInvitation in LRNMaster). The link token is matched by its SHA-256 hash and the
/// one-time password by PBKDF2, both exactly as LRN.ReportsApi UserInvitationService
/// stores them.
/// </summary>
public interface IUserInvitationRepository
{
    /// <summary>The open (unused, unrevoked, unexpired) invitation for an active user, or null.</summary>
    Task<UserInvitation?> FindOpenAsync(string token);
    Task<SetPasswordOutcome> CompleteAsync(string token, string otp, string newPasswordHash, IPasswordHasher hasher);
}

public sealed class SqlUserInvitationRepository : IUserInvitationRepository
{
    public const int MaxOtpAttempts = 5;
    private readonly string _conn;

    public SqlUserInvitationRepository(IConfiguration cfg)
    {
        _conn = cfg.GetConnectionString("DefaultConnection") ?? throw new ArgumentException("DefaultConnection not configured");
    }

    /// <summary>Must match LRN.ReportsApi UserInvitationService.HashToken.</summary>
    public static string HashToken(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    private const string OpenSql = @"
SELECT TOP (1) i.InvitationId, i.LabUserID, u.UserName, i.OtpHash, i.FailedAttempts
FROM dbo.UserInvitation i {0}
INNER JOIN dbo.LabUsers u ON u.LabUserID = i.LabUserID
WHERE i.TokenHash = @Token AND i.UsedUtc IS NULL AND i.RevokedUtc IS NULL
  AND i.ExpiresUtc > SYSUTCDATETIME() AND ISNULL(u.IsActive, 0) = 1;";

    public async Task<UserInvitation?> FindOpenAsync(string token)
    {
        if (string.IsNullOrWhiteSpace(token) || token.Length > 200) return null;
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand(string.Format(OpenSql, string.Empty), conn);
        cmd.Parameters.Add("@Token", SqlDbType.Char, 64).Value = HashToken(token);
        await using var r = await cmd.ExecuteReaderAsync();
        return await r.ReadAsync() ? Read(r) : null;
    }

    public async Task<SetPasswordOutcome> CompleteAsync(string token, string otp, string newPasswordHash, IPasswordHasher hasher)
    {
        if (string.IsNullOrWhiteSpace(token) || token.Length > 200) return SetPasswordOutcome.InvalidLink;
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(IsolationLevel.ReadCommitted);

        // UPDLOCK: two submits of the same link cannot both pass the OTP check.
        UserInvitation? invite;
        await using (var read = new SqlCommand(string.Format(OpenSql, "WITH (UPDLOCK, ROWLOCK)"), conn, tx))
        {
            read.Parameters.Add("@Token", SqlDbType.Char, 64).Value = HashToken(token);
            await using var r = await read.ExecuteReaderAsync();
            invite = await r.ReadAsync() ? Read(r) : null;
        }
        if (invite is null)
        {
            await tx.RollbackAsync();
            return SetPasswordOutcome.InvalidLink;
        }

        if (!hasher.Verify(invite.OtpHash, (otp ?? string.Empty).Trim().ToUpperInvariant()))
        {
            var attempts = invite.FailedAttempts + 1;
            await using var fail = new SqlCommand(@"
UPDATE dbo.UserInvitation
SET FailedAttempts = @Attempts, RevokedUtc = CASE WHEN @Attempts >= @Max THEN SYSUTCDATETIME() ELSE RevokedUtc END
WHERE InvitationId = @Id;", conn, tx);
            fail.Parameters.Add("@Attempts", SqlDbType.Int).Value = attempts;
            fail.Parameters.Add("@Max", SqlDbType.Int).Value = MaxOtpAttempts;
            fail.Parameters.Add("@Id", SqlDbType.BigInt).Value = invite.InvitationId;
            await fail.ExecuteNonQueryAsync();
            await tx.CommitAsync();
            return attempts >= MaxOtpAttempts ? SetPasswordOutcome.TooManyAttempts : SetPasswordOutcome.WrongOtp;
        }

        await using (var done = new SqlCommand(@"
UPDATE dbo.LabUsers SET PasswordHash = @Hash, ModifiedBy = UserName, ModifiedDate = SYSUTCDATETIME() WHERE LabUserID = @UserId;
UPDATE dbo.UserInvitation SET UsedUtc = SYSUTCDATETIME() WHERE InvitationId = @Id;
UPDATE dbo.UserInvitation SET RevokedUtc = SYSUTCDATETIME()
WHERE LabUserID = @UserId AND InvitationId <> @Id AND UsedUtc IS NULL AND RevokedUtc IS NULL;", conn, tx))
        {
            done.Parameters.Add("@Hash", SqlDbType.NVarChar, 500).Value = newPasswordHash;
            done.Parameters.Add("@UserId", SqlDbType.Int).Value = invite.LabUserId;
            done.Parameters.Add("@Id", SqlDbType.BigInt).Value = invite.InvitationId;
            await done.ExecuteNonQueryAsync();
        }
        await tx.CommitAsync();
        return SetPasswordOutcome.Ok;
    }

    private static UserInvitation Read(SqlDataReader r) => new(
        r.GetInt64(0), r.GetInt32(1), r.IsDBNull(2) ? string.Empty : r.GetString(2), r.GetString(3), r.GetInt32(4));
}
