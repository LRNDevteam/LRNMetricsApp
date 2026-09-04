using System.Text.RegularExpressions;

namespace LabMetricsDashboard.Services;

/// <summary>Human-readable browser and device names, parsed from a raw User-Agent string.</summary>
public sealed record UserAgentInfo(string Browser, string Device)
{
    private static readonly UserAgentInfo Unknown = new("Unknown browser", "Unknown device");

    /// <summary>
    /// A small, dependency-free parser for the handful of browsers/platforms this app's users
    /// actually show up on. Order matters: Edge, Opera and Samsung Internet are Chromium-based and
    /// carry "Chrome/" in their UA string too, so they must be checked before the generic Chrome
    /// match, and everything above carries "Safari/" as a legacy token, so real Safari is checked
    /// last of the lot.
    /// </summary>
    public static UserAgentInfo Parse(string? userAgent)
    {
        if (string.IsNullOrWhiteSpace(userAgent)) return Unknown;

        var browser =
            Match(userAgent, @"Edg(?:A|iOS)?/([\d.]+)", "Edge") ??
            Match(userAgent, @"OPR/([\d.]+)", "Opera") ??
            Match(userAgent, @"SamsungBrowser/([\d.]+)", "Samsung Internet") ??
            Match(userAgent, @"Firefox/([\d.]+)", "Firefox") ??
            Match(userAgent, @"CriOS/([\d.]+)", "Chrome") ??           // Chrome on iOS
            Match(userAgent, @"Chrome/([\d.]+)", "Chrome") ??
            Match(userAgent, @"Version/([\d.]+).*Safari/", "Safari") ??
            (userAgent.Contains("MSIE", StringComparison.Ordinal) || userAgent.Contains("Trident/", StringComparison.Ordinal)
                ? "Internet Explorer"
                : null) ??
            "Unknown browser";

        var device = ParseDevice(userAgent);

        return new UserAgentInfo(browser, device);
    }

    private static string? Match(string ua, string pattern, string label)
    {
        var m = Regex.Match(ua, pattern);
        if (!m.Success) return null;
        var version = m.Groups[1].Value;
        var major = version.Split('.')[0];
        return string.IsNullOrEmpty(major) ? label : $"{label} {major}";
    }

    private static string ParseDevice(string ua)
    {
        if (ua.Contains("iPad", StringComparison.Ordinal)) return "iPad";
        if (ua.Contains("iPhone", StringComparison.Ordinal)) return "iPhone";

        var android = Regex.Match(ua, @"Android[\s\d.]*;\s*([^;)]+?)\s*(?:Build|\))");
        if (android.Success) return android.Groups[1].Value.Trim();
        if (ua.Contains("Android", StringComparison.Ordinal)) return "Android device";

        var windows = Regex.Match(ua, @"Windows NT ([\d.]+)");
        if (windows.Success)
        {
            return windows.Groups[1].Value switch
            {
                "10.0" => "Windows 10/11 PC",
                "6.3" => "Windows 8.1 PC",
                "6.2" => "Windows 8 PC",
                "6.1" => "Windows 7 PC",
                _ => "Windows PC"
            };
        }

        if (ua.Contains("Macintosh", StringComparison.Ordinal) || ua.Contains("Mac OS X", StringComparison.Ordinal)) return "Mac";
        if (ua.Contains("CrOS", StringComparison.Ordinal)) return "Chromebook";
        if (ua.Contains("Linux", StringComparison.Ordinal)) return "Linux PC";

        return "Unknown device";
    }
}
