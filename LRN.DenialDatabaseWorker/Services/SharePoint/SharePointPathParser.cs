using System.Net;

namespace DenialDatabaseProcessorWorker.Services.SharePoint;

public static class SharePointPathParser
{
    /// <summary>
    /// Takes a SharePoint "AllItems.aspx?id=..." style folder link and returns the decoded folder path.
    /// Example output: "/sites/SiteName/Shared Documents/10. Automation/LRN-Output/Denial Database"
    /// </summary>
    public static string ExtractFolderPathFromLink(string sharePointUploadPath)
    {
        if (string.IsNullOrWhiteSpace(sharePointUploadPath))
            return "";

        // If it's already a server-relative folder path, accept it
        if (sharePointUploadPath.StartsWith("/sites/", StringComparison.OrdinalIgnoreCase))
            return sharePointUploadPath;

        if (!Uri.TryCreate(sharePointUploadPath, UriKind.Absolute, out var uri))
            return "";

        var qs = ParseQueryString(uri.Query);
        if (!qs.TryGetValue("id", out var id) || string.IsNullOrWhiteSpace(id))
            return "";

        // id is URL-encoded server-relative path
        return WebUtility.UrlDecode(id) ?? "";
    }

    private static Dictionary<string, string> ParseQueryString(string query)
    {
        var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(query))
            return dict;

        var q = query.TrimStart('?');
        foreach (var part in q.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = part.Split('=', 2);
            var key = WebUtility.UrlDecode(kv[0]) ?? "";
            var val = kv.Length > 1 ? (WebUtility.UrlDecode(kv[1]) ?? "") : "";
            if (!string.IsNullOrWhiteSpace(key))
                dict[key] = val;
        }
        return dict;
    }
}
