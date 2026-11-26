using System.Data;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public enum LoginCodeOutcome { Ok, WrongCode, TooManyAttempts, Expired }

/// <summary>
/// Emailed one-time sign-in codes (dbo.UserLoginOtp in LRNMaster, created by LRN.ReportsApi
/// LoginCodeService). The code is matched by PBKDF2 exactly as LabUsers.PasswordHash; a code works
/// once, for its own user only, until it expires or is replaced by a newer one.
/// </summary>
public interface ILoginCodeRepository
{
    Task<LoginCodeOutcome> VerifyAsync(long challengeId, int labUserId, string code, IPasswordHasher hasher);
}

public sealed class SqlLoginCodeRepository : ILoginCodeRepository
{
    public const int MaxAttempts = 5;
    private readonly string _conn;

    public SqlLoginCodeRepository(IConfiguration cfg)
    {
        _conn = cfg.GetConnectionString("DefaultConnection") ?? throw new ArgumentException("DefaultConnection not configured");
    }

    public async Task<LoginCodeOutcome> VerifyAsync(long challengeId, int labUserId, string code, IPasswordHasher hasher)
    {
        var typed = new string((code ?? string.Empty).Where(char.IsDigit).ToArray());
        await using var conn = new SqlConnection(_conn);
        await conn.OpenAsync();
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(IsolationLevel.ReadCommitted);

        // UPDLOCK: two submits of the same code cannot both pass.
        string? hash = null;
        var attempts = 0;
        await using (var read = new SqlCommand(@"
SELECT CodeHash, FailedAttempts FROM dbo.UserLoginOtp WITH (UPDLOCK, ROWLOCK)
WHERE LoginOtpId = @Id AND LabUserID = @UserId AND UsedUtc IS NULL AND RevokedUtc IS NULL AND ExpiresUtc > SYSUTCDATETIME();", conn, tx))
        {
            read.Parameters.Add("@Id", SqlDbType.BigInt).Value = challengeId;
            read.Parameters.Add("@UserId", SqlDbType.Int).Value = labUserId;
            await using var r = await read.ExecuteReaderAsync();
            if (await r.ReadAsync())
            {
                hash = r.GetString(0);
                attempts = r.GetInt32(1);
            }
        }
        if (hash is null)
        {
            await tx.RollbackAsync();
            return LoginCodeOutcome.Expired;
        }

        if (typed.Length == 0 || !hasher.Verify(hash, typed))
        {
            attempts++;
            await using var fail = new SqlCommand(@"
UPDATE dbo.UserLoginOtp
SET FailedAttempts = @Attempts, RevokedUtc = CASE WHEN @Attempts >= @Max THEN SYSUTCDATETIME() ELSE RevokedUtc END
WHERE LoginOtpId = @Id;", conn, tx);
            fail.Parameters.Add("@Attempts", SqlDbType.Int).Value = attempts;
            fail.Parameters.Add("@Max", SqlDbType.Int).Value = MaxAttempts;
            fail.Parameters.Add("@Id", SqlDbType.BigInt).Value = challengeId;
            await fail.ExecuteNonQueryAsync();
            await tx.CommitAsync();
            return attempts >= MaxAttempts ? LoginCodeOutcome.TooManyAttempts : LoginCodeOutcome.WrongCode;
        }

        await using (var done = new SqlCommand("UPDATE dbo.UserLoginOtp SET UsedUtc = SYSUTCDATETIME() WHERE LoginOtpId = @Id;", conn, tx))
        {
            done.Parameters.Add("@Id", SqlDbType.BigInt).Value = challengeId;
            await done.ExecuteNonQueryAsync();
        }
        await tx.CommitAsync();
        return LoginCodeOutcome.Ok;
    }
}
