using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Azure.Core;
using Azure.Identity;
using DenialDatabaseProcessorWorker.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services.SharePoint
{
    /// <summary>
    /// Minimal Microsoft Graph REST client (no SDK) for uploading to SharePoint document library.
    /// Uses ClientSecretCredential.
    /// </summary>
    public sealed class SharePointGraphClient
    {
        private readonly HttpClient _http;
        private readonly ProcessorOptions _options;
        private readonly ILogger<SharePointGraphClient> _logger;

        private string? _cachedSiteId;

        public SharePointGraphClient(
            HttpClient httpClient,
            IOptions<ProcessorOptions> options,
            ILogger<SharePointGraphClient> logger)
        {
            _http = httpClient;
            _options = options.Value;
            _logger = logger;
        }

        public bool Enabled => _options.SharePoint.Enabled;

        public async Task UploadAsync(string baseFolderServerRelativePath, string relativeSubfolder, string localFilePath, CancellationToken ct)
        {
            if (!Enabled)
                return;

            var siteId = await GetSiteIdAsync(ct);

            // Convert server-relative base folder to drive-relative path:
            // Example baseFolderServerRelativePath: /sites/Site/Shared Documents/10. Automation/...
            // Drive root is the document library root (e.g., "Shared Documents").
            var driveRelativeBase = ServerRelativeToDrivePath(baseFolderServerRelativePath);
            if (string.IsNullOrWhiteSpace(driveRelativeBase))
                throw new InvalidOperationException($"Unable to parse SharePoint base folder from '{baseFolderServerRelativePath}'.");

            var fileName = Path.GetFileName(localFilePath);
            var targetFolderPath = CombineGraphPath(driveRelativeBase, relativeSubfolder); // under the base folder
            await EnsureFolderPathAsync(siteId, targetFolderPath, ct);

            var uploadPath = $"{targetFolderPath}/{fileName}".Replace("\\", "/");
            await PutFileAsync(siteId, uploadPath, localFilePath, ct);
        }

        private async Task<string> GetSiteIdAsync(CancellationToken ct)
        {
            if (!string.IsNullOrWhiteSpace(_cachedSiteId))
                return _cachedSiteId;

            var siteUrl = _options.SharePoint.SiteUrl?.Trim();
            if (string.IsNullOrWhiteSpace(siteUrl))
                throw new InvalidOperationException("SharePoint.SiteUrl is required when SharePoint upload is enabled.");

            var uri = new Uri(siteUrl);
            var hostname = uri.Host;       // tenant.sharepoint.com
            var sitePath = uri.AbsolutePath; // /sites/SiteName

            var url = $"https://graph.microsoft.com/v1.0/sites/{hostname}:{sitePath}";

            using var req = await CreateAuthRequestAsync(HttpMethod.Get, url, ct);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            using var resp = await _http.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode)
                throw new InvalidOperationException($"Graph get site failed: {(int)resp.StatusCode} {resp.ReasonPhrase} {body}");

            using var doc = JsonDocument.Parse(body);
            var id = doc.RootElement.GetProperty("id").GetString();
            if (string.IsNullOrWhiteSpace(id))
                throw new InvalidOperationException("Graph site id not found in response.");

            _cachedSiteId = id!;
            return id!;
        }

        private async Task EnsureFolderPathAsync(string siteId, string driveRelativePath, CancellationToken ct)
        {
            // Create folders one-by-one under drive/root
            // POST /sites/{siteId}/drive/root:/{parent}:/children  {name, folder:{}, conflictBehavior:"fail"}
            var parts = driveRelativePath.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
            if (parts.Count == 0)
                return;

            // We don't create the first part if it's "Shared Documents" (library root already exists),
            // but we still ensure remaining subfolders.
            string current = parts[0];
            for (int i = 1; i < parts.Count; i++)
            {
                var parent = current;
                var child = parts[i];

                await CreateFolderIfMissingAsync(siteId, parent, child, ct);
                current = $"{parent}/{child}";
            }
        }

        private async Task CreateFolderIfMissingAsync(string siteId, string parentPath, string childName, CancellationToken ct)
        {
            var url = $"https://graph.microsoft.com/v1.0/sites/{siteId}/drive/root:/{Escape(parentPath)}:/children";

            // Use a dictionary so we can include "@microsoft.graph.conflictBehavior"
            var payload = new Dictionary<string, object?>
            {
                ["name"] = childName,
                ["folder"] = new Dictionary<string, object?>(), // {}
                ["@microsoft.graph.conflictBehavior"] = "fail"
            };

            var json = JsonSerializer.Serialize(payload);
            using var req = await CreateAuthRequestAsync(HttpMethod.Post, url, ct);
            req.Content = new StringContent(json, Encoding.UTF8, "application/json");
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            using var resp = await _http.SendAsync(req, ct);

            if (resp.IsSuccessStatusCode)
                return;

            var body = await resp.Content.ReadAsStringAsync(ct);

            // 409 conflict -> already exists (fine)
            if ((int)resp.StatusCode == 409)
                return;

            throw new InvalidOperationException($"Graph create folder failed ({parentPath}/{childName}): {(int)resp.StatusCode} {resp.ReasonPhrase} {body}");
        }

        private async Task PutFileAsync(string siteId, string driveRelativeFilePath, string localFilePath, CancellationToken ct)
        {
            var url = $"https://graph.microsoft.com/v1.0/sites/{siteId}/drive/root:/{Escape(driveRelativeFilePath)}:/content";
            await using var fs = File.OpenRead(localFilePath);

            using var req = await CreateAuthRequestAsync(HttpMethod.Put, url, ct);
            req.Content = new StreamContent(fs);
            req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

            using var resp = await _http.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            if (!resp.IsSuccessStatusCode)
                throw new InvalidOperationException($"Graph upload failed: {(int)resp.StatusCode} {resp.ReasonPhrase} {body}");

            _logger.LogInformation("Uploaded to SharePoint via Graph: {Path}", driveRelativeFilePath);
        }

        private async Task<HttpRequestMessage> CreateAuthRequestAsync(HttpMethod method, string url, CancellationToken ct)
        {
            var token = await GetAccessTokenAsync(ct);

            var req = new HttpRequestMessage(method, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return req;
        }

        private async Task<string> GetAccessTokenAsync(CancellationToken ct)
        {
            var sp = _options.SharePoint;

            if (string.IsNullOrWhiteSpace(sp.TenantId) || string.IsNullOrWhiteSpace(sp.ClientId) || string.IsNullOrWhiteSpace(sp.ClientSecret))
                throw new InvalidOperationException("SharePoint TenantId/ClientId/ClientSecret must be configured.");

            var cred = new ClientSecretCredential(sp.TenantId, sp.ClientId, sp.ClientSecret);
            var token = await cred.GetTokenAsync(new TokenRequestContext(new[] { "https://graph.microsoft.com/.default" }), ct);
            return token.Token;
        }

        private static string ServerRelativeToDrivePath(string serverRelativeFolderPath)
        {
            // Expect: /sites/SiteName/Shared Documents/...
            var p = (serverRelativeFolderPath ?? string.Empty).Trim();
            if (!p.StartsWith("/sites/", StringComparison.OrdinalIgnoreCase))
                return string.Empty;

            // Strip "/sites/{SiteName}/"
            var siteNameEndSlash = p.IndexOf('/', "/sites/".Length);
            if (siteNameEndSlash < 0)
                return string.Empty;

            var rest = p[(siteNameEndSlash + 1)..]; // "Shared Documents/..."
            return rest.Trim('/');
        }

        private static string CombineGraphPath(string a, string b)
        {
            a = (a ?? "").Trim().Trim('/');
            b = (b ?? "").Trim().Trim('/');
            if (string.IsNullOrEmpty(a)) return b;
            if (string.IsNullOrEmpty(b)) return a;
            return $"{a}/{b}";
        }

        private static string Escape(string graphPath)
        {
            if (string.IsNullOrEmpty(graphPath))
                return string.Empty;

            // Escape each segment but keep slashes as separators
            return string.Join("/", graphPath
                .Split('/', StringSplitOptions.RemoveEmptyEntries)
                .Select(Uri.EscapeDataString));
        }
    }
}