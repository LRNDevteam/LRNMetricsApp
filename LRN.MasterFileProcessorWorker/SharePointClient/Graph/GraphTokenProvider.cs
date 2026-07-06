using System.Net.Http.Headers;
using System.Text.Json;

namespace LRN.SharePointClient.Graph;

public sealed class GraphTokenProvider : IGraphTokenProvider
{
    private readonly HttpClient _http;
    private readonly GraphAuthOptions _options;

    private string? _token;
    private DateTimeOffset _expiresUtc;

    public GraphTokenProvider(HttpClient http, GraphAuthOptions options)
    {
        _http = http;
        _options = options;
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(_token) && DateTimeOffset.UtcNow < _expiresUtc.AddMinutes(-2))
            return _token;

        if (string.IsNullOrWhiteSpace(_options.TenantId) || string.IsNullOrWhiteSpace(_options.ClientId) || string.IsNullOrWhiteSpace(_options.ClientSecret))
            throw new InvalidOperationException("GraphAuthOptions TenantId/ClientId/ClientSecret are required.");

        var url = $"https://login.microsoftonline.com/{_options.TenantId}/oauth2/v2.0/token";

        var form = new Dictionary<string, string>
        {
            ["client_id"] = _options.ClientId,
            ["client_secret"] = _options.ClientSecret,
            ["grant_type"] = "client_credentials",
            ["scope"] = _options.Scope
        };

        using var req = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new FormUrlEncodedContent(form)
        };

        using var resp = await _http.SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);

        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Token request failed ({(int)resp.StatusCode}): {body}");

        using var json = JsonDocument.Parse(body);
        _token = json.RootElement.GetProperty("access_token").GetString();
        var expiresIn = json.RootElement.TryGetProperty("expires_in", out var e) ? e.GetInt32() : 3600;
        _expiresUtc = DateTimeOffset.UtcNow.AddSeconds(expiresIn);

        if (string.IsNullOrWhiteSpace(_token))
            throw new InvalidOperationException("Token response missing access_token.");

        return _token;
    }
}
