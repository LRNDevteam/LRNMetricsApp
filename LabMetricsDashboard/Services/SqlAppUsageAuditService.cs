using System.Data;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public sealed class SqlAppUsageAuditService : IAppUsageAuditService
{
    private const string BrowserCookieName = "lmd.browser.id";
    private readonly string _masterConnectionString;
    private readonly ILogger<SqlAppUsageAuditService> _logger;
    private static readonly SemaphoreSlim EnsureSemaphore = new(1, 1);
    private static volatile bool _ensured;

    /// <summary>Consecutive SQL connection failure count for circuit breaker.</summary>
    private static int _consecutiveFailures;
    /// <summary>UTC time after which the circuit breaker allows the next attempt.</summary>
    private static DateTime _retryAfterUtc = DateTime.MinValue;
    /// <summary>Max back-off duration (5 minutes).</summary>
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromMinutes(5);

    public SqlAppUsageAuditService(IConfiguration configuration, ILogger<SqlAppUsageAuditService> logger)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
        _logger = logger;
    }

    /// <summary>Returns true if the circuit is open (should skip SQL calls).</summary>
    private static bool IsCircuitOpen()
        => _consecutiveFailures > 0 && DateTime.UtcNow < _retryAfterUtc;

    /// <summary>Records a successful SQL call and resets the circuit.</summary>
    private static void RecordSuccess()
    {
        _consecutiveFailures = 0;
        _retryAfterUtc = DateTime.MinValue;
    }

    /// <summary>Records a failed SQL call and sets exponential back-off.</summary>
    private void RecordFailure(Exception ex)
    {
        var failures = Interlocked.Increment(ref _consecutiveFailures);
        var delay = TimeSpan.FromSeconds(Math.Min(Math.Pow(2, failures), MaxBackoff.TotalSeconds));
        _retryAfterUtc = DateTime.UtcNow.Add(delay);

        if (failures <= 3)
        {
            _logger.LogWarning(ex,
                "Audit SQL connection failed (attempt {Count}). Next retry after {Delay:F0}s.",
                failures, delay.TotalSeconds);
        }
        else if (failures == 4)
        {
            _logger.LogWarning(
                "Audit SQL connection still failing after {Count} attempts. Suppressing further warnings until recovery.",
                failures);
        }
        // failures > 4: silent back-off, no log spam
    }

    public async Task LogPageVisitAsync(HttpContext httpContext, string pageName, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(_masterConnectionString) || IsCircuitOpen())
        {
            return;
        }

        try
        {
            await EnsureTablesAsync(cancellationToken);

            var browserId = GetOrCreateBrowserId(httpContext);
            var userName = ResolveUserName(httpContext);
            var ipAddress = ResolveIpAddress(httpContext);
            var path = httpContext.Request.Path.Value ?? string.Empty;
            var queryString = httpContext.Request.QueryString.HasValue ? httpContext.Request.QueryString.Value ?? string.Empty : string.Empty;
            var userAgent = httpContext.Request.Headers.UserAgent.ToString();

            await using var connection = new SqlConnection(_masterConnectionString);
            await connection.OpenAsync(cancellationToken);

            const string sql = @"
INSERT INTO dbo.AppUsageAudit
(
    OccurredOnUtc, UserName, BrowserId, TabId, PageName, Path, QueryString, IpAddress, UserAgent, ActivityType
)
VALUES
(
    SYSUTCDATETIME(), @UserName, @BrowserId, @TabId, @PageName, @Path, @QueryString, @IpAddress, @UserAgent, 'PageView'
);";

            await using var command = new SqlCommand(sql, connection)
            {
                CommandType = CommandType.Text,
                CommandTimeout = 30
            };

            command.Parameters.AddWithValue("@UserName", DbString(userName));
            command.Parameters.AddWithValue("@BrowserId", browserId);
            command.Parameters.AddWithValue("@TabId", DbString(httpContext.Request.Headers["X-Lmd-TabId"].ToString()));
            command.Parameters.AddWithValue("@PageName", DbString(pageName));
            command.Parameters.AddWithValue("@Path", DbString(path));
            command.Parameters.AddWithValue("@QueryString", DbString(queryString));
            command.Parameters.AddWithValue("@IpAddress", DbString(ipAddress));
            command.Parameters.AddWithValue("@UserAgent", DbString(userAgent));

            await command.ExecuteNonQueryAsync(cancellationToken);
            RecordSuccess();
        }
        catch (Exception ex)
        {
            RecordFailure(ex);
        }
    }

    public async Task TrackHeartbeatAsync(HttpContext httpContext, UsageHeartbeatRequest request, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(_masterConnectionString) || IsCircuitOpen())
        {
            return;
        }

        if (request is null)
        {
            return;
        }

        try
        {
            await EnsureTablesAsync(cancellationToken);

            var browserId = GetOrCreateBrowserId(httpContext);
            var tabId = string.IsNullOrWhiteSpace(request.TabId) ? "default" : request.TabId.Trim();
            var pageSessionId = $"{browserId}:{tabId}";
            var userName = ResolveUserName(httpContext);
            var ipAddress = ResolveIpAddress(httpContext);
            var pageName = string.IsNullOrWhiteSpace(request.PageName) ? "Unknown" : request.PageName.Trim();
            var path = string.IsNullOrWhiteSpace(request.Path) ? httpContext.Request.Headers.Referer.ToString() : request.Path.Trim();
            var queryString = request.QueryString?.Trim() ?? string.Empty;
            var userAgent = httpContext.Request.Headers.UserAgent.ToString();
            var idleSeconds = Math.Max(0, Math.Min(request.IdleSeconds, 86400));
            var lastActionUtc = DateTime.UtcNow.AddSeconds(-idleSeconds);
            var locationText = string.IsNullOrWhiteSpace(request.LocationText)
                ? (request.Latitude.HasValue && request.Longitude.HasValue ? $"{request.Latitude:0.000000}, {request.Longitude:0.000000}" : string.Empty)
                : request.LocationText.Trim();

            await using var connection = new SqlConnection(_masterConnectionString);
            await connection.OpenAsync(cancellationToken);

            const string sql = @"
MERGE dbo.AppUsagePageSession AS target
USING (SELECT @PageSessionId AS PageSessionId) AS source
ON target.PageSessionId = source.PageSessionId
WHEN MATCHED THEN
    UPDATE SET
        BrowserId = @BrowserId,
        TabId = @TabId,
        UserName = @UserName,
        PageName = @PageName,
        Path = @Path,
        QueryString = @QueryString,
        IpAddress = @IpAddress,
        UserAgent = @UserAgent,
        LastLocationText = CASE WHEN @LocationText IS NULL OR @LocationText = '' THEN target.LastLocationText ELSE @LocationText END,
        LastLatitude = COALESCE(@Latitude, target.LastLatitude),
        LastLongitude = COALESCE(@Longitude, target.LastLongitude),
        LastSeenOnUtc = SYSUTCDATETIME(),
        LastActionOnUtc = @LastActionOnUtc,
        CurrentIdleSeconds = @IdleSeconds,
        MaxIdleSeconds = CASE WHEN @IdleSeconds > ISNULL(target.MaxIdleSeconds, 0) THEN @IdleSeconds ELSE ISNULL(target.MaxIdleSeconds, 0) END
WHEN NOT MATCHED THEN
    INSERT
    (
        PageSessionId, BrowserId, TabId, UserName, PageName, Path, QueryString, IpAddress, UserAgent,
        LastLocationText, LastLatitude, LastLongitude, FirstSeenOnUtc, LastSeenOnUtc, LastActionOnUtc,
        CurrentIdleSeconds, MaxIdleSeconds
    )
    VALUES
    (
        @PageSessionId, @BrowserId, @TabId, @UserName, @PageName, @Path, @QueryString, @IpAddress, @UserAgent,
        @LocationText, @Latitude, @Longitude, SYSUTCDATETIME(), SYSUTCDATETIME(), @LastActionOnUtc,
        @IdleSeconds, @IdleSeconds
    );";

            await using var command = new SqlCommand(sql, connection)
            {
                CommandType = CommandType.Text,
                CommandTimeout = 30
            };

            command.Parameters.AddWithValue("@PageSessionId", pageSessionId);
            command.Parameters.AddWithValue("@BrowserId", browserId);
            command.Parameters.AddWithValue("@TabId", tabId);
            command.Parameters.AddWithValue("@UserName", DbString(userName));
            command.Parameters.AddWithValue("@PageName", DbString(pageName));
            command.Parameters.AddWithValue("@Path", DbString(path));
            command.Parameters.AddWithValue("@QueryString", DbString(queryString));
            command.Parameters.AddWithValue("@IpAddress", DbString(ipAddress));
            command.Parameters.AddWithValue("@UserAgent", DbString(userAgent));
            command.Parameters.AddWithValue("@LocationText", DbString(locationText));
            command.Parameters.AddWithValue("@Latitude", request.Latitude.HasValue ? request.Latitude.Value : DBNull.Value);
            command.Parameters.AddWithValue("@Longitude", request.Longitude.HasValue ? request.Longitude.Value : DBNull.Value);
            command.Parameters.AddWithValue("@LastActionOnUtc", lastActionUtc);
            command.Parameters.AddWithValue("@IdleSeconds", idleSeconds);

            await command.ExecuteNonQueryAsync(cancellationToken);
            RecordSuccess();
        }
        catch (Exception ex)
        {
            RecordFailure(ex);
        }
    }

    public async Task<AppUsagePageViewModel> GetUsagePageAsync(CancellationToken cancellationToken = default)
    {
        var model = new AppUsagePageViewModel();
        if (string.IsNullOrWhiteSpace(_masterConnectionString))
        {
            return model;
        }

        await EnsureTablesAsync(cancellationToken);

        await using var connection = new SqlConnection(_masterConnectionString);
        await connection.OpenAsync(cancellationToken);

        const string metricsSql = @"
SELECT
    ActiveUsersCount = (SELECT COUNT(1) FROM dbo.AppUsagePageSession WITH(NOLOCK) WHERE LastSeenOnUtc >= DATEADD(MINUTE, -20, SYSUTCDATETIME())),
    DistinctUsers24h = (SELECT COUNT(DISTINCT COALESCE(NULLIF(UserName, ''), BrowserId)) FROM dbo.AppUsageAudit WITH(NOLOCK) WHERE OccurredOnUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())),
    TotalPageViews24h = (SELECT COUNT(1) FROM dbo.AppUsageAudit WITH(NOLOCK) WHERE OccurredOnUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME()) AND ActivityType = 'PageView');";

        await using (var metricsCommand = new SqlCommand(metricsSql, connection) { CommandType = CommandType.Text, CommandTimeout = 30 })
        await using (var reader = await metricsCommand.ExecuteReaderAsync(cancellationToken))
        {
            if (await reader.ReadAsync(cancellationToken))
            {
                model.ActiveUsersCount = reader.IsDBNull(0) ? 0 : reader.GetInt32(0);
                model.DistinctUsers24h = reader.IsDBNull(1) ? 0 : reader.GetInt32(1);
                model.TotalPageViews24h = reader.IsDBNull(2) ? 0 : reader.GetInt32(2);
            }
        }

        const string activeSql = @"
SELECT TOP (200)
    UserName,
    BrowserId,
    TabId,
    PageName,
    Path,
    IpAddress,
    ISNULL(LastLocationText, '') AS LastLocationText,
    LastLatitude,
    LastLongitude,
    ISNULL(UserAgent, '') AS UserAgent,
    FirstSeenOnUtc,
    LastSeenOnUtc,
    LastActionOnUtc,
    CASE WHEN LastActionOnUtc IS NULL THEN ISNULL(CurrentIdleSeconds, 0) ELSE DATEDIFF(SECOND, LastActionOnUtc, SYSUTCDATETIME()) END AS CurrentIdleSeconds,
    ISNULL(MaxIdleSeconds, 0) AS MaxIdleSeconds
FROM dbo.AppUsagePageSession WITH(NOLOCK)
WHERE LastSeenOnUtc >= DATEADD(MINUTE, -20, SYSUTCDATETIME())
ORDER BY LastSeenOnUtc DESC, UserName, PageName;";

        await using (var activeCommand = new SqlCommand(activeSql, connection) { CommandType = CommandType.Text, CommandTimeout = 30 })
        await using (var reader = await activeCommand.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                var idleSeconds = reader.IsDBNull(13) ? 0 : reader.GetInt32(13);
                model.ActiveUsers.Add(new CurrentUserActivityRecord
                {
                    UserName = Str(reader, 0),
                    BrowserId = Str(reader, 1),
                    TabId = Str(reader, 2),
                    PageName = Str(reader, 3),
                    Path = Str(reader, 4),
                    IpAddress = Str(reader, 5),
                    LocationText = Str(reader, 6),
                    Latitude = Dec(reader, 7),
                    Longitude = Dec(reader, 8),
                    UserAgent = Str(reader, 9),
                    FirstSeenOnUtc = Dt(reader, 10),
                    LastSeenOnUtc = Dt(reader, 11),
                    LastActionOnUtc = Ndt(reader, 12),
                    CurrentIdleSeconds = idleSeconds,
                    MaxIdleSeconds = reader.IsDBNull(14) ? 0 : reader.GetInt32(14),
                    IdleStatus = idleSeconds >= 300 ? "Idle" : "Active"
                });
            }
        }

        const string recentSql = @"
SELECT TOP (300)
    a.UsageAuditId,
    a.OccurredOnUtc,
    ISNULL(a.UserName, '') AS UserName,
    ISNULL(a.BrowserId, '') AS BrowserId,
    ISNULL(a.TabId, '') AS TabId,
    ISNULL(a.PageName, '') AS PageName,
    ISNULL(a.Path, '') AS Path,
    ISNULL(a.QueryString, '') AS QueryString,
    ISNULL(a.IpAddress, '') AS IpAddress,
    ISNULL(s.LastLocationText, '') AS LocationText,
    s.LastLatitude,
    s.LastLongitude,
    ISNULL(a.UserAgent, '') AS UserAgent,
    ISNULL(a.ActivityType, '') AS ActivityType
FROM dbo.AppUsageAudit a WITH(NOLOCK)
LEFT JOIN dbo.AppUsagePageSession s WITH(NOLOCK)
    ON a.BrowserId = s.BrowserId
   AND ISNULL(a.TabId, '') = ISNULL(s.TabId, '')
ORDER BY a.OccurredOnUtc DESC;";

        await using (var recentCommand = new SqlCommand(recentSql, connection) { CommandType = CommandType.Text, CommandTimeout = 30 })
        await using (var reader = await recentCommand.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                model.RecentActivity.Add(new AppUsageActivityRecord
                {
                    UsageAuditId = reader.GetInt64(0),
                    OccurredOnUtc = Dt(reader, 1),
                    UserName = Str(reader, 2),
                    BrowserId = Str(reader, 3),
                    TabId = Str(reader, 4),
                    PageName = Str(reader, 5),
                    Path = Str(reader, 6),
                    QueryString = Str(reader, 7),
                    IpAddress = Str(reader, 8),
                    LocationText = Str(reader, 9),
                    Latitude = Dec(reader, 10),
                    Longitude = Dec(reader, 11),
                    UserAgent = Str(reader, 12),
                    ActivityType = Str(reader, 13)
                });
            }
        }

        return model;
    }

    private async Task EnsureTablesAsync(CancellationToken cancellationToken)
    {
        if (_ensured)
        {
            return;
        }

        await EnsureSemaphore.WaitAsync(cancellationToken);
        try
        {
            if (_ensured)
            {
                return;
            }

            await using var connection = new SqlConnection(_masterConnectionString);
            await connection.OpenAsync(cancellationToken);

            const string sql = @"
IF OBJECT_ID('dbo.AppUsageAudit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AppUsageAudit
    (
        UsageAuditId BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        OccurredOnUtc DATETIME2(0) NOT NULL CONSTRAINT DF_AppUsageAudit_OccurredOnUtc DEFAULT SYSUTCDATETIME(),
        UserName NVARCHAR(256) NULL,
        BrowserId NVARCHAR(100) NOT NULL,
        TabId NVARCHAR(100) NULL,
        PageName NVARCHAR(200) NULL,
        Path NVARCHAR(400) NULL,
        QueryString NVARCHAR(1200) NULL,
        IpAddress NVARCHAR(64) NULL,
        UserAgent NVARCHAR(1000) NULL,
        ActivityType NVARCHAR(50) NULL
    );
END;

IF OBJECT_ID('dbo.AppUsagePageSession', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AppUsagePageSession
    (
        PageSessionId NVARCHAR(220) NOT NULL PRIMARY KEY,
        BrowserId NVARCHAR(100) NOT NULL,
        TabId NVARCHAR(100) NOT NULL,
        UserName NVARCHAR(256) NULL,
        PageName NVARCHAR(200) NULL,
        Path NVARCHAR(400) NULL,
        QueryString NVARCHAR(1200) NULL,
        IpAddress NVARCHAR(64) NULL,
        UserAgent NVARCHAR(1000) NULL,
        LastLocationText NVARCHAR(255) NULL,
        LastLatitude DECIMAL(9,6) NULL,
        LastLongitude DECIMAL(9,6) NULL,
        FirstSeenOnUtc DATETIME2(0) NOT NULL CONSTRAINT DF_AppUsagePageSession_FirstSeenOnUtc DEFAULT SYSUTCDATETIME(),
        LastSeenOnUtc DATETIME2(0) NOT NULL CONSTRAINT DF_AppUsagePageSession_LastSeenOnUtc DEFAULT SYSUTCDATETIME(),
        LastActionOnUtc DATETIME2(0) NULL,
        CurrentIdleSeconds INT NOT NULL CONSTRAINT DF_AppUsagePageSession_CurrentIdle DEFAULT(0),
        MaxIdleSeconds INT NOT NULL CONSTRAINT DF_AppUsagePageSession_MaxIdle DEFAULT(0)
    );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AppUsageAudit_OccurredOnUtc' AND object_id = OBJECT_ID('dbo.AppUsageAudit'))
BEGIN
    CREATE INDEX IX_AppUsageAudit_OccurredOnUtc ON dbo.AppUsageAudit (OccurredOnUtc DESC) INCLUDE (UserName, BrowserId, TabId, PageName, Path, IpAddress, ActivityType);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AppUsagePageSession_LastSeenOnUtc' AND object_id = OBJECT_ID('dbo.AppUsagePageSession'))
BEGIN
    CREATE INDEX IX_AppUsagePageSession_LastSeenOnUtc ON dbo.AppUsagePageSession (LastSeenOnUtc DESC) INCLUDE (UserName, PageName, Path, IpAddress, LastLocationText, LastActionOnUtc, CurrentIdleSeconds, MaxIdleSeconds);
END;";

            await using var command = new SqlCommand(sql, connection)
            {
                CommandType = CommandType.Text,
                CommandTimeout = 60
            };

            await command.ExecuteNonQueryAsync(cancellationToken);
            _ensured = true;
        }
        finally
        {
            EnsureSemaphore.Release();
        }
    }

    private static string GetOrCreateBrowserId(HttpContext httpContext)
    {
        if (httpContext.Request.Cookies.TryGetValue(BrowserCookieName, out var existing) && !string.IsNullOrWhiteSpace(existing))
        {
            return existing;
        }

        var browserId = Guid.NewGuid().ToString("N");
        httpContext.Response.Cookies.Append(BrowserCookieName, browserId, new CookieOptions
        {
            HttpOnly = false,
            IsEssential = true,
            Secure = httpContext.Request.IsHttps,
            SameSite = SameSiteMode.Lax,
            Expires = DateTimeOffset.UtcNow.AddYears(2)
        });

        return browserId;
    }

    private static string ResolveUserName(HttpContext httpContext)
    {
        var fullName = httpContext.User?.FindFirst("FullName")?.Value
            ?? httpContext.User?.FindFirst("name")?.Value
            ?? httpContext.User?.FindFirst(System.Security.Claims.ClaimTypes.Name)?.Value;

        if (!string.IsNullOrWhiteSpace(fullName))
        {
            return fullName.Trim();
        }

        var userName = httpContext.User?.Identity?.Name;
        return string.IsNullOrWhiteSpace(userName) ? "Anonymous" : userName.Trim();
    }

    private static string ResolveIpAddress(HttpContext httpContext)
    {
        var forwarded = httpContext.Request.Headers["X-Forwarded-For"].FirstOrDefault();
        if (!string.IsNullOrWhiteSpace(forwarded))
        {
            return forwarded.Split(',')[0].Trim();
        }

        return httpContext.Connection.RemoteIpAddress?.ToString() ?? string.Empty;
    }

    private static object DbString(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
    private static string Str(SqlDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? string.Empty : reader.GetString(ordinal);
    private static decimal? Dec(SqlDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? null : reader.GetDecimal(ordinal);
    private static DateTime Dt(SqlDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? DateTime.MinValue : reader.GetDateTime(ordinal);
    private static DateTime? Ndt(SqlDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
}
