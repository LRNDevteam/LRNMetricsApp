using System.Net.Http.Headers;
using System.Text.Json;
using LRN.SharePointClient.Abstractions;
using LRN.SharePointClient.Models;

namespace LRN.SharePointClient.Graph;

public sealed class GraphSharePointClient : ISharePointClient
{
    private readonly HttpClient _http;
    private readonly IGraphTokenProvider _tokenProvider;

    public GraphSharePointClient(HttpClient http, IGraphTokenProvider tokenProvider)
    {
        _http = http;
        _tokenProvider = tokenProvider;
    }

    public Task<IReadOnlyList<SharePointItemInfo>> ListChildrenAsync(SharePointLocation location, CancellationToken ct)
        => ListChildrenAsync(location, subFolderPath: "", ct);

    public async Task<IReadOnlyList<SharePointItemInfo>> ListChildrenAsync(SharePointLocation location, string subFolderPath, CancellationToken ct)
    {
        var folderPath = BuildFolderPath(location.FolderPath, subFolderPath);
        var url = $"https://graph.microsoft.com/v1.0/sites/{location.SiteId}/drives/{location.DriveId}/root:/{EncodePath(folderPath)}:/children?$select=id,name,lastModifiedDateTime,size,folder,file";

        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        await AttachAuthAsync(req, ct);

        using var resp = await _http.SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);

        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"ListChildren failed ({(int)resp.StatusCode}): {body}");

        using var json = JsonDocument.Parse(body);
        var list = new List<SharePointItemInfo>();

        if (!json.RootElement.TryGetProperty("value", out var value) || value.ValueKind != JsonValueKind.Array)
            return list;

        foreach (var item in value.EnumerateArray())
        {
            var id = item.GetProperty("id").GetString() ?? string.Empty;
            var name = item.GetProperty("name").GetString() ?? string.Empty;
            var lastModified = item.TryGetProperty("lastModifiedDateTime", out var lm)
                ? DateTimeOffset.Parse(lm.GetString() ?? DateTimeOffset.UtcNow.ToString("O"))
                : DateTimeOffset.UtcNow;

            var isFolder = item.TryGetProperty("folder", out _);
            long? size = item.TryGetProperty("size", out var s) ? s.GetInt64() : null;

            list.Add(new SharePointItemInfo(id, name, isFolder, lastModified.ToUniversalTime(), size));
        }

        return list;
    }

    public async Task DownloadFileAsync(SharePointLocation location, string itemId, string localFilePath, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(localFilePath) ?? AppContext.BaseDirectory);

        var url = $"https://graph.microsoft.com/v1.0/sites/{location.SiteId}/drives/{location.DriveId}/items/{itemId}/content";

        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        await AttachAuthAsync(req, ct);

        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException($"Download failed ({(int)resp.StatusCode}): {body}");
        }

        await using var src = await resp.Content.ReadAsStreamAsync(ct);
        await using var dst = File.Create(localFilePath);
        await src.CopyToAsync(dst, ct);
    }

    public async Task UploadFileAsync(SharePointLocation location, string targetFileName, string localFilePath, bool overwrite, CancellationToken ct)
    {
        if (!File.Exists(localFilePath))
            throw new FileNotFoundException("Local file not found", localFilePath);

        var path = BuildFolderPath(location.FolderPath, "");
        var finalPath = string.IsNullOrWhiteSpace(path) ? targetFileName : $"{path}/{targetFileName}";

        var url = $"https://graph.microsoft.com/v1.0/sites/{location.SiteId}/drives/{location.DriveId}/root:/{EncodePath(finalPath)}:/content";

        await using var stream = File.OpenRead(localFilePath);
        using var req = new HttpRequestMessage(HttpMethod.Put, url)
        {
            Content = new StreamContent(stream)
        };

        req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        await AttachAuthAsync(req, ct);

        using var resp = await _http.SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);

        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Upload failed ({(int)resp.StatusCode}): {body}");
    }

    private async Task AttachAuthAsync(HttpRequestMessage req, CancellationToken ct)
    {
        var token = await _tokenProvider.GetAccessTokenAsync(ct);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
    }

    private static string EncodePath(string path)
    {
        path = (path ?? string.Empty).Trim().Trim('/');
        if (string.IsNullOrWhiteSpace(path)) return string.Empty;
        var segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return string.Join("/", segments.Select(Uri.EscapeDataString));
    }

    private static string BuildFolderPath(string basePath, string subPath)
    {
        basePath = (basePath ?? string.Empty).Trim().Trim('/');
        subPath = (subPath ?? string.Empty).Trim().Trim('/');

        if (string.IsNullOrWhiteSpace(basePath))
            return subPath;
        if (string.IsNullOrWhiteSpace(subPath))
            return basePath;
        return $"{basePath}/{subPath}";
    }
}
