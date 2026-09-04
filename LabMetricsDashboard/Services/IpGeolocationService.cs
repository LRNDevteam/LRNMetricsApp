using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Resolves an IP address to a "City, Region, Country" label via ip-api.com's free tier
/// (45 requests/minute, no API key, HTTP only - HTTPS needs their paid plan; this is a
/// server-to-server call, so plain HTTP carries no browser mixed-content concern).
///
/// Visitor IP addresses leave this server and go to a third party for this to work. If that is
/// not acceptable for this app's data-sensitivity level, swap this implementation for a local
/// GeoIP database (e.g. MaxMind GeoLite2) instead - <see cref="IIpGeolocationService"/> is the
/// seam to do that behind.
/// </summary>
public sealed class IpGeolocationService : IIpGeolocationService
{
    private static readonly TimeSpan CacheDuration = TimeSpan.FromHours(6);
    private static readonly TimeSpan NegativeCacheDuration = TimeSpan.FromMinutes(30);

    // ip-api.com returns lowercase field names ("status", "regionName", ...); the response type
    // below is PascalCase for C# convention, so matching must be case-insensitive.
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private readonly HttpClient _http;
    private readonly IMemoryCache _cache;
    private readonly ILogger<IpGeolocationService> _logger;

    public IpGeolocationService(HttpClient http, IMemoryCache cache, ILogger<IpGeolocationService> logger)
    {
        _http = http;
        _cache = cache;
        _logger = logger;
    }

    public async Task<string?> ResolveAsync(string ipAddress, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(ipAddress)) return null;

        var ip = ipAddress.Trim();
        var cacheKey = $"iplocation:{ip}";
        if (_cache.TryGetValue(cacheKey, out string? cached)) return cached;

        // Office LANs, localhost and Docker/VPN ranges all resolve to nothing useful upstream -
        // skip the call entirely rather than burning one of the 45/minute on a guaranteed miss.
        if (!IPAddress.TryParse(ip, out var parsed) || IsPrivateOrLoopback(parsed))
        {
            _cache.Set(cacheKey, (string?)null, CacheDuration);
            return null;
        }

        try
        {
            using var response = await _http.GetAsync($"json/{ip}?fields=status,message,country,regionName,city", cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                _cache.Set(cacheKey, (string?)null, NegativeCacheDuration);
                return null;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var doc = await JsonSerializer.DeserializeAsync<IpApiResponse>(stream, JsonOptions, cancellationToken);

            if (doc is null || !string.Equals(doc.Status, "success", StringComparison.OrdinalIgnoreCase))
            {
                // "fail" covers reserved ranges ip-api doesn't recognize and, notably, the
                // 45/minute rate limit - cache briefly rather than on every request so a burst of
                // traffic backs off instead of hammering an already-throttling endpoint.
                _cache.Set(cacheKey, (string?)null, NegativeCacheDuration);
                return null;
            }

            var parts = new[] { doc.City, doc.RegionName, doc.Country }
                .Where(x => !string.IsNullOrWhiteSpace(x));
            var label = string.Join(", ", parts);
            var result = string.IsNullOrWhiteSpace(label) ? null : label;

            _cache.Set(cacheKey, result, CacheDuration);
            return result;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Never let a third-party lookup take the Usage page down with it.
            _logger.LogWarning(ex, "IP geolocation lookup failed for {IpAddress}", ip);
            _cache.Set(cacheKey, (string?)null, NegativeCacheDuration);
            return null;
        }
    }

    private static bool IsPrivateOrLoopback(IPAddress ip)
    {
        if (IPAddress.IsLoopback(ip)) return true;

        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();

        if (ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
        {
            var b = ip.GetAddressBytes();
            return b[0] == 10
                || (b[0] == 172 && b[1] is >= 16 and <= 31)
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254); // link-local
        }

        // IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
        var bytes = ip.GetAddressBytes();
        return (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80);
    }

    private sealed class IpApiResponse
    {
        public string? Status { get; set; }
        public string? Message { get; set; }
        public string? Country { get; set; }
        public string? RegionName { get; set; }
        public string? City { get; set; }
    }
}
