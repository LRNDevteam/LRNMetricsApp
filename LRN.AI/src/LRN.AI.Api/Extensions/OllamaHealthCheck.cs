using LRN.AI.Application.Abstractions;
using LRN.AI.Application.Common;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace LRN.AI.Api.Extensions;

/// <summary>Model-provider health, reported at /health/ollama separately from API liveness at /health.</summary>
internal sealed class OllamaHealthCheck(ILLMProvider provider) : IHealthCheck
{
    public const string Tag = "provider";

    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            await provider.GetAvailableModelsAsync(cancellationToken);
            return HealthCheckResult.Healthy();
        }
        catch (LLMProviderException ex)
        {
            return HealthCheckResult.Unhealthy(ex.Code.ToString());
        }
    }
}
