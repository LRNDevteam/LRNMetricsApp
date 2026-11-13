using LRN.AI.Application.ModelComparison;

namespace LRN.AI.Api.Contracts.Models;

/// <summary>
/// POST /api/ai/v1/models/compare body. Fields are nullable so missing values reach the application validator and
/// come back as one consistent ValidationProblemDetails rather than model-binding errors.
/// </summary>
public sealed class CompareModelsRequest
{
    public string? Prompt { get; init; }
    public List<string>? ModelNames { get; init; }
    public string? SystemPrompt { get; init; }
    public double? Temperature { get; init; }
    public int? MaxTokens { get; init; }

    internal ModelComparisonRequest ToApplication() => new(Prompt, ModelNames, SystemPrompt, Temperature, MaxTokens);
}

public sealed record ModelsResponse(string Provider, bool Connected, IReadOnlyList<ModelInfoDto> Models)
{
    internal static ModelsResponse From(ModelCatalog catalog) => new(
        catalog.Provider,
        true,
        catalog.Models.Select(m => new ModelInfoDto(m.Name, m.SizeBytes, m.ModifiedAt)).ToList());
}

public sealed record ModelInfoDto(string Name, long? SizeBytes, DateTimeOffset? ModifiedAt);

public sealed record CompareModelsResponse(
    Guid ComparisonId,
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt,
    IReadOnlyList<ModelResultDto> Results)
{
    internal static CompareModelsResponse From(ModelComparisonResult result) => new(
        result.ComparisonId,
        result.StartedAt,
        result.CompletedAt,
        result.Results.Select(r => new ModelResultDto(
            r.ModelName,
            r.Success,
            r.Response,
            r.DurationMs,
            r.PromptTokens,
            r.OutputTokens,
            r.FinishReason,
            r.Error is null ? null : new ModelErrorDto(r.Error.Code, r.Error.Message))).ToList());
}

public sealed record ModelResultDto(
    string ModelName,
    bool Success,
    string? Response,
    long DurationMs,
    int? PromptTokens,
    int? OutputTokens,
    string? FinishReason,
    ModelErrorDto? Error);

public sealed record ModelErrorDto(string Code, string Message);
