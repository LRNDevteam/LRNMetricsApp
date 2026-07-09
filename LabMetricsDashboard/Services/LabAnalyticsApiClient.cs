using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services;

public interface ILabAnalyticsApiClient
{
    Task<MasterPagedResult<LabModeDto>> GetModesAsync(IQueryCollection query, CancellationToken ct);
    Task<MasterPagedResult<LabMedianDto>> GetMediansAsync(IQueryCollection query, CancellationToken ct);
    Task<(byte[] Content, string FileName)> ExportModesAsync(IQueryCollection query, CancellationToken ct);
    Task<(byte[] Content, string FileName)> ExportMediansAsync(IQueryCollection query, CancellationToken ct);
    Task<IReadOnlyList<string>> GetModeOptionsAsync(IQueryCollection query, CancellationToken ct);
    Task<IReadOnlyList<string>> GetMedianOptionsAsync(IQueryCollection query, CancellationToken ct);
    Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct);
}

/// <summary>
/// Proxy to the LRN.ReportsApi analytics endpoints (Lab Modes / Meridian).
/// Same base URL and workflow JWT handshake as the Master Values client.
/// </summary>
public sealed class LabAnalyticsApiClient : ILabAnalyticsApiClient
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly HttpClient _http;
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly WorkflowJwtIssuer _jwtIssuer;

    public LabAnalyticsApiClient(HttpClient http, IOptions<DenialWorkflowOptions> options, IHttpContextAccessor httpContextAccessor, WorkflowJwtIssuer jwtIssuer)
    {
        _http = http;
        _httpContextAccessor = httpContextAccessor;
        _jwtIssuer = jwtIssuer;
        var baseUrl = options.Value.BaseUrl?.Trim();
        if (!string.IsNullOrWhiteSpace(baseUrl))
        {
            if (!baseUrl.EndsWith("/", StringComparison.Ordinal)) baseUrl += "/";
            if (Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)) _http.BaseAddress = uri;
        }
    }

    public async Task<MasterPagedResult<LabModeDto>> GetModesAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<MasterPagedResult<LabModeDto>>("api/analytics/lab-modes" + Query(query), ct) ?? new();

    public async Task<MasterPagedResult<LabMedianDto>> GetMediansAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<MasterPagedResult<LabMedianDto>>("api/analytics/lab-medians" + Query(query), ct) ?? new();

    public Task<(byte[] Content, string FileName)> ExportModesAsync(IQueryCollection query, CancellationToken ct)
        => ExportAsync("api/analytics/lab-modes/export" + Query(query), "LabModes.xlsx", ct);

    public Task<(byte[] Content, string FileName)> ExportMediansAsync(IQueryCollection query, CancellationToken ct)
        => ExportAsync("api/analytics/lab-medians/export" + Query(query), "LabMedians.xlsx", ct);

    public async Task<IReadOnlyList<string>> GetModeOptionsAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<List<string>>("api/analytics/lab-modes/options" + Query(query), ct) ?? [];

    public async Task<IReadOnlyList<string>> GetMedianOptionsAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<List<string>>("api/analytics/lab-medians/options" + Query(query), ct) ?? [];

    public async Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct)
        => await GetAsync<List<MasterValueLabOption>>("api/analytics/labs", ct) ?? [];

    private async Task<(byte[] Content, string FileName)> ExportAsync(string url, string fallbackName, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.GetAsync(url, ct);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(body) ? $"API request failed: {(int)response.StatusCode}" : body);
        }
        var fileName = response.Content.Headers.ContentDisposition?.FileNameStar
            ?? response.Content.Headers.ContentDisposition?.FileName?.Trim('"')
            ?? fallbackName;
        return (await response.Content.ReadAsByteArrayAsync(ct), fileName);
    }

    private async Task<T?> GetAsync<T>(string url, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.GetAsync(url, ct);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return default;
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(body) ? $"API request failed: {(int)response.StatusCode}" : body);
        }
        return await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct);
    }

    private async Task AuthorizeAsync(CancellationToken ct)
    {
        if (_http.BaseAddress == null) throw new InvalidOperationException("Analytics API base URL is missing or invalid. Configure DenialWorkflowApi:BaseUrl to the LRN.ReportsApi URL.");
        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true) return;
        var token = await _jwtIssuer.CreateTokenAsync(user, ct);
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
    }

    private static string Query(IQueryCollection query)
    {
        var pairs = query
            .SelectMany(x => x.Value, (x, v) => $"{Uri.EscapeDataString(x.Key)}={Uri.EscapeDataString(v ?? string.Empty)}");
        var text = string.Join("&", pairs);
        return string.IsNullOrWhiteSpace(text) ? string.Empty : "?" + text;
    }
}
