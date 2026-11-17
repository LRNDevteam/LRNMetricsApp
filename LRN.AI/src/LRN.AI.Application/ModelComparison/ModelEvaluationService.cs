using System.Diagnostics;
using LRN.AI.Application.Abstractions;
using LRN.AI.Application.Common;
using LRN.AI.Application.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.AI.Application.ModelComparison;

public interface IModelEvaluationService
{
    /// <summary>Installed models. Throws <see cref="LLMProviderException"/> when the provider cannot be reached.</summary>
    Task<ModelCatalog> ListModelsAsync(CallerContext caller, CancellationToken cancellationToken);

    /// <summary>
    /// Sends one prompt with identical settings to each requested model. Throws <see cref="RequestValidationException"/>
    /// for invalid input and <see cref="LLMProviderException"/> when the provider cannot be reached at all; a single
    /// model's failure is reported in its own result and never discards the others.
    /// </summary>
    Task<ModelComparisonResult> CompareAsync(ModelComparisonRequest request, CallerContext caller, CancellationToken cancellationToken);
}

internal sealed class ModelEvaluationService(
    ILLMProvider provider,
    ModelComparisonValidator validator,
    IOptions<ComparisonOptions> options,
    IAiAuditLogger audit,
    ILogger<ModelEvaluationService> logger) : IModelEvaluationService
{
    public async Task<ModelCatalog> ListModelsAsync(CallerContext caller, CancellationToken cancellationToken)
    {
        try
        {
            var models = await provider.GetAvailableModelsAsync(cancellationToken);
            audit.Record(new AiAuditEvent(AuditActions.ModelsList, AuditOutcomes.Succeeded, caller, DateTimeOffset.UtcNow));
            return new ModelCatalog(provider.ProviderName, models);
        }
        catch (LLMProviderException ex)
        {
            audit.Record(new AiAuditEvent(AuditActions.ModelsList, AuditOutcomes.Failed, caller, DateTimeOffset.UtcNow, Reason: ex.Code.ToString()));
            throw;
        }
    }

    public async Task<ModelComparisonResult> CompareAsync(ModelComparisonRequest request, CallerContext caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var o = options.Value;
        var requestedNames = (request.ModelNames ?? Array.Empty<string>()).Select(n => n?.Trim() ?? string.Empty).ToList();
        var promptCharacters = request.Prompt?.Length;

        void Audit(string outcome, string? reason = null, Guid? comparisonId = null, IReadOnlyList<AiAuditModelOutcome>? outcomes = null) =>
            audit.Record(new AiAuditEvent(AuditActions.ModelsCompare, outcome, caller, DateTimeOffset.UtcNow,
                comparisonId?.ToString(), requestedNames, promptCharacters, reason, outcomes));

        var validation = validator.Validate(request);
        if (validation.Errors.Count > 0)
        {
            Audit(AuditOutcomes.Rejected, validation.PhiCategories.Count > 0
                ? "LikelyPhi:" + string.Join(',', validation.PhiCategories)
                : "ValidationFailed:" + string.Join(',', validation.Errors.Keys));
            throw new RequestValidationException(validation.Errors);
        }

        IReadOnlyList<string> modelNames = requestedNames;
        if (o.RequireInstalledModels)
        {
            IReadOnlyList<LLMModelInfo> installed;
            try
            {
                installed = await provider.GetAvailableModelsAsync(cancellationToken);
            }
            catch (LLMProviderException ex)
            {
                Audit(AuditOutcomes.Failed, ex.Code.ToString());
                throw;
            }

            var resolved = requestedNames.Select(name => (Requested: name, Installed: ResolveInstalledName(name, installed))).ToList();
            var missing = resolved.Where(r => r.Installed is null).Select(r => r.Requested).ToList();
            if (missing.Count > 0)
            {
                Audit(AuditOutcomes.Rejected, "ModelNotInstalled");
                throw new RequestValidationException(new Dictionary<string, string[]>
                {
                    ["modelNames"] = missing
                        .Select(m => $"Model '{m}' is not installed in {provider.ProviderName}. Use GET /api/ai/v1/models for the installed tags.")
                        .ToArray()
                });
            }
            modelNames = resolved.Select(r => r.Installed!).ToList();
        }

        var prompt = request.Prompt!;
        var systemPrompt = string.IsNullOrWhiteSpace(request.SystemPrompt) ? o.DefaultSystemPrompt : request.SystemPrompt;
        var temperature = request.Temperature ?? o.DefaultTemperature;
        var maxTokens = request.MaxTokens ?? o.DefaultMaxTokens;

        var comparisonId = Guid.NewGuid();
        var startedAt = DateTimeOffset.UtcNow;
        ModelRunResult[] results;
        try
        {
            using var gate = new SemaphoreSlim(Math.Clamp(o.MaxConcurrency, 1, ComparisonOptions.HardMaxModels));
            results = await Task.WhenAll(modelNames.Select(name =>
                RunModelAsync(new LLMRequest(name, prompt, systemPrompt, temperature, maxTokens), gate, comparisonId, cancellationToken)));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Audit(AuditOutcomes.Cancelled, comparisonId: comparisonId);
            throw;
        }
        var completedAt = DateTimeOffset.UtcNow;

        var succeeded = results.Count(r => r.Success);
        Audit(
            succeeded == results.Length ? AuditOutcomes.Succeeded : succeeded > 0 ? AuditOutcomes.PartiallySucceeded : AuditOutcomes.Failed,
            comparisonId: comparisonId,
            outcomes: results.Select(r => new AiAuditModelOutcome(r.ModelName, r.Success, r.DurationMs, r.Error?.Code)).ToList());

        return new ModelComparisonResult(comparisonId, startedAt, completedAt, results);
    }

    private async Task<ModelRunResult> RunModelAsync(LLMRequest request, SemaphoreSlim gate, Guid comparisonId, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken);
        // Started after the gate so a model's time never includes waiting for another model's slot.
        var stopwatch = Stopwatch.StartNew();
        try
        {
            var response = await provider.GenerateAsync(request, cancellationToken);
            return ModelRunResult.Succeeded(request.ModelName, response, stopwatch.ElapsedMilliseconds);
        }
        catch (LLMProviderException ex)
        {
            logger.LogWarning("Comparison {ComparisonId}: model {ModelName} failed with {ErrorCode} after {DurationMs} ms.",
                comparisonId, request.ModelName, ex.Code, stopwatch.ElapsedMilliseconds);
            return ModelRunResult.Failed(request.ModelName, ex.Code, stopwatch.ElapsedMilliseconds);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "Comparison {ComparisonId}: model {ModelName} failed unexpectedly.", comparisonId, request.ModelName);
            return ModelRunResult.Failed(request.ModelName, LLMErrorCode.ProviderError, stopwatch.ElapsedMilliseconds);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Exact tag match, or a bare name matching its ":latest" tag (Ollama's own default).</summary>
    private static string? ResolveInstalledName(string requested, IReadOnlyList<LLMModelInfo> installed)
    {
        var exact = installed.FirstOrDefault(m => string.Equals(m.Name, requested, StringComparison.Ordinal));
        if (exact is not null) return exact.Name;
        if (requested.Contains(':')) return null;
        return installed.FirstOrDefault(m => string.Equals(m.Name, requested + ":latest", StringComparison.Ordinal))?.Name;
    }
}
