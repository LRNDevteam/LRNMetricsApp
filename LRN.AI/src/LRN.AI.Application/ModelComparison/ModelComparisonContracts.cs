using LRN.AI.Application.Common;
using LRN.AI.Application.Models;

namespace LRN.AI.Application.ModelComparison;

/// <summary>Null temperature / max tokens / system prompt take the configured defaults.</summary>
public sealed record ModelComparisonRequest(
    string? Prompt,
    IReadOnlyList<string>? ModelNames,
    string? SystemPrompt = null,
    double? Temperature = null,
    int? MaxTokens = null);

public sealed record ModelComparisonResult(
    Guid ComparisonId,
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt,
    IReadOnlyList<ModelRunResult> Results);

public sealed record ModelRunResult(
    string ModelName,
    bool Success,
    string? Response,
    long DurationMs,
    int? PromptTokens,
    int? OutputTokens,
    string? FinishReason,
    ModelRunError? Error)
{
    internal static ModelRunResult Succeeded(string modelName, LLMResponse response, long durationMs) =>
        new(modelName, true, response.Content, durationMs, response.PromptTokens, response.OutputTokens, response.FinishReason, null);

    internal static ModelRunResult Failed(string modelName, LLMErrorCode code, long durationMs) =>
        new(modelName, false, null, durationMs, null, null, null, new ModelRunError(code.ToString(), code.ToCallerMessage()));
}

public sealed record ModelRunError(string Code, string Message);

public sealed record ModelCatalog(string Provider, IReadOnlyList<LLMModelInfo> Models);
