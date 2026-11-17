using LRN.AI.Application.ModelComparison;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace LRN.AI.Application;

public static class DependencyInjection
{
    /// <summary>Registers use cases. The host binds <see cref="ComparisonOptions"/> from configuration.</summary>
    public static IServiceCollection AddLrnAiApplication(this IServiceCollection services)
    {
        services.AddSingleton<IValidateOptions<ComparisonOptions>, ComparisonOptionsValidator>();
        services.AddSingleton<ModelComparisonValidator>();
        services.AddScoped<IModelEvaluationService, ModelEvaluationService>();
        return services;
    }
}
