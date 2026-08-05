using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services;

public interface IMasterValuesApiClient
{
    Task<MasterPagedResult<InsurancePayerMasterDto>> GetInsurancePayersAsync(IQueryCollection query, CancellationToken ct);
    Task<InsurancePayerMasterDto?> GetInsurancePayerAsync(int id, CancellationToken ct);
    Task SaveInsurancePayerAsync(int? id, InsurancePayerMasterDto dto, CancellationToken ct);
    Task UpdateInsuranceStatusAsync(int id, string? isActive, CancellationToken ct);
    Task<ImportResultDto> ImportInsuranceAsync(IFormFile file, CancellationToken ct);
    Task<GlobalPayerIdConflictResolutionResult> ResolveInsuranceConflictsAsync(GlobalPayerIdConflictResolutionRequest request, CancellationToken ct);
    Task<(byte[] Content, string FileName)> ExportInsuranceAsync(IQueryCollection query, CancellationToken ct);

    Task<MasterPagedResult<PayerPolicyInsuranceMasterDto>> GetPolicyPayersAsync(IQueryCollection query, CancellationToken ct);
    Task<PayerPolicyInsuranceMasterDto?> GetPolicyPayerAsync(int id, CancellationToken ct);
    Task SavePolicyPayerAsync(int? id, PayerPolicyInsuranceMasterDto dto, CancellationToken ct);
    Task<int> GetPolicyNextGlobalPayerIdAsync(CancellationToken ct);
    Task UpdatePolicyStatusAsync(int id, string? isActive, CancellationToken ct);
    Task<ImportResultDto> ImportPolicyAsync(IFormFile file, CancellationToken ct);
    Task<(byte[] Content, string FileName)> ExportPolicyAsync(IQueryCollection query, CancellationToken ct);
    Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct);

    // Payer mapping rules admin (single-page CRUD over the 6 rule tables) - raw JSON passthrough,
    // the API is the single source of truth for the table metadata and validation.
    Task<string> GetPayerRulesRawAsync(string path, CancellationToken ct);
    Task<string> SendPayerRulesRawAsync(HttpMethod method, string path, string jsonBody, CancellationToken ct);

    // Report Audit Log - raw JSON passthrough: the report-status columns are built from
    // ReportTypeMaster at execution time, so there is no fixed DTO to bind them to.
    Task<string> GetReportAuditRawAsync(string path, IQueryCollection query, CancellationToken ct);
    Task<(byte[] Content, string FileName)> ExportReportAuditLogsAsync(IQueryCollection query, CancellationToken ct);

    // Payer mapping intelligence (LRN.PayerPolicyMapper pipeline endpoints)
    Task<PayerMappingSuggestionsResponse?> GetMappingSuggestionsAsync(int labInsuranceMasterId, CancellationToken ct);
    Task<IReadOnlyList<PayerPolicySearchResultDto>> SearchPolicyPayersRankedAsync(string query, CancellationToken ct);
    Task<PayerMappingActionResult> ApproveMappingAsync(int labInsuranceMasterId, PayerMappingActionRequest request, CancellationToken ct);
    Task<PayerMappingActionResult> ManualMapAsync(int labInsuranceMasterId, PayerMappingActionRequest request, CancellationToken ct);
    Task<PayerMappingActionResult> RejectMappingAsync(int labInsuranceMasterId, CancellationToken ct);
    Task<PayerMappingActionResult> UnmapMappingAsync(int labInsuranceMasterId, CancellationToken ct);
    Task<MappingStatusSummaryDto> GetMappingSummaryAsync(CancellationToken ct);

    // Payer Service Audit (worker run history + manual trigger)
    Task<PayerMapperRunListResponse> GetPayerServiceRunsAsync(int page, int pageSize, CancellationToken ct);
    Task<PayerMapperRunDetailsResponse?> GetPayerServiceRunAsync(Guid runId, CancellationToken ct);
    Task<PayerMapperTriggerResult> TriggerPayerServiceRunAsync(string scope, CancellationToken ct);

    Task<MasterPagedResult<PayerMasterApprovalRequestDto>> GetApprovalsAsync(IQueryCollection query, CancellationToken ct);
    Task<PayerMasterApprovalDecisionResult> ApproveRequestsAsync(PayerMasterApprovalDecisionRequest request, CancellationToken ct);
    Task<PayerMasterApprovalDecisionResult> RejectRequestsAsync(PayerMasterApprovalDecisionRequest request, CancellationToken ct);
    Task<MasterPagedResult<PayerMasterAuditEntryDto>> GetAuditAsync(IQueryCollection query, CancellationToken ct);
    Task<IReadOnlyList<PayerMasterNotificationDto>> GetNotificationsAsync(int take, CancellationToken ct);
}

public sealed class MasterValuesApiClient : IMasterValuesApiClient
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly HttpClient _http;
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly WorkflowJwtIssuer _jwtIssuer;

    public MasterValuesApiClient(HttpClient http, IOptions<DenialWorkflowOptions> options, IHttpContextAccessor httpContextAccessor, WorkflowJwtIssuer jwtIssuer)
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

    public async Task<MasterPagedResult<InsurancePayerMasterDto>> GetInsurancePayersAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<MasterPagedResult<InsurancePayerMasterDto>>("api/master-values/insurance-payers" + Query(query), ct) ?? new();

    public async Task<InsurancePayerMasterDto?> GetInsurancePayerAsync(int id, CancellationToken ct)
        => await GetAsync<InsurancePayerMasterDto>($"api/master-values/insurance-payers/{id}", ct);

    public Task SaveInsurancePayerAsync(int? id, InsurancePayerMasterDto dto, CancellationToken ct)
        => SendJsonAsync(id.HasValue ? HttpMethod.Put : HttpMethod.Post, id.HasValue ? $"api/master-values/insurance-payers/{id}" : "api/master-values/insurance-payers", dto, ct);

    public Task UpdateInsuranceStatusAsync(int id, string? isActive, CancellationToken ct)
        => SendJsonAsync(HttpMethod.Patch, $"api/master-values/insurance-payers/{id}/status", new { isActive }, ct);

    public Task<ImportResultDto> ImportInsuranceAsync(IFormFile file, CancellationToken ct)
        => ImportAsync("api/master-values/insurance-payers/import", file, ct);

    public Task<GlobalPayerIdConflictResolutionResult> ResolveInsuranceConflictsAsync(GlobalPayerIdConflictResolutionRequest request, CancellationToken ct)
        => PostForResultAsync<GlobalPayerIdConflictResolutionRequest, GlobalPayerIdConflictResolutionResult>("api/master-values/insurance-payers/import/resolve-conflicts", request, ct);

    public Task<(byte[] Content, string FileName)> ExportInsuranceAsync(IQueryCollection query, CancellationToken ct)
        => ExportAsync("api/master-values/insurance-payers/export" + Query(query), "InsurancePayerMaster.xlsx", ct);

    public async Task<MasterPagedResult<PayerPolicyInsuranceMasterDto>> GetPolicyPayersAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<MasterPagedResult<PayerPolicyInsuranceMasterDto>>("api/master-values/payer-policy-insurance" + Query(query), ct) ?? new();

    public async Task<PayerPolicyInsuranceMasterDto?> GetPolicyPayerAsync(int id, CancellationToken ct)
        => await GetAsync<PayerPolicyInsuranceMasterDto>($"api/master-values/payer-policy-insurance/{id}", ct);

    public Task SavePolicyPayerAsync(int? id, PayerPolicyInsuranceMasterDto dto, CancellationToken ct)
        => SendJsonAsync(id.HasValue ? HttpMethod.Put : HttpMethod.Post, id.HasValue ? $"api/master-values/payer-policy-insurance/{id}" : "api/master-values/payer-policy-insurance", dto, ct);

    public async Task<int> GetPolicyNextGlobalPayerIdAsync(CancellationToken ct)
        => (await GetAsync<NextGlobalIdResponse>("api/master-values/payer-policy-insurance/next-global-id", ct))?.NextGlobalPayerId ?? 0;

    private sealed record NextGlobalIdResponse(int NextGlobalPayerId);

    public Task UpdatePolicyStatusAsync(int id, string? isActive, CancellationToken ct)
        => SendJsonAsync(HttpMethod.Patch, $"api/master-values/payer-policy-insurance/{id}/status", new { isActive }, ct);

    public Task<ImportResultDto> ImportPolicyAsync(IFormFile file, CancellationToken ct)
        => ImportAsync("api/master-values/payer-policy-insurance/import", file, ct);

    public Task<(byte[] Content, string FileName)> ExportPolicyAsync(IQueryCollection query, CancellationToken ct)
        => ExportAsync("api/master-values/payer-policy-insurance/export" + Query(query), "PayerPolicyInsuranceMaster.xlsx", ct);

    public async Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct)
        => await GetAsync<List<MasterValueLabOption>>("api/master-values/insurance-payers/labs", ct) ?? [];

    public Task<PayerMappingSuggestionsResponse?> GetMappingSuggestionsAsync(int labInsuranceMasterId, CancellationToken ct)
        => GetAsync<PayerMappingSuggestionsResponse>($"api/master-values/insurance-payers/{labInsuranceMasterId}/suggestions", ct);

    public async Task<IReadOnlyList<PayerPolicySearchResultDto>> SearchPolicyPayersRankedAsync(string query, CancellationToken ct)
        => await GetAsync<List<PayerPolicySearchResultDto>>($"api/master-values/payer-policy-insurance/search?q={Uri.EscapeDataString(query)}", ct) ?? [];

    public Task<PayerMappingActionResult> ApproveMappingAsync(int labInsuranceMasterId, PayerMappingActionRequest request, CancellationToken ct)
        => PostForResultAsync<PayerMappingActionRequest, PayerMappingActionResult>($"api/master-values/insurance-payers/{labInsuranceMasterId}/mapping/approve", request, ct);

    public Task<PayerMappingActionResult> ManualMapAsync(int labInsuranceMasterId, PayerMappingActionRequest request, CancellationToken ct)
        => PostForResultAsync<PayerMappingActionRequest, PayerMappingActionResult>($"api/master-values/insurance-payers/{labInsuranceMasterId}/mapping/manual", request, ct);

    public Task<PayerMappingActionResult> RejectMappingAsync(int labInsuranceMasterId, CancellationToken ct)
        => PostForResultAsync<object, PayerMappingActionResult>($"api/master-values/insurance-payers/{labInsuranceMasterId}/mapping/reject", new { }, ct);

    public Task<PayerMappingActionResult> UnmapMappingAsync(int labInsuranceMasterId, CancellationToken ct)
        => PostForResultAsync<object, PayerMappingActionResult>($"api/master-values/insurance-payers/{labInsuranceMasterId}/mapping/unmap", new { }, ct);

    public async Task<MappingStatusSummaryDto> GetMappingSummaryAsync(CancellationToken ct)
        => await GetAsync<MappingStatusSummaryDto>("api/master-values/insurance-payers/mapping-summary", ct) ?? new();

    public async Task<PayerMapperRunListResponse> GetPayerServiceRunsAsync(int page, int pageSize, CancellationToken ct)
        => await GetAsync<PayerMapperRunListResponse>($"api/master-values/payer-mapper/runs?page={page}&pageSize={pageSize}", ct) ?? new();

    public Task<PayerMapperRunDetailsResponse?> GetPayerServiceRunAsync(Guid runId, CancellationToken ct)
        => GetAsync<PayerMapperRunDetailsResponse>($"api/master-values/payer-mapper/runs/{runId}", ct);

    public Task<PayerMapperTriggerResult> TriggerPayerServiceRunAsync(string scope, CancellationToken ct)
        => PostForResultAsync<object, PayerMapperTriggerResult>("api/master-values/payer-mapper/runs/trigger", new { scope }, ct);

    public async Task<MasterPagedResult<PayerMasterApprovalRequestDto>> GetApprovalsAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<MasterPagedResult<PayerMasterApprovalRequestDto>>("api/master-values/workflow/approvals" + Query(query), ct) ?? new();

    public Task<PayerMasterApprovalDecisionResult> ApproveRequestsAsync(PayerMasterApprovalDecisionRequest request, CancellationToken ct)
        => PostForResultAsync<PayerMasterApprovalDecisionRequest, PayerMasterApprovalDecisionResult>("api/master-values/workflow/approvals/approve", request, ct);

    public Task<PayerMasterApprovalDecisionResult> RejectRequestsAsync(PayerMasterApprovalDecisionRequest request, CancellationToken ct)
        => PostForResultAsync<PayerMasterApprovalDecisionRequest, PayerMasterApprovalDecisionResult>("api/master-values/workflow/approvals/reject", request, ct);

    public async Task<MasterPagedResult<PayerMasterAuditEntryDto>> GetAuditAsync(IQueryCollection query, CancellationToken ct)
        => await GetAsync<MasterPagedResult<PayerMasterAuditEntryDto>>("api/master-values/workflow/audit" + Query(query), ct) ?? new();

    public async Task<IReadOnlyList<PayerMasterNotificationDto>> GetNotificationsAsync(int take, CancellationToken ct)
        => await GetAsync<List<PayerMasterNotificationDto>>($"api/master-values/workflow/notifications?take={take}", ct) ?? [];

    public async Task<string> GetReportAuditRawAsync(string path, IQueryCollection query, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.GetAsync("api/master-values/report-audit-log/" + path + Query(query), ct);
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadAsStringAsync(ct);
    }

    public Task<(byte[] Content, string FileName)> ExportReportAuditLogsAsync(IQueryCollection query, CancellationToken ct)
        => ExportAsync("api/master-values/report-audit-log/logs/export" + Query(query), "ReportAuditLog.csv", ct);

    public async Task<string> GetPayerRulesRawAsync(string path, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.GetAsync("api/master-values/payer-rules/" + path, ct);
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadAsStringAsync(ct);
    }

    public async Task<string> SendPayerRulesRawAsync(HttpMethod method, string path, string jsonBody, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var request = new HttpRequestMessage(method, "api/master-values/payer-rules/" + path)
        {
            Content = new StringContent(string.IsNullOrWhiteSpace(jsonBody) ? "{}" : jsonBody, Encoding.UTF8, "application/json")
        };
        using var response = await _http.SendAsync(request, ct);
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadAsStringAsync(ct);
    }

    private async Task<TResult> PostForResultAsync<TPayload, TResult>(string url, TPayload payload, CancellationToken ct) where TResult : new()
    {
        await AuthorizeAsync(ct);
        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
        };
        using var response = await _http.SendAsync(request, ct);
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadFromJsonAsync<TResult>(JsonOptions, ct) ?? new TResult();
    }

    private async Task<T?> GetAsync<T>(string url, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.GetAsync(url, ct);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return default;
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct);
    }

    private async Task SendJsonAsync<T>(HttpMethod method, string url, T payload, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var request = new HttpRequestMessage(method, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
        };
        using var response = await _http.SendAsync(request, ct);
        await EnsureSuccessAsync(response, ct);
    }

    private async Task<ImportResultDto> ImportAsync(string url, IFormFile file, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var form = new MultipartFormDataContent();
        await using var stream = file.OpenReadStream();
        using var content = new StreamContent(stream);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        form.Add(content, "File", file.FileName);
        using var response = await _http.PostAsync(url, form, ct);
        await EnsureSuccessAsync(response, ct);
        return await response.Content.ReadFromJsonAsync<ImportResultDto>(JsonOptions, ct) ?? new();
    }

    private async Task<(byte[] Content, string FileName)> ExportAsync(string url, string fallbackName, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.GetAsync(url, ct);
        await EnsureSuccessAsync(response, ct);
        var fileName = response.Content.Headers.ContentDisposition?.FileNameStar
            ?? response.Content.Headers.ContentDisposition?.FileName?.Trim('"')
            ?? fallbackName;
        return (await response.Content.ReadAsByteArrayAsync(ct), fileName);
    }

    private async Task AuthorizeAsync(CancellationToken ct)
    {
        if (_http.BaseAddress == null) throw new InvalidOperationException("Master Values API base URL is missing or invalid. Configure DenialWorkflowApi:BaseUrl to the LRN.ReportsApi URL.");
        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true) return;
        var token = await _jwtIssuer.CreateTokenAsync(user, ct);
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.IsSuccessStatusCode) return;
        var body = await response.Content.ReadAsStringAsync(ct);
        throw new InvalidOperationException(string.IsNullOrWhiteSpace(body) ? $"API request failed: {(int)response.StatusCode}" : body);
    }

    private static string Query(IQueryCollection query)
    {
        var pairs = query
            .Where(x => !string.Equals(x.Key, "id", StringComparison.OrdinalIgnoreCase))
            .SelectMany(x => x.Value, (x, v) => $"{Uri.EscapeDataString(x.Key)}={Uri.EscapeDataString(v ?? string.Empty)}");
        var text = string.Join("&", pairs);
        return string.IsNullOrWhiteSpace(text) ? string.Empty : "?" + text;
    }
}
