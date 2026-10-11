using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.UserMail;

/// <summary>The user an invitation is for, with the role and lab names the email shows.</summary>
public sealed record UserMailTarget(int LabUserId, string UserName, string? Email, bool IsActive,
    IReadOnlyList<string> RoleNames, IReadOnlyList<int> LabIds, IReadOnlyList<string> LabNames);

/// <summary>dbo.EmailLog.EmailType values written by this API. The log accepts any type.</summary>
public static class EmailTypes
{
    public const string UserInvitation = "UserInvitation";
    public const string UserInvitationResend = "UserInvitationResend";
    public const string DenialWorkflowSupport = "DenialWorkflowSupport";
    public const string DenialWorkflowNotification = "DenialWorkflowNotification";
    public const string PayerMasterNotification = "PayerMasterNotification";
}

public sealed class UserEmailLogQuery
{
    public string? Search { get; set; }
    public int? RoleId { get; set; }
    /// <summary>Sent | Failed</summary>
    public string? Status { get; set; }
    /// <summary>LRN Metrics | AR Workbench | Denial Workflow | Payer Master</summary>
    public string? Application { get; set; }
    /// <summary>One or more dbo.EmailLog.EmailType values (?emailType=A&amp;emailType=B).</summary>
    public List<string>? EmailType { get; set; }
    public int? LabUserId { get; set; }
    /// <summary>Sent on or after this date (UTC).</summary>
    public DateTime? From { get; set; }
    /// <summary>Sent before the end of this date (UTC).</summary>
    public DateTime? To { get; set; }
    /// <summary>sent (default) | type | application | to | user | subject | status | sentBy</summary>
    public string? SortBy { get; set; }
    /// <summary>Default true: newest first.</summary>
    public bool? SortDesc { get; set; }
    /// <summary>Older clients: true = sent time ascending (same as SortBy=sent, SortDesc=false).</summary>
    public bool OldestFirst { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

/// <summary>One mail type in the log, for the type filter.</summary>
public sealed class EmailTypeSummary
{
    public string EmailType { get; set; } = string.Empty;
    public int Total { get; set; }
    public int Failed { get; set; }
    public DateTime? LastSentUtc { get; set; }
}

public sealed class UserEmailLogRow
{
    public long EmailLogId { get; set; }
    public DateTime CreatedUtc { get; set; }
    public int? LabUserId { get; set; }
    public string? UserName { get; set; }
    public string? FullName { get; set; }
    public string? Roles { get; set; }
    public string Application { get; set; } = string.Empty;
    public string EmailType { get; set; } = string.Empty;
    public string ToAddress { get; set; } = string.Empty;
    public string Subject { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string? ErrorMessage { get; set; }
    public string? SentBy { get; set; }
    /// <summary>False when the user has since been deleted.</summary>
    public bool UserExists { get; set; }
}

public sealed class UserEmailLogPage
{
    public List<UserEmailLogRow> Rows { get; set; } = new();
    public int Total { get; set; }
    public int Page { get; set; }
    public int PageSize { get; set; }
    /// <summary>False until Sql/UserMail_Setup.sql has been run.</summary>
    public bool Installed { get; set; } = true;
}

public sealed class UserEmailDetail
{
    public UserEmailLogRow Email { get; set; } = new();
    /// <summary>The message as sent, with the one-time password and link removed.</summary>
    public string? BodyHtml { get; set; }
}

public interface IUserMailRepository
{
    Task<UserMailTarget?> GetTargetAsync(int labUserId, CancellationToken ct);
    Task CreateInvitationAsync(int labUserId, string application, string tokenHash, string otpHash, DateTime expiresUtc, string createdBy, CancellationToken ct);
    Task WriteEmailLogAsync(int? labUserId, string? userName, string application, string emailType, string toAddress, string? fromAddress,
        string subject, string? bodyHtml, bool sent, string? error, string? sentBy, CancellationToken ct);
    Task<Dictionary<int, ArWorkbenchInviteStatus>> GetInviteStatusesAsync(IReadOnlyCollection<int> labUserIds, CancellationToken ct);
    /// <param name="labIds">Only users with one of these labs; null = every email (full admins).</param>
    Task<UserEmailLogPage> GetEmailLogAsync(UserEmailLogQuery query, IReadOnlyCollection<int>? labIds, CancellationToken ct);
    Task<UserEmailDetail?> GetEmailAsync(long emailLogId, IReadOnlyCollection<int>? labIds, CancellationToken ct);
    /// <summary>Every mail type in the log with its counts, for the type filter.</summary>
    Task<IReadOnlyList<EmailTypeSummary>> GetEmailTypesAsync(IReadOnlyCollection<int>? labIds, CancellationToken ct);
}

/// <summary>dbo.UserInvitation / dbo.EmailLog in LRNMaster (Sql/UserMail_Setup.sql).</summary>
public sealed class SqlUserMailRepository : IUserMailRepository
{
    private readonly string _master;

    public SqlUserMailRepository(IConfiguration configuration)
    {
        _master = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");
    }

    private async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var conn = new SqlConnection(_master);
        await conn.OpenAsync(ct);
        return conn;
    }

    public async Task<UserMailTarget?> GetTargetAsync(int labUserId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
SELECT UserName, Email, CAST(ISNULL(IsActive, 0) AS bit) FROM dbo.LabUsers WHERE LabUserID = @Id;
SELECT r.RoleName FROM dbo.UserRoles ur INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID WHERE ur.LabUserID = @Id ORDER BY r.RoleName;
SELECT DISTINCT ul.LabId, COALESCE(l.LabName, CONCAT(N'Lab ', ul.LabId))
FROM dbo.UserLabs ul LEFT JOIN dbo.Labs l ON l.LabId = ul.LabId
WHERE ul.LabUserID = @Id;", conn);
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        var userName = r.IsDBNull(0) ? string.Empty : r.GetString(0);
        var email = r.IsDBNull(1) ? null : r.GetString(1);
        var active = r.GetBoolean(2);
        var roles = new List<string>();
        var labIds = new List<int>();
        var labNames = new List<string>();
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) roles.Add(r.GetString(0));
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) { labIds.Add(r.GetInt32(0)); labNames.Add(r.GetString(1)); }
        return new UserMailTarget(labUserId, userName, email, active, roles, labIds, labNames.OrderBy(n => n).ToList());
    }

    public async Task CreateInvitationAsync(int labUserId, string application, string tokenHash, string otpHash, DateTime expiresUtc, string createdBy, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
UPDATE dbo.UserInvitation SET RevokedUtc = SYSUTCDATETIME()
WHERE LabUserID = @Id AND UsedUtc IS NULL AND RevokedUtc IS NULL;
INSERT INTO dbo.UserInvitation (LabUserID, Application, TokenHash, OtpHash, ExpiresUtc, CreatedBy)
VALUES (@Id, @App, @Token, @Otp, @Expires, @By);", conn);
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = labUserId;
        cmd.Parameters.Add("@App", SqlDbType.NVarChar, 50).Value = application;
        cmd.Parameters.Add("@Token", SqlDbType.Char, 64).Value = tokenHash;
        cmd.Parameters.Add("@Otp", SqlDbType.NVarChar, 200).Value = otpHash;
        cmd.Parameters.Add("@Expires", SqlDbType.DateTime2).Value = expiresUtc;
        cmd.Parameters.Add("@By", SqlDbType.NVarChar, 100).Value = Truncate(createdBy, 100);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task WriteEmailLogAsync(int? labUserId, string? userName, string application, string emailType, string toAddress, string? fromAddress,
        string subject, string? bodyHtml, bool sent, string? error, string? sentBy, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
INSERT INTO dbo.EmailLog (LabUserID, UserName, Application, EmailType, ToAddress, FromAddress, Subject, BodyHtml, Status, ErrorMessage, SentBy)
VALUES (@Id, @UserName, @App, @Type, @To, @From, @Subject, @Body, @Status, @Error, @By);", conn);
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = (object?)labUserId ?? DBNull.Value;
        cmd.Parameters.Add("@UserName", SqlDbType.NVarChar, 256).Value = (object?)userName ?? DBNull.Value;
        cmd.Parameters.Add("@App", SqlDbType.NVarChar, 50).Value = application;
        cmd.Parameters.Add("@Type", SqlDbType.NVarChar, 50).Value = emailType;
        cmd.Parameters.Add("@To", SqlDbType.NVarChar, 1000).Value = Truncate(toAddress, 1000);
        cmd.Parameters.Add("@From", SqlDbType.NVarChar, 256).Value = (object?)fromAddress ?? DBNull.Value;
        cmd.Parameters.Add("@Subject", SqlDbType.NVarChar, 400).Value = Truncate(subject, 400);
        cmd.Parameters.Add("@Body", SqlDbType.NVarChar, -1).Value = (object?)bodyHtml ?? DBNull.Value;
        cmd.Parameters.Add("@Status", SqlDbType.VarChar, 20).Value = sent ? "Sent" : "Failed";
        cmd.Parameters.Add("@Error", SqlDbType.NVarChar, 2000).Value = error is null ? DBNull.Value : Truncate(error, 2000);
        cmd.Parameters.Add("@By", SqlDbType.NVarChar, 100).Value = sentBy is null ? DBNull.Value : Truncate(sentBy, 100);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<Dictionary<int, ArWorkbenchInviteStatus>> GetInviteStatusesAsync(IReadOnlyCollection<int> labUserIds, CancellationToken ct)
    {
        var result = new Dictionary<int, ArWorkbenchInviteStatus>();
        if (labUserIds.Count == 0) return result;
        await using var conn = await OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.EmailLog', N'U') IS NULL OR OBJECT_ID(N'dbo.UserInvitation', N'U') IS NULL
BEGIN
    SELECT CAST(NULL AS int), CAST(NULL AS varchar(20)), CAST(NULL AS datetime2), CAST(NULL AS datetime2), CAST(NULL AS bit) WHERE 1 = 0;
    RETURN;
END;
SELECT u.LabUserID, m.Status, m.CreatedUtc, i.UsedUtc,
       CAST(CASE WHEN u.PasswordHash IS NULL OR u.PasswordHash = N'' THEN 0 ELSE 1 END AS bit)
FROM dbo.LabUsers u
OUTER APPLY (SELECT TOP (1) Status, CreatedUtc FROM dbo.EmailLog e WHERE e.LabUserID = u.LabUserID ORDER BY e.CreatedUtc DESC, e.EmailLogId DESC) m
OUTER APPLY (SELECT TOP (1) UsedUtc FROM dbo.UserInvitation x WHERE x.LabUserID = u.LabUserID AND x.UsedUtc IS NOT NULL ORDER BY x.UsedUtc DESC) i
WHERE u.LabUserID IN (SELECT TRY_CAST(value AS int) FROM STRING_SPLIT(@Ids, ','));", conn);
        cmd.Parameters.Add("@Ids", SqlDbType.NVarChar, -1).Value = string.Join(",", labUserIds);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            result[r.GetInt32(0)] = new ArWorkbenchInviteStatus
            {
                LastEmailStatus = r.IsDBNull(1) ? null : r.GetString(1),
                LastEmailUtc = r.IsDBNull(2) ? null : r.GetDateTime(2),
                AcceptedUtc = r.IsDBNull(3) ? null : r.GetDateTime(3),
                HasPassword = r.GetBoolean(4)
            };
        }
        return result;
    }

    // Shared WHERE for the list and the single-email read.
    private static string Where(SqlCommand cmd, UserEmailLogQuery? q, IReadOnlyCollection<int>? labIds)
    {
        var clauses = new List<string>();
        if (labIds is not null)
        {
            clauses.Add("EXISTS (SELECT 1 FROM dbo.UserLabs ul WHERE ul.LabUserID = e.LabUserID AND ul.LabId IN (SELECT TRY_CAST(value AS int) FROM STRING_SPLIT(@Labs, ',')))");
            cmd.Parameters.Add("@Labs", SqlDbType.NVarChar, -1).Value = labIds.Count == 0 ? "0" : string.Join(",", labIds);
        }
        if (q is null) return clauses.Count == 0 ? "1 = 1" : string.Join(" AND ", clauses);
        if (q.RoleId is > 0)
        {
            clauses.Add("EXISTS (SELECT 1 FROM dbo.UserRoles ur WHERE ur.LabUserID = e.LabUserID AND ur.RoleID = @RoleId)");
            cmd.Parameters.Add("@RoleId", SqlDbType.Int).Value = q.RoleId.Value;
        }
        if (q.LabUserId is > 0)
        {
            clauses.Add("e.LabUserID = @UserId");
            cmd.Parameters.Add("@UserId", SqlDbType.Int).Value = q.LabUserId.Value;
        }
        if (q.Status is "Sent" or "Failed")
        {
            clauses.Add("e.Status = @Status");
            cmd.Parameters.Add("@Status", SqlDbType.VarChar, 20).Value = q.Status;
        }
        if (!string.IsNullOrWhiteSpace(q.Application))
        {
            clauses.Add("e.Application = @App");
            cmd.Parameters.Add("@App", SqlDbType.NVarChar, 50).Value = q.Application.Trim();
        }
        var types = (q.EmailType ?? []).SelectMany(t => t.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Where(t => t.Length is > 0 and <= 50).Distinct(StringComparer.OrdinalIgnoreCase).Take(50).ToList();
        if (types.Count > 0)
        {
            var names = new List<string>();
            for (var i = 0; i < types.Count; i++)
            {
                names.Add($"@Type{i}");
                cmd.Parameters.Add($"@Type{i}", SqlDbType.NVarChar, 50).Value = types[i];
            }
            clauses.Add($"e.EmailType IN ({string.Join(", ", names)})");
        }
        if (q.From is { } from)
        {
            clauses.Add("e.CreatedUtc >= @From");
            cmd.Parameters.Add("@From", SqlDbType.DateTime2).Value = from.Date;
        }
        if (q.To is { } to)
        {
            clauses.Add("e.CreatedUtc < @ToExclusive");
            cmd.Parameters.Add("@ToExclusive", SqlDbType.DateTime2).Value = to.Date.AddDays(1);
        }
        if (!string.IsNullOrWhiteSpace(q.Search))
        {
            clauses.Add("(e.UserName LIKE @Search OR e.ToAddress LIKE @Search OR e.Subject LIKE @Search OR e.SentBy LIKE @Search)");
            var term = q.Search.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 300).Value = $"%{Truncate(term, 290)}%";
        }
        return clauses.Count == 0 ? "1 = 1" : string.Join(" AND ", clauses);
    }

    private const string RowColumns = @"
e.EmailLogId, e.CreatedUtc, e.LabUserID, e.UserName,
NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(u.FirstName, N''), N' ', ISNULL(u.LastName, N'')))), N''),
(SELECT STRING_AGG(r.RoleName, N', ') FROM dbo.UserRoles ur INNER JOIN dbo.Roles r ON r.RoleID = ur.RoleID WHERE ur.LabUserID = e.LabUserID),
e.Application, e.EmailType, e.ToAddress, e.Subject, e.Status, e.ErrorMessage, e.SentBy,
CAST(CASE WHEN u.LabUserID IS NULL THEN 0 ELSE 1 END AS bit)";

    private static UserEmailLogRow ReadRow(SqlDataReader r) => new()
    {
        EmailLogId = r.GetInt64(0),
        CreatedUtc = r.GetDateTime(1),
        LabUserId = r.IsDBNull(2) ? null : r.GetInt32(2),
        UserName = r.IsDBNull(3) ? null : r.GetString(3),
        FullName = r.IsDBNull(4) ? null : r.GetString(4),
        Roles = r.IsDBNull(5) ? null : r.GetString(5),
        Application = r.GetString(6),
        EmailType = r.GetString(7),
        ToAddress = r.GetString(8),
        Subject = r.GetString(9),
        Status = r.GetString(10),
        ErrorMessage = r.IsDBNull(11) ? null : r.GetString(11),
        SentBy = r.IsDBNull(12) ? null : r.GetString(12),
        UserExists = r.GetBoolean(13)
    };

    public async Task<UserEmailLogPage> GetEmailLogAsync(UserEmailLogQuery query, IReadOnlyCollection<int>? labIds, CancellationToken ct)
    {
        var page = Math.Max(1, query.Page);
        var size = Math.Clamp(query.PageSize, 10, 500);
        await using var conn = await OpenAsync(ct);
        await using var cmd = conn.CreateCommand();
        var where = Where(cmd, query, labIds);
        cmd.CommandText = $@"
IF OBJECT_ID(N'dbo.EmailLog', N'U') IS NULL
BEGIN
    SELECT CAST(-1 AS int);
    RETURN;
END;
SELECT COUNT(*) FROM dbo.EmailLog e WHERE {where};
SELECT {RowColumns}
FROM dbo.EmailLog e
LEFT JOIN dbo.LabUsers u ON u.LabUserID = e.LabUserID
WHERE {where}
ORDER BY {OrderBy(query)}
OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;";
        cmd.Parameters.Add("@Skip", SqlDbType.Int).Value = (page - 1) * size;
        cmd.Parameters.Add("@Take", SqlDbType.Int).Value = size;

        var result = new UserEmailLogPage { Page = page, PageSize = size };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) result.Total = r.GetInt32(0);
        if (result.Total < 0) return new UserEmailLogPage { Page = page, PageSize = size, Installed = false };
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) result.Rows.Add(ReadRow(r));
        return result;
    }

    public async Task<UserEmailDetail?> GetEmailAsync(long emailLogId, IReadOnlyCollection<int>? labIds, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = conn.CreateCommand();
        var where = Where(cmd, null, labIds);
        cmd.CommandText = $@"
SELECT {RowColumns}, e.BodyHtml
FROM dbo.EmailLog e
LEFT JOIN dbo.LabUsers u ON u.LabUserID = e.LabUserID
WHERE e.EmailLogId = @EmailId AND {where};";
        cmd.Parameters.Add("@EmailId", SqlDbType.BigInt).Value = emailLogId;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new UserEmailDetail { Email = ReadRow(r), BodyHtml = r.IsDBNull(14) ? null : r.GetString(14) };
    }

    // Whitelisted sort columns; the sent time (then id) always breaks ties so paging is stable.
    private static string OrderBy(UserEmailLogQuery q)
    {
        var column = (q.SortBy ?? "sent").Trim().ToLowerInvariant() switch
        {
            "type" or "emailtype" => "e.EmailType",
            "application" or "app" => "e.Application",
            "to" or "toaddress" => "e.ToAddress",
            "user" or "username" => "e.UserName",
            "subject" => "e.Subject",
            "status" => "e.Status",
            "sentby" => "e.SentBy",
            _ => null
        };
        var desc = q.SortDesc ?? !q.OldestFirst;
        var dir = desc ? "DESC" : "ASC";
        return column is null
            ? $"e.CreatedUtc {dir}, e.EmailLogId {dir}"
            : $"{column} {dir}, e.CreatedUtc DESC, e.EmailLogId DESC";
    }

    public async Task<IReadOnlyList<EmailTypeSummary>> GetEmailTypesAsync(IReadOnlyCollection<int>? labIds, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = conn.CreateCommand();
        var where = Where(cmd, null, labIds);
        cmd.CommandText = $@"
IF OBJECT_ID(N'dbo.EmailLog', N'U') IS NULL
BEGIN
    SELECT CAST(NULL AS nvarchar(50)), 0, 0, CAST(NULL AS datetime2) WHERE 1 = 0;
    RETURN;
END;
SELECT e.EmailType, COUNT(*), SUM(CASE WHEN e.Status = 'Failed' THEN 1 ELSE 0 END), MAX(e.CreatedUtc)
FROM dbo.EmailLog e
WHERE {where}
GROUP BY e.EmailType
ORDER BY e.EmailType;";
        var list = new List<EmailTypeSummary>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            list.Add(new EmailTypeSummary { EmailType = r.GetString(0), Total = r.GetInt32(1), Failed = r.GetInt32(2), LastSentUtc = r.IsDBNull(3) ? null : r.GetDateTime(3) });
        return list;
    }

    private static string Truncate(string value, int max) => value.Length <= max ? value : value[..max];
}
