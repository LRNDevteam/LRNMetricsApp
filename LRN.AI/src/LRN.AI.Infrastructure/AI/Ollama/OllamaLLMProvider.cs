using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using LRN.AI.Application.Abstractions;
using LRN.AI.Application.Common;
using LRN.AI.Application.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.AI.Infrastructure.AI.Ollama;

/// <summary>
/// <see cref="ILLMProvider"/> over the Ollama REST API: <c>GET /api/tags</c> and non-streaming <c>POST /api/chat</c>.
/// Logs operation, model, error code and HTTP status only, never request or response bodies.
/// </summary>
internal sealed class OllamaLLMProvider(
    HttpClient httpClient,
    IOptions<OllamaOptions> options,
    ILogger<OllamaLLMProvider> logger) : ILLMProvider
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public string ProviderName => "Ollama";

    public Task<IReadOnlyList<LLMModelInfo>> GetAvailableModelsAsync(CancellationToken cancellationToken) =>
        ExecuteAsync("list models", modelName: null, options.Value.ListTimeoutSeconds, async ct =>
        {
            using var response = await httpClient.GetAsync("api/tags", ct);
            EnsureSuccess(response, modelName: null);
            var body = await ReadJsonAsync<OllamaTagsResponse>(response, ct);
            if (body.Models is null)
                throw new LLMProviderException(LLMErrorCode.InvalidModelResponse, "Ollama /api/tags response has no models array.");

            IReadOnlyList<LLMModelInfo> models = body.Models
                .Where(m => !string.IsNullOrWhiteSpace(m.Name))
                .Select(m => new LLMModelInfo(m.Name!, m.Size, OllamaTimestamp.Parse(m.ModifiedAt)))
                .ToList();
            return models;
        }, cancellationToken);

    public Task<LLMResponse> GenerateAsync(LLMRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        return ExecuteAsync("chat", request.ModelName, options.Value.TimeoutSeconds, async ct =>
        {
            var stopwatch = Stopwatch.StartNew();
            using var response = await httpClient.PostAsJsonAsync("api/chat", BuildChatRequest(request), JsonOptions, ct);
            EnsureSuccess(response, request.ModelName);
            var body = await ReadJsonAsync<OllamaChatResponse>(response, ct);

            var content = body.Message?.Content;
            if (string.IsNullOrWhiteSpace(content))
                throw new LLMProviderException(LLMErrorCode.InvalidModelResponse, "Ollama /api/chat response has no message content.");

            return new LLMResponse(
                string.IsNullOrWhiteSpace(body.Model) ? request.ModelName : body.Model,
                content,
                stopwatch.ElapsedMilliseconds,
                body.PromptEvalCount,
                body.EvalCount,
                body.DoneReason);
        }, cancellationToken);
    }

    private OllamaChatRequest BuildChatRequest(LLMRequest request)
    {
        var messages = new List<OllamaChatMessage>(2);
        if (!string.IsNullOrWhiteSpace(request.SystemPrompt))
            messages.Add(new OllamaChatMessage { Role = "system", Content = request.SystemPrompt });
        messages.Add(new OllamaChatMessage { Role = "user", Content = request.Prompt });

        return new OllamaChatRequest
        {
            Model = request.ModelName,
            Messages = messages,
            Stream = false,
            Options = new OllamaGenerationOptions { Temperature = request.Temperature, NumPredict = request.MaxTokens },
            KeepAlive = string.IsNullOrWhiteSpace(options.Value.KeepAlive) ? null : options.Value.KeepAlive
        };
    }

    /// <summary>
    /// Runs one Ollama call under its own timeout and maps every failure to <see cref="LLMProviderException"/>.
    /// Cancellation of the caller's token is rethrown as-is so it is not reported as a model timeout.
    /// </summary>
    private async Task<T> ExecuteAsync<T>(
        string operation, string? modelName, int timeoutSeconds, Func<CancellationToken, Task<T>> action, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        try
        {
            return await action(timeout.Token);
        }
        catch (LLMProviderException ex)
        {
            throw Logged(ex, operation, modelName);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException ex)
        {
            throw Logged(new LLMProviderException(LLMErrorCode.ModelTimeout,
                $"Ollama did not complete {operation} within {timeoutSeconds} seconds.", ex), operation, modelName);
        }
        catch (HttpRequestException ex)
        {
            throw Logged(new LLMProviderException(LLMErrorCode.ProviderUnavailable,
                $"Ollama could not be reached for {operation} ({ex.HttpRequestError}).", ex), operation, modelName);
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException)
        {
            throw Logged(new LLMProviderException(LLMErrorCode.InvalidModelResponse,
                $"Ollama returned a body for {operation} that is not the expected JSON.", ex), operation, modelName);
        }
    }

    private LLMProviderException Logged(LLMProviderException ex, string operation, string? modelName)
    {
        logger.LogWarning("Ollama {Operation} failed for model {ModelName}: {ErrorCode}. {Diagnostic}",
            operation, modelName ?? "(none)", ex.Code, ex.Message);
        return ex;
    }

    private static void EnsureSuccess(HttpResponseMessage response, string? modelName)
    {
        if (response.IsSuccessStatusCode) return;
        // The error body is not read: Ollama error text can echo request content.
        if (response.StatusCode == HttpStatusCode.NotFound && modelName is not null)
            throw new LLMProviderException(LLMErrorCode.ModelNotFound, $"Ollama returned HTTP 404 for model '{modelName}'.");
        throw new LLMProviderException(LLMErrorCode.ProviderError, $"Ollama returned HTTP {(int)response.StatusCode}.");
    }

    private static async Task<T> ReadJsonAsync<T>(HttpResponseMessage response, CancellationToken cancellationToken) where T : class =>
        await response.Content.ReadFromJsonAsync<T>(JsonOptions, cancellationToken)
        ?? throw new LLMProviderException(LLMErrorCode.InvalidModelResponse, "Ollama returned an empty JSON body.");
}
