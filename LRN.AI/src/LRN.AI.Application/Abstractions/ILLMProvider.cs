using LRN.AI.Application.Common;
using LRN.AI.Application.Models;

namespace LRN.AI.Application.Abstractions;

/// <summary>
/// A model runtime (Phase 1: local Ollama). Implementations throw <see cref="LLMProviderException"/> for every
/// provider failure and let <see cref="OperationCanceledException"/> through only when the caller's token was
/// cancelled, so a provider timeout is never mistaken for a cancelled request.
/// </summary>
public interface ILLMProvider
{
    string ProviderName { get; }

    Task<LLMResponse> GenerateAsync(
        LLMRequest request,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<LLMModelInfo>> GetAvailableModelsAsync(
        CancellationToken cancellationToken);
}
