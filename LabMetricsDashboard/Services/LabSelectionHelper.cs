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
    /// <exception cref="LabMetricsDashboard.Services.Security.LabAccessDeniedException">
    /// The request named a lab that is not in <paramref name="availableLabs"/>.
    /// </exception>
    public static string Resolve(HttpContext httpContext, string? labParam, List<string> availableLabs)
    {
        ArgumentNullException.ThrowIfNull(httpContext);
        availableLabs ??= new List<string>();

        // HIPAA finding F3. An explicit ?lab= used to be taken at face value: whatever the caller
        // typed became the selected lab, and the page then rendered that lab's data. The cookie
        // path below was already checked against availableLabs, so the query string - the one an
        // attacker controls - was the only unchecked route in.
        //
        // Refused rather than silently corrected to an allowed lab. Quietly swapping the lab would
        // show the user data they did not ask for under a URL that says otherwise, and would leave
        // no signal that anything was attempted.
        if (!string.IsNullOrWhiteSpace(labParam)
            && !availableLabs.Contains(labParam.Trim(), StringComparer.OrdinalIgnoreCase))
        {
            throw new LabMetricsDashboard.Services.Security.LabAccessDeniedException(labParam);
        }

        // The configured spelling wins over the caller's: several downstream dictionaries are
        // keyed by lab name and not all of them compare case-insensitively.
        var selectedLab = string.IsNullOrWhiteSpace(labParam)
            ? labParam
            : availableLabs.First(l => string.Equals(l, labParam.Trim(), StringComparison.OrdinalIgnoreCase));

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
