namespace LabMetricsDashboard.Services;

/// <summary>
/// Resolves which lab to use for the current request and persists the
/// choice in a cookie so subsequent page navigations default to the
/// same lab without requiring a <c>?lab=</c> query parameter.
/// </summary>
public static class LabSelectionHelper
{
    private const string CookieName = "lmd_selected_lab";

    /// <summary>
    /// Determines the active lab from (in priority order):
    /// <list type="number">
    ///   <item><c>lab</c> query-string parameter (explicit user choice)</item>
    ///   <item><c>lmd_selected_lab</c> cookie (remembered from a prior page)</item>
    ///   <item>First available lab from config</item>
    /// </list>
    /// The resolved lab is always written back to the cookie so it
    /// carries across to the next navigation.
    /// </summary>
    public static string Resolve(HttpContext httpContext, string? labParam, List<string> availableLabs)
    {
        ArgumentNullException.ThrowIfNull(httpContext);

        var selectedLab = labParam;

        // Fallback to cookie
        if (string.IsNullOrWhiteSpace(selectedLab))
        {
            httpContext.Request.Cookies.TryGetValue(CookieName, out var cookieLab);
            if (!string.IsNullOrWhiteSpace(cookieLab)
                && availableLabs.Contains(cookieLab, StringComparer.OrdinalIgnoreCase))
            {
                selectedLab = cookieLab;
            }
        }

        // Fallback to first available
        if (string.IsNullOrWhiteSpace(selectedLab))
        {
            selectedLab = availableLabs.FirstOrDefault() ?? string.Empty;
        }

        // Persist to cookie (session-scoped, HttpOnly, 30-day sliding)
        if (!string.IsNullOrWhiteSpace(selectedLab))
        {
            httpContext.Response.Cookies.Append(CookieName, selectedLab, new CookieOptions
            {
                HttpOnly = true,
                SameSite = SameSiteMode.Lax,
                IsEssential = true,
                MaxAge = TimeSpan.FromDays(30),
            });
        }

        return selectedLab;
    }
}
