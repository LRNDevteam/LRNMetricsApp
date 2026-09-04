using System.Collections.Concurrent;
using System.Security.Claims;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

/// <summary>
/// "Who's active right now" tracked entirely in this server's memory — nothing is written to or
/// read from SQL. A heartbeat every ~15s from each open tab (see the script in _Layout.cshtml)
/// upserts an entry here; the Usage page just reads the live dictionary.
///
/// This means a session vanishes from the page on an app-pool recycle/deploy - the browser's
/// next heartbeat (within 15s) recreates it - and nothing here survives as a historical audit
/// trail. That trade-off is the point: this is a live "who's online" view, not a logged record of
/// who visited what page. If a persisted history is ever wanted again, layer a separate write
/// path onto this rather than routing it back through the on-the-go view.
///
/// Registered as a singleton (see Program.cs) - it IS the storage, so it must outlive any single
/// request.
/// </summary>
public sealed class InMemoryAppUsageService : IAppUsageAuditService
{
    private const string BrowserCookieName = "lmd.browser.id";
    private static readonly TimeSpan ActiveWindow = TimeSpan.FromMinutes(20);

    // Sessions quiet for longer than this are dropped from memory entirely, so a laptop closed
    // mid-session (no final heartbeat ever arrives) doesn't sit in the dictionary forever.
    private static readonly TimeSpan ForgetAfter = TimeSpan.FromHours(2);

    private readonly ConcurrentDictionary<string, LiveSession> _sessions = new();

    public Task TrackHeartbeatAsync(HttpContext httpContext, UsageHeartbeatRequest request, CancellationToken cancellationToken = default)
    {
        if (request is null) return Task.CompletedTask;

        var browserId = GetOrCreateBrowserId(httpContext);
        var tabId = string.IsNullOrWhiteSpace(request.TabId) ? "default" : request.TabId.Trim();
        var key = $"{browserId}:{tabId}";
        var now = DateTime.UtcNow;
        var idleSeconds = Math.Max(0, Math.Min(request.IdleSeconds, 86400));
        var locationText = string.IsNullOrWhiteSpace(request.LocationText)
            ? (request.Latitude.HasValue && request.Longitude.HasValue ? $"{request.Latitude:0.000000}, {request.Longitude:0.000000}" : null)
            : request.LocationText.Trim();

        _sessions.AddOrUpdate(
            key,
            _ => new LiveSession
            {
                BrowserId = browserId,
                TabId = tabId,
                UserName = ResolveUserName(httpContext),
                PageName = string.IsNullOrWhiteSpace(request.PageName) ? "Unknown" : request.PageName.Trim(),
                Path = string.IsNullOrWhiteSpace(request.Path) ? httpContext.Request.Headers.Referer.ToString() : request.Path.Trim(),
                IpAddress = ResolveIpAddress(httpContext),
                UserAgent = httpContext.Request.Headers.UserAgent.ToString(),
                LocationText = locationText,
                Latitude = request.Latitude,
                Longitude = request.Longitude,
                FirstSeenOnUtc = now,
                LastSeenOnUtc = now,
                LastActionOnUtc = now.AddSeconds(-idleSeconds),
                CurrentIdleSeconds = idleSeconds,
                MaxIdleSeconds = idleSeconds
            },
            (_, existing) => existing with
            {
                UserName = ResolveUserName(httpContext),
                PageName = string.IsNullOrWhiteSpace(request.PageName) ? existing.PageName : request.PageName.Trim(),
                Path = string.IsNullOrWhiteSpace(request.Path) ? existing.Path : request.Path.Trim(),
                IpAddress = ResolveIpAddress(httpContext),
                UserAgent = httpContext.Request.Headers.UserAgent.ToString(),
                // A tab that already sent a location keeps it even if a later heartbeat - most of
                // them - carries none, the same "last known good" behaviour the old SQL MERGE had.
                LocationText = locationText ?? existing.LocationText,
                Latitude = request.Latitude ?? existing.Latitude,
                Longitude = request.Longitude ?? existing.Longitude,
                LastSeenOnUtc = now,
                LastActionOnUtc = now.AddSeconds(-idleSeconds),
                CurrentIdleSeconds = idleSeconds,
                MaxIdleSeconds = Math.Max(idleSeconds, existing.MaxIdleSeconds)
            });

        PruneStale(now);
        return Task.CompletedTask;
    }

    public Task<AppUsagePageViewModel> GetUsagePageAsync(CancellationToken cancellationToken = default)
    {
        var now = DateTime.UtcNow;
        var model = new AppUsagePageViewModel();

        foreach (var session in _sessions.Values.OrderByDescending(s => s.LastSeenOnUtc))
        {
            if (now - session.LastSeenOnUtc > ActiveWindow) continue;

            // Idle time keeps counting between heartbeats - it is "seconds since the last real
            // click", not "seconds since the last heartbeat" - so it is recomputed live here
            // rather than read off whatever value the last heartbeat happened to report.
            var liveIdleSeconds = Math.Max(0, (int)Math.Round((now - session.LastActionOnUtc).TotalSeconds));

            model.ActiveUsers.Add(new CurrentUserActivityRecord
            {
                UserName = session.UserName,
                BrowserId = session.BrowserId,
                TabId = session.TabId,
                PageName = session.PageName,
                Path = session.Path,
                IpAddress = session.IpAddress,
                LocationText = session.LocationText ?? string.Empty,
                Latitude = session.Latitude,
                Longitude = session.Longitude,
                UserAgent = session.UserAgent,
                FirstSeenOnUtc = session.FirstSeenOnUtc,
                LastSeenOnUtc = session.LastSeenOnUtc,
                LastActionOnUtc = session.LastActionOnUtc,
                CurrentIdleSeconds = liveIdleSeconds,
                MaxIdleSeconds = Math.Max(session.MaxIdleSeconds, liveIdleSeconds),
                IdleStatus = liveIdleSeconds >= 300 ? "Idle" : "Active"
            });
        }

        model.ActiveUsersCount = model.ActiveUsers.Count;
        return Task.FromResult(model);
    }

    private void PruneStale(DateTime now)
    {
        foreach (var (key, session) in _sessions)
        {
            if (now - session.LastSeenOnUtc > ForgetAfter)
            {
                _sessions.TryRemove(key, out _);
            }
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
            ?? httpContext.User?.FindFirst(ClaimTypes.Name)?.Value;

        if (!string.IsNullOrWhiteSpace(fullName)) return fullName.Trim();

        var userName = httpContext.User?.Identity?.Name;
        return string.IsNullOrWhiteSpace(userName) ? "Anonymous" : userName.Trim();
    }

    private static string ResolveIpAddress(HttpContext httpContext)
    {
        var forwarded = httpContext.Request.Headers["X-Forwarded-For"].FirstOrDefault();
        if (!string.IsNullOrWhiteSpace(forwarded)) return forwarded.Split(',')[0].Trim();

        return httpContext.Connection.RemoteIpAddress?.ToString() ?? string.Empty;
    }

    private sealed record LiveSession
    {
        public required string BrowserId { get; init; }
        public required string TabId { get; init; }
        public required string UserName { get; init; }
        public required string PageName { get; init; }
        public required string Path { get; init; }
        public required string IpAddress { get; init; }
        public required string UserAgent { get; init; }
        public string? LocationText { get; init; }
        public decimal? Latitude { get; init; }
        public decimal? Longitude { get; init; }
        public required DateTime FirstSeenOnUtc { get; init; }
        public required DateTime LastSeenOnUtc { get; init; }
        public required DateTime LastActionOnUtc { get; init; }
        public required int CurrentIdleSeconds { get; init; }
        public required int MaxIdleSeconds { get; init; }
    }
}
