using System.Net.Http.Json;
using DenialDatabaseProcessorWorker.Models.Workflow;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services.Workflow;

public interface IDenialWorkflowApiClient
{
    Task<DenialWorkflowImportResult?> ImportAsync(DenialTaskImportRequest request, CancellationToken ct);
}

public sealed class DenialWorkflowApiClient : IDenialWorkflowApiClient
{
    private readonly HttpClient _http;
    private readonly DenialWorkflowApiOptions _options;

    public DenialWorkflowApiClient(HttpClient http, IOptions<DenialWorkflowApiOptions> options)
    {
        _http = http;
        _options = options.Value;
        _http.BaseAddress = new Uri(_options.BaseUrl.TrimEnd('/') + "/");
    }

    public async Task<DenialWorkflowImportResult?> ImportAsync(DenialTaskImportRequest request, CancellationToken ct)
    {
        if (!_options.Enabled) return null;
        using var response = await _http.PostAsJsonAsync("api/denial-workflow/import", request, ct);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<DenialWorkflowImportResult>(cancellationToken: ct);
    }
}
