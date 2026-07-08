using System.Net.Http.Headers;
using System.Net.Http.Json;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using LabMetricsDashboard.ViewModels;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services.DenialDashboard;

// Thin HTTP client over LRN.ReportsApi's api/denial-dashboard/* endpoints. All Denial Dashboard
// database access now lives in the API; the controller talks to this client instead of SQL.
// Auth reuses the same self-signed workflow JWT as DenialWorkflowApiClient.
public interface IDenialDashboardApiClient
{
    Task<IReadOnlyList<LabOption>> GetLabsAsync(CancellationToken cancellationToken = default);
    Task<string?> GetCurrentRunIdAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialRecord>> GetByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialInsightRecord>> GetInsightTableByLabAsync(int labId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsByLabAsync(int labId, int page, int pageSize, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<int> GetLineItemCountByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsForExportByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DenialBreakdownSourceRecord>> GetBreakdownSourceByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default);
    Task<DenialFilterAutocompleteOptions> GetFilterAutocompleteOptionsAsync(int labId, CancellationToken cancellationToken = default);
    Task<int> AssignReviewerByInsightAsync(int labId, string denialCode, string payerName, string reviewerUserName, string? runId, CancellationToken cancellationToken = default);
    Task<int> UpdateReviewerTaskAsync(int labId, string taskId, string status, string comments, string reviewerUserName, string? runId, CancellationToken cancellationToken = default);
    Task<TaskBoardUploadResult> UpdateTaskBoardAsync(int labId, IReadOnlyList<TaskBoardCsvUpdate> updates, CancellationToken cancellationToken = default);
}

public sealed class DenialDashboardApiClient : IDenialDashboardApiClient
{
    private readonly HttpClient _http;
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly WorkflowJwtIssuer _jwtIssuer;

    public DenialDashboardApiClient(HttpClient http, IOptions<DenialWorkflowOptions> options, IHttpContextAccessor httpContextAccessor, WorkflowJwtIssuer jwtIssuer)
    {
        _http = http;
        _httpContextAccessor = httpContextAccessor;
        _jwtIssuer = jwtIssuer;

        var baseUrl = options.Value.BaseUrl?.Trim() ?? string.Empty;
        if (TryBuildBaseUri(baseUrl, out var baseUri))
        {
            _http.BaseAddress = baseUri;
        }
    }

    public async Task<IReadOnlyList<LabOption>> GetLabsAsync(CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        return await _http.GetFromJsonAsync<List<LabOption>>("api/denial-dashboard/labs", cancellationToken) ?? new List<LabOption>();
    }

    public async Task<string?> GetCurrentRunIdAsync(int labId, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        var response = await _http.GetFromJsonAsync<CurrentRunResponse>($"api/denial-dashboard/current-run?labId={labId}", cancellationToken);
        return response?.RunId;
    }

    public async Task<IReadOnlyList<DenialRecord>> GetByLabAsync(int labId, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        return await _http.GetFromJsonAsync<List<DenialRecord>>($"api/denial-dashboard/records?labId={labId}", cancellationToken) ?? new List<DenialRecord>();
    }

    public async Task<IReadOnlyList<DenialInsightRecord>> GetInsightTableByLabAsync(int labId, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        return await _http.GetFromJsonAsync<List<DenialInsightRecord>>($"api/denial-dashboard/insights?labId={labId}", cancellationToken) ?? new List<DenialInsightRecord>();
    }

    public async Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsByLabAsync(int labId, int page, int pageSize, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        using var response = await _http.PostAsJsonAsync($"api/denial-dashboard/line-items?labId={labId}&page={page}&pageSize={pageSize}", filters, cancellationToken);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<List<DenialLineItemRecord>>(cancellationToken: cancellationToken) ?? new List<DenialLineItemRecord>();
    }

    public async Task<int> GetLineItemCountByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        using var response = await _http.PostAsJsonAsync($"api/denial-dashboard/line-items/count?labId={labId}", filters, cancellationToken);
        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<CountResponse>(cancellationToken: cancellationToken);
        return payload?.Count ?? 0;
    }

    public async Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsForExportByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        using var response = await _http.PostAsJsonAsync($"api/denial-dashboard/line-items/export?labId={labId}", filters, cancellationToken);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<List<DenialLineItemRecord>>(cancellationToken: cancellationToken) ?? new List<DenialLineItemRecord>();
    }

    public async Task<IReadOnlyList<DenialBreakdownSourceRecord>> GetBreakdownSourceByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        using var response = await _http.PostAsJsonAsync($"api/denial-dashboard/breakdown-source?labId={labId}", filters, cancellationToken);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<List<DenialBreakdownSourceRecord>>(cancellationToken: cancellationToken) ?? new List<DenialBreakdownSourceRecord>();
    }

    public async Task<DenialFilterAutocompleteOptions> GetFilterAutocompleteOptionsAsync(int labId, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        return await _http.GetFromJsonAsync<DenialFilterAutocompleteOptions>($"api/denial-dashboard/autocomplete?labId={labId}", cancellationToken) ?? new DenialFilterAutocompleteOptions();
    }

    public async Task<int> AssignReviewerByInsightAsync(int labId, string denialCode, string payerName, string reviewerUserName, string? runId, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        using var response = await _http.PostAsJsonAsync("api/denial-dashboard/assign-insight", new
        {
            labId,
            denialCode,
            payerName,
            reviewerUserName,
            runId
        }, cancellationToken);
        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<RowsAffectedResponse>(cancellationToken: cancellationToken);
        return payload?.RowsAffected ?? 0;
    }

    public async Task<int> UpdateReviewerTaskAsync(int labId, string taskId, string status, string comments, string reviewerUserName, string? runId, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        using var response = await _http.PostAsJsonAsync("api/denial-dashboard/update-task", new
        {
            labId,
            taskId,
            status,
            comments,
            reviewerUserName,
            runId
        }, cancellationToken);
        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<RowsAffectedResponse>(cancellationToken: cancellationToken);
        return payload?.RowsAffected ?? 0;
    }

    public async Task<TaskBoardUploadResult> UpdateTaskBoardAsync(int labId, IReadOnlyList<TaskBoardCsvUpdate> updates, CancellationToken cancellationToken = default)
    {
        await AuthorizeAsync(cancellationToken);
        using var response = await _http.PostAsJsonAsync($"api/denial-dashboard/task-board/update?labId={labId}", updates, cancellationToken);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<TaskBoardUploadResult>(cancellationToken: cancellationToken) ?? new TaskBoardUploadResult();
    }

    private async Task AuthorizeAsync(CancellationToken cancellationToken)
    {
        EnsureBaseAddressConfigured();

        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true) return;
        var tokenResult = await _jwtIssuer.CreateTokenAsync(user, cancellationToken);
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", tokenResult.Token);
    }

    private void EnsureBaseAddressConfigured()
    {
        if (_http.BaseAddress != null) return;

        throw new InvalidOperationException(
            "DenialWorkflowApi:BaseUrl is missing or invalid. Set it in LabMetricsDashboard appsettings.json. " +
            "Example: \"DenialWorkflowApi\": { \"BaseUrl\": \"https://www.lrnanalytics.com/lrnapi/\" }");
    }

    private static bool TryBuildBaseUri(string? configuredBaseUrl, out Uri? baseUri)
    {
        baseUri = null;
        if (string.IsNullOrWhiteSpace(configuredBaseUrl)) return false;

        var value = configuredBaseUrl.Trim();
        if (!value.EndsWith("/", StringComparison.Ordinal)) value += "/";

        return Uri.TryCreate(value, UriKind.Absolute, out baseUri)
            && (baseUri.Scheme == Uri.UriSchemeHttp || baseUri.Scheme == Uri.UriSchemeHttps);
    }

    private sealed class CurrentRunResponse
    {
        public string? RunId { get; set; }
    }

    private sealed class CountResponse
    {
        public int Count { get; set; }
    }

    private sealed class RowsAffectedResponse
    {
        public int RowsAffected { get; set; }
    }
}
