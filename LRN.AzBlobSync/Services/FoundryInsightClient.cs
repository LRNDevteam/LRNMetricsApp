using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using LRN.AzBlobSync.Models;

namespace LRN.AzBlobSync.Services;

public sealed class FoundryInsightClient
{
    private readonly FoundryOptions _options;
    private readonly KeyVaultSecretReader _secrets;
    private readonly ILogger<FoundryInsightClient> _logger;

    public FoundryInsightClient(
        FoundryOptions options,
        KeyVaultSecretReader secrets,
        ILogger<FoundryInsightClient> logger)
    {
        _options = options;
        _secrets = secrets;
        _logger = logger;
    }

    public async Task<string> CompleteJsonAsync(string systemPrompt, string userPrompt, CancellationToken ct)
    {
        var apiKey = await ResolveApiKeyAsync(ct);
        var endpoint = (_options.AzureOpenAiEndpoint ?? string.Empty).Trim().TrimEnd('/');
        if (string.IsNullOrWhiteSpace(endpoint))
            throw new InvalidOperationException("Foundry:AzureOpenAiEndpoint is empty.");

        var deployment = Uri.EscapeDataString(_options.DeploymentName);
        var apiVersion = Uri.EscapeDataString(_options.ApiVersion);
        var url = $"{endpoint}/openai/deployments/{deployment}/chat/completions?api-version={apiVersion}";

        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(Math.Max(30, _options.TimeoutSeconds)) };
        using var req = new HttpRequestMessage(HttpMethod.Post, url);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        req.Headers.TryAddWithoutValidation("api-key", apiKey);

        var body = new Dictionary<string, object?>
        {
            ["messages"] = new object[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = userPrompt },
            },
            ["max_completion_tokens"] = _options.MaxCompletionTokens,
            ["response_format"] = new { type = "json_object" },
        };

        req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

        _logger.LogInformation(
            "[Foundry] Calling deployment '{Deployment}'",
            _options.DeploymentName);

        using var resp = await http.SendAsync(req, ct);
        var raw = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Foundry HTTP {(int)resp.StatusCode}: {Trim(raw, 2000)}");

        using var doc = JsonDocument.Parse(raw);
        var content = doc.RootElement
            .GetProperty("choices")[0]
            .GetProperty("message")
            .GetProperty("content")
            .GetString();

        if (string.IsNullOrWhiteSpace(content))
            throw new InvalidOperationException("Foundry returned an empty message content.");

        return StripFence(content);
    }

    private async Task<string> ResolveApiKeyAsync(CancellationToken ct)
    {
        var env = Environment.GetEnvironmentVariable("FOUNDRY_API_KEY")
            ?? Environment.GetEnvironmentVariable("AZURE_OPENAI_API_KEY");
        if (!string.IsNullOrWhiteSpace(env))
            return env.Trim();

        if (string.IsNullOrWhiteSpace(_options.ApiKeySecretName))
            throw new InvalidOperationException("Set FOUNDRY_API_KEY or Foundry:ApiKeySecretName.");

        return await _secrets.GetSecretAsync(_options.ApiKeySecretName, ct);
    }

    private static string StripFence(string text)
    {
        var t = text.Trim();
        if (!t.StartsWith("```", StringComparison.Ordinal))
            return t;

        var firstNl = t.IndexOf('\n');
        if (firstNl < 0)
            return t;
        t = t[(firstNl + 1)..];
        var end = t.LastIndexOf("```", StringComparison.Ordinal);
        return end >= 0 ? t[..end].Trim() : t.Trim();
    }

    private static string Trim(string s, int max)
        => s.Length <= max ? s : s[..max] + "…";
}
