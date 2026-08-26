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
        var maxTokens = Math.Max(1000, _options.MaxCompletionTokens);
        // gpt-5-mini counts reasoning toward max_completion_tokens; empty content
        // usually means finish_reason=length. Retry once with a larger budget.
        var attemptBudgets = new[] { maxTokens, Math.Max(maxTokens * 2, 16_000) };

        Exception? last = null;
        for (var attempt = 0; attempt < attemptBudgets.Length; attempt++)
        {
            try
            {
                return await CompleteOnceAsync(systemPrompt, userPrompt, attemptBudgets[attempt], attempt + 1, ct);
            }
            catch (EmptyFoundryContentException ex)
            {
                last = ex;
                _logger.LogWarning(
                    "[Foundry] Empty content on attempt {Attempt} (max_completion_tokens={Tokens}, finish={Finish}). {Detail}",
                    attempt + 1, attemptBudgets[attempt], ex.FinishReason, ex.Message);
                if (attempt == attemptBudgets.Length - 1 || !ex.Retryable)
                    break;
            }
        }

        throw last ?? new InvalidOperationException("Foundry returned an empty message content.");
    }

    private async Task<string> CompleteOnceAsync(
        string systemPrompt,
        string userPrompt,
        int maxCompletionTokens,
        int attempt,
        CancellationToken ct)
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
            ["max_completion_tokens"] = maxCompletionTokens,
            ["response_format"] = new { type = "json_object" },
        };

        req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

        _logger.LogInformation(
            "[Foundry] Calling deployment '{Deployment}' (attempt {Attempt}, max_completion_tokens={Tokens})",
            _options.DeploymentName, attempt, maxCompletionTokens);

        using var resp = await http.SendAsync(req, ct);
        var raw = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Foundry HTTP {(int)resp.StatusCode}: {Trim(raw, 2000)}");

        using var doc = JsonDocument.Parse(raw);
        var root = doc.RootElement;
        if (!root.TryGetProperty("choices", out var choices) || choices.GetArrayLength() == 0)
            throw new InvalidOperationException($"Foundry response has no choices: {Trim(raw, 2000)}");

        var choice = choices[0];
        var finishReason = choice.TryGetProperty("finish_reason", out var fr) ? fr.GetString() ?? "" : "";
        var message = choice.GetProperty("message");

        var content = message.TryGetProperty("content", out var contentEl) && contentEl.ValueKind == JsonValueKind.String
            ? contentEl.GetString()
            : null;

        var refusal = message.TryGetProperty("refusal", out var refusalEl) && refusalEl.ValueKind == JsonValueKind.String
            ? refusalEl.GetString()
            : null;

        string? usageSummary = null;
        if (root.TryGetProperty("usage", out var usage))
            usageSummary = usage.GetRawText();

        if (!string.IsNullOrWhiteSpace(content))
        {
            _logger.LogInformation(
                "[Foundry] OK finish={Finish} usage={Usage}",
                finishReason, usageSummary ?? "(none)");
            return StripFence(content);
        }

        var detail =
            $"finish_reason={finishReason}; refusal={refusal ?? "(none)"}; usage={usageSummary ?? "(none)"}; raw={Trim(raw, 1200)}";
        var retryable = string.Equals(finishReason, "length", StringComparison.OrdinalIgnoreCase)
                        || string.IsNullOrWhiteSpace(finishReason);
        throw new EmptyFoundryContentException(
            "Foundry returned an empty message content. " + detail,
            finishReason,
            retryable);
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

    private sealed class EmptyFoundryContentException : InvalidOperationException
    {
        public string FinishReason { get; }
        public bool Retryable { get; }

        public EmptyFoundryContentException(string message, string finishReason, bool retryable)
            : base(message)
        {
            FinishReason = finishReason;
            Retryable = retryable;
        }
    }
}
