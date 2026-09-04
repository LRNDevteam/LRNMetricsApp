using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Models.Menu;
using LabMetricsDashboard.Services.Security;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services;

public interface IMenuApiClient
{
    Task<IReadOnlyList<MenuItemDto>> GetMyMenusAsync(CancellationToken ct);
    Task<IReadOnlyList<MenuRouteDto>> GetManagedRoutesAsync(CancellationToken ct);

    Task<IReadOnlyList<MenuItemDto>> GetMenuItemsAsync(CancellationToken ct);
    Task<MenuItemDto?> GetMenuItemAsync(int id, CancellationToken ct);
    Task<int?> CreateMenuItemAsync(MenuItemSaveRequest request, CancellationToken ct);
    Task UpdateMenuItemAsync(int id, MenuItemSaveRequest request, CancellationToken ct);
    Task SetMenuItemDisabledAsync(int id, bool isDisabled, CancellationToken ct);
    Task DeleteMenuItemAsync(int id, CancellationToken ct);

    Task<IReadOnlyList<MenuRoleOptionDto>> GetRolesAsync(CancellationToken ct);
    Task<IReadOnlyList<int>> GetRoleMenuIdsAsync(int roleId, CancellationToken ct);
    Task SaveRoleMenusAsync(int roleId, IReadOnlyCollection<int> menuIds, CancellationToken ct);

    Task<IReadOnlyList<RoleFeatureDto>> GetMyFeaturesAsync(CancellationToken ct);
    Task<IReadOnlyList<MenuFeatureDto>> GetFeatureCatalogAsync(CancellationToken ct);
    Task<IReadOnlyList<RoleFeatureDto>> GetRoleFeaturesAsync(int roleId, CancellationToken ct);
    Task SaveRoleFeaturesAsync(int roleId, IReadOnlyCollection<RoleFeatureDto> features, CancellationToken ct);
}

/// <summary>
/// Typed client for the LRN.ReportsApi dynamic-menu endpoints (api/menu).
/// Same base-URL + JWT pattern as <see cref="MasterValuesApiClient"/>.
/// </summary>
public sealed class MenuApiClient : IMenuApiClient
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly HttpClient _http;
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly WorkflowJwtIssuer _jwtIssuer;

    public MenuApiClient(HttpClient http, IOptions<DenialWorkflowOptions> options, IHttpContextAccessor httpContextAccessor, WorkflowJwtIssuer jwtIssuer)
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

    public async Task<IReadOnlyList<MenuItemDto>> GetMyMenusAsync(CancellationToken ct)
        => await GetAsync<List<MenuItemDto>>("api/menu/my", ct) ?? [];

    public async Task<IReadOnlyList<MenuRouteDto>> GetManagedRoutesAsync(CancellationToken ct)
        => await GetAsync<List<MenuRouteDto>>("api/menu/routes", ct) ?? [];

    public async Task<IReadOnlyList<MenuItemDto>> GetMenuItemsAsync(CancellationToken ct)
        => await GetAsync<List<MenuItemDto>>("api/menu/items", ct) ?? [];

    public async Task<MenuItemDto?> GetMenuItemAsync(int id, CancellationToken ct)
        => await GetAsync<MenuItemDto>($"api/menu/items/{id}", ct);

    public async Task<int?> CreateMenuItemAsync(MenuItemSaveRequest request, CancellationToken ct)
    {
        var result = await SendJsonAsync<MenuItemSaveRequest, CreateResult>(HttpMethod.Post, "api/menu/items", request, ct);
        return result?.Id;
    }

    public Task UpdateMenuItemAsync(int id, MenuItemSaveRequest request, CancellationToken ct)
        => SendJsonAsync<MenuItemSaveRequest, CreateResult>(HttpMethod.Put, $"api/menu/items/{id}", request, ct);

    public Task SetMenuItemDisabledAsync(int id, bool isDisabled, CancellationToken ct)
        => SendJsonAsync<object, CreateResult>(HttpMethod.Patch, $"api/menu/items/{id}/disabled", new { isDisabled }, ct);

    public async Task DeleteMenuItemAsync(int id, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.DeleteAsync($"api/menu/items/{id}", ct);
        await EnsureSuccessAsync(response, ct);
    }

    public async Task<IReadOnlyList<MenuRoleOptionDto>> GetRolesAsync(CancellationToken ct)
        => await GetAsync<List<MenuRoleOptionDto>>("api/menu/roles", ct) ?? [];

    public async Task<IReadOnlyList<int>> GetRoleMenuIdsAsync(int roleId, CancellationToken ct)
        => await GetAsync<List<int>>($"api/menu/roles/{roleId}/menus", ct) ?? [];

    public Task SaveRoleMenusAsync(int roleId, IReadOnlyCollection<int> menuIds, CancellationToken ct)
        => SendJsonAsync<object, CreateResult>(HttpMethod.Put, $"api/menu/roles/{roleId}/menus", new { menuIds }, ct);

    public async Task<IReadOnlyList<RoleFeatureDto>> GetMyFeaturesAsync(CancellationToken ct)
        => await GetAsync<List<RoleFeatureDto>>("api/menu/my/features", ct) ?? [];

    public async Task<IReadOnlyList<MenuFeatureDto>> GetFeatureCatalogAsync(CancellationToken ct)
        => await GetAsync<List<MenuFeatureDto>>("api/menu/features", ct) ?? [];

    public async Task<IReadOnlyList<RoleFeatureDto>> GetRoleFeaturesAsync(int roleId, CancellationToken ct)
        => await GetAsync<List<RoleFeatureDto>>($"api/menu/roles/{roleId}/features", ct) ?? [];

    public Task SaveRoleFeaturesAsync(int roleId, IReadOnlyCollection<RoleFeatureDto> features, CancellationToken ct)
        => SendJsonAsync<object, CreateResult>(HttpMethod.Put, $"api/menu/roles/{roleId}/features", new { features }, ct);

    private sealed class CreateResult
    {
        public int? Id { get; set; }
        public bool Success { get; set; }
    }

    private async Task<T?> GetAsync<T>(string url, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.GetAsync(url, ct);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return default;
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct);
    }

    private async Task<TResult?> SendJsonAsync<TPayload, TResult>(HttpMethod method, string url, TPayload payload, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var request = new HttpRequestMessage(method, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
        };
        using var response = await _http.SendAsync(request, ct);
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadFromJsonAsync<TResult>(JsonOptions, ct);
    }

    private async Task AuthorizeAsync(CancellationToken ct)
    {
        if (_http.BaseAddress == null) throw new InvalidOperationException("Menu API base URL is missing or invalid. Configure DenialWorkflowApi:BaseUrl to the LRN.ReportsApi URL.");
        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true) return;
        var token = await _jwtIssuer.CreateTokenAsync(user, ct);
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.IsSuccessStatusCode) return;
        var body = await response.Content.ReadAsStringAsync(ct);
        throw new InvalidOperationException(string.IsNullOrWhiteSpace(body) ? $"Menu API request failed: {(int)response.StatusCode}" : body);
    }
}
