namespace LRN.AI.Application.Models;

/// <summary>
/// Provider-independent generation request. A comparison builds one of these per model with identical
/// prompt and settings, so only <see cref="ModelName"/> differs between the calls.
/// </summary>
public sealed record LLMRequest(
    string ModelName,
    string Prompt,
    string? SystemPrompt,
    double Temperature,
    int MaxTokens);

/// <summary>
/// Provider-independent generation result. Token counts and finish reason are reported when the provider
/// supplies them; they feed model evaluation (output size, truncation) and are never estimated.
/// </summary>
public sealed record LLMResponse(
    string ModelName,
    string Content,
    long DurationMs,
    int? PromptTokens = null,
    int? OutputTokens = null,
    string? FinishReason = null);

public sealed record LLMModelInfo(
    string Name,
    long? SizeBytes,
    DateTimeOffset? ModifiedAt);
