using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads the Report Control Board data from LRN.ReportsApi (which owns the
/// usp_ReportsWorkflowTracker_Pivot call).
///
/// Never throws to the page: a tracker outage returns <see cref="ReportBoardFetch.Error"/> together
/// with the last good copy, so the board degrades to "stale, and here is why" instead of a blank
/// grid or a 500.
/// </summary>
public interface IReportBoardApiClient
{
    Task<ReportBoardFetch> GetLatestAsync(bool refresh, CancellationToken ct);
    Task<RunErrorsResult> GetRunErrorsAsync(string runId, string? labName, string? reportType, CancellationToken ct);
    /// <summary>Downloads the run's Error-log CSV (usp_ReportRunIdInfoLog_Get, @logtype='Error'). Null on failure.</summary>
    Task<ReportErrorCsv?> GetRunErrorsCsvAsync(string runId, string? reportType, CancellationToken ct);
}

/// <summary>Outcome of a board fetch. <see cref="Data"/> may be a stale copy when Error is set.</summary>
public sealed record ReportBoardFetch(ReportBoardApiResult? Data, string? Error, DateTime? FetchedAt);

/// <summary>A downloaded error-log CSV, ready to stream back to the browser.</summary>
public sealed record ReportErrorCsv(byte[] Content, string FileName, string ContentType);

public sealed class ReportBoardApiClient : IReportBoardApiClient
{
    private const string CacheKey = "ReportBoard_Latest";
    private const string LastGoodKey = "ReportBoard_LastGood";
    private static readonly TimeSpan CacheDuration = TimeSpan.FromMinutes(2);
    // The stale copy behind an error card is only useful while it is recognisably "this morning's run".
    private static readonly TimeSpan LastGoodDuration = TimeSpan.FromHours(12);
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private readonly HttpClient _http;
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly WorkflowJwtIssuer _jwtIssuer;
    private readonly IMemoryCache _cache;
    private readonly ILogger<ReportBoardApiClient> _logger;

    public ReportBoardApiClient(
        HttpClient http,
        IOptions<DenialWorkflowOptions> options,
        IHttpContextAccessor httpContextAccessor,
        WorkflowJwtIssuer jwtIssuer,
        IMemoryCache cache,
        ILogger<ReportBoardApiClient> logger)
    {
        _http = http;
        _httpContextAccessor = httpContextAccessor;
        _jwtIssuer = jwtIssuer;
        _cache = cache;
        _logger = logger;

        var baseUrl = options.Value.BaseUrl?.Trim();
        if (!string.IsNullOrWhiteSpace(baseUrl))
        {
            if (!baseUrl.EndsWith("/", StringComparison.Ordinal)) baseUrl += "/";
            if (Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)) _http.BaseAddress = uri;
        }
    }

    public async Task<ReportBoardFetch> GetLatestAsync(bool refresh, CancellationToken ct)
    {
        if (!refresh && _cache.TryGetValue<ReportBoardFetch>(CacheKey, out var cached) && cached is not null)
            return cached;

        try
        {
            await AuthorizeAsync(ct);
            using var response = await _http.GetAsync("api/report-board/latest?mode=Latest", ct);
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"Report tracker returned {(int)response.StatusCode}.");

            var data = await response.Content.ReadFromJsonAsync<ReportBoardApiResult>(JsonOptions, ct)
                       ?? new ReportBoardApiResult();
            var fetch = new ReportBoardFetch(data, null, DateTime.Now);

            _cache.Set(CacheKey, fetch, CacheDuration);
            _cache.Set(LastGoodKey, fetch, LastGoodDuration);
            return fetch;
        }
        catch (Exception ex)
        {
            // The board is a landing page; a tracker outage must not be a 500. Fall back to the last
            // good copy when there is one so the page can say how stale it is.
            _logger.LogWarning(ex, "Report board: the workflow tracker could not be read.");
            var lastGood = _cache.Get<ReportBoardFetch>(LastGoodKey);
            return new ReportBoardFetch(lastGood?.Data, DescribeError(ex), lastGood?.FetchedAt);
        }
    }

    public async Task<RunErrorsResult> GetRunErrorsAsync(string runId, string? labName, string? reportType, CancellationToken ct)
    {
        try
        {
            await AuthorizeAsync(ct);
            var url = $"api/report-board/run-errors?runId={Uri.EscapeDataString(runId)}"
                      + (string.IsNullOrWhiteSpace(labName) ? string.Empty : $"&labName={Uri.EscapeDataString(labName)}")
                      + (string.IsNullOrWhiteSpace(reportType) ? string.Empty : $"&reportType={Uri.EscapeDataString(reportType)}");
            using var response = await _http.GetAsync(url, ct);
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"Error log request returned {(int)response.StatusCode}.");
            return await response.Content.ReadFromJsonAsync<RunErrorsResult>(JsonOptions, ct) ?? new RunErrorsResult();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Report board: the error log for run {RunId} could not be read.", runId);
            return new RunErrorsResult { LoadError = DescribeError(ex) };
        }
    }

    public async Task<ReportErrorCsv?> GetRunErrorsCsvAsync(string runId, string? reportType, CancellationToken ct)
    {
        try
        {
            await AuthorizeAsync(ct);
            var url = $"api/report-board/run-errors/export?runId={Uri.EscapeDataString(runId)}"
                      + (string.IsNullOrWhiteSpace(reportType) ? string.Empty : $"&reportType={Uri.EscapeDataString(reportType)}");
            using var response = await _http.GetAsync(url, ct);
            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Report board: error CSV for run {RunId} returned {Status}.", runId, (int)response.StatusCode);
                return null;
            }
            var content = await response.Content.ReadAsByteArrayAsync(ct);
            var fileName = response.Content.Headers.ContentDisposition?.FileNameStar
                           ?? response.Content.Headers.ContentDisposition?.FileName?.Trim('"')
                           ?? $"RunErrors_{runId}.xlsx";
            var contentType = response.Content.Headers.ContentType?.MediaType
                              ?? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
            return new ReportErrorCsv(content, fileName, contentType);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Report board: the error CSV for run {RunId} could not be downloaded.", runId);
            return null;
        }
    }

    private static string DescribeError(Exception ex)
        => ex is InvalidOperationException && ex.Message.Contains("base URL", StringComparison.OrdinalIgnoreCase)
            ? ex.Message
            : "The report workflow tracker is not reachable right now.";

    private async Task AuthorizeAsync(CancellationToken ct)
    {
        if (_http.BaseAddress == null)
            throw new InvalidOperationException("The Reports API base URL is missing or invalid. Configure DenialWorkflowApi:BaseUrl.");
        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true) return;
        var token = await _jwtIssuer.CreateTokenAsync(user, ct);
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
    }
}
