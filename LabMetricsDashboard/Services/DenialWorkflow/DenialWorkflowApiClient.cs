using System.Net.Http.Headers;
using System.Net.Http.Json;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services.DenialWorkflow;

public interface IDenialWorkflowApiClient
{
    Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct);
    Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(DenialWorkflowFilter filter, CancellationToken ct);
    Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct);
    Task<int> UpdateTaskAsync(UpdateTaskRequest request, CancellationToken ct);
    Task<int> DecideVerificationAsync(VerificationDecisionRequest request, CancellationToken ct);
}

public sealed class DenialWorkflowApiClient : IDenialWorkflowApiClient
{
    private readonly HttpClient _http;
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly WorkflowJwtIssuer _jwtIssuer;

    public DenialWorkflowApiClient(HttpClient http, IOptions<DenialWorkflowOptions> options, IHttpContextAccessor httpContextAccessor, WorkflowJwtIssuer jwtIssuer)
    {
        _http = http;
        _http.BaseAddress = new Uri(options.Value.BaseUrl.TrimEnd('/') + "/");
        _httpContextAccessor = httpContextAccessor;
        _jwtIssuer = jwtIssuer;
    }

    public async Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        return await _http.GetFromJsonAsync<DenialWorkflowSummary>($"api/denial-workflow/summary?labId={labId}&role={Uri.EscapeDataString(role)}&userName={Uri.EscapeDataString(userName)}", ct) ?? new();
    }

    public async Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        return await _http.GetFromJsonAsync<List<ReviewerWorkflowSummaryRow>>("api/denial-workflow/reviewer-summary" + ToQueryString(filter), ct) ?? [];
    }

    public async Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        return await _http.GetFromJsonAsync<PagedResult<WorkflowTaskRow>>("api/denial-workflow/tasks" + ToQueryString(filter), ct) ?? new();
    }

	public async Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(
		DenialWorkflowFilter filter,
		CancellationToken ct = default)
	{
			await AuthorizeAsync(ct);
	using var response = await _http.GetAsync(
			"api/denial-workflow/verification" + ToQueryString(filter),
			ct);

		if (!response.IsSuccessStatusCode)
		{
			var error = await response.Content.ReadAsStringAsync(ct);

			return new PagedResult<VerificationTaskRow>
			{
				Items = new List<VerificationTaskRow>(),
				Page = filter.Page,
				PageSize = filter.PageSize,
				TotalRecords = 0,
				ErrorMessage = error
			};
		}

		return await response.Content.ReadFromJsonAsync<PagedResult<VerificationTaskRow>>(cancellationToken: ct)
			?? new PagedResult<VerificationTaskRow>
			{
				Items = new List<VerificationTaskRow>(),
				Page = filter.Page,
				PageSize = filter.PageSize,
				TotalRecords = 0
			};
	}
	public async Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct)
        => await PostForRowsAffectedAsync("api/denial-workflow/assign-insight", request, ct);

    public async Task<int> UpdateTaskAsync(UpdateTaskRequest request, CancellationToken ct)
        => await PostForRowsAffectedAsync("api/denial-workflow/update-task", request, ct);

    public async Task<int> DecideVerificationAsync(VerificationDecisionRequest request, CancellationToken ct)
        => await PostForRowsAffectedAsync("api/denial-workflow/decide-verification", request, ct);

    private async Task AuthorizeAsync(CancellationToken ct)
    {
        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true) return;
        var tokenResult = await _jwtIssuer.CreateTokenAsync(user, ct);
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", tokenResult.Token);
    }

    private static string ToQueryString(DenialWorkflowFilter f)
    {
        var values = new Dictionary<string, string?>
        {
            ["labId"] = f.LabId.ToString(), ["role"] = f.Role, ["userName"] = f.UserName, ["runId"] = f.RunId, ["status"] = f.Status,
            ["assignedTo"] = f.AssignedTo, ["denialCode"] = f.DenialCode, ["payerName"] = f.PayerName, ["searchText"] = f.SearchText,
            ["fromDate"] = f.FromDate?.ToString("yyyy-MM-dd"), ["toDate"] = f.ToDate?.ToString("yyyy-MM-dd"), ["page"] = f.Page.ToString(), ["pageSize"] = f.PageSize.ToString()
        };
        return "?" + string.Join("&", values.Where(x => !string.IsNullOrWhiteSpace(x.Value)).Select(x => $"{Uri.EscapeDataString(x.Key)}={Uri.EscapeDataString(x.Value!)}"));
    }

    private async Task<int> PostForRowsAffectedAsync<T>(string url, T payload, CancellationToken ct)
    {
        await AuthorizeAsync(ct);
        using var response = await _http.PostAsJsonAsync(url, payload, ct);
        response.EnsureSuccessStatusCode();
        var result = await response.Content.ReadFromJsonAsync<DenialWorkflowResult>(cancellationToken: ct);
        return result?.RowsAffected ?? 0;
    }
}
