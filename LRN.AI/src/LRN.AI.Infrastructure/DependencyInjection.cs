using LRN.AI.Application.Abstractions;
using LRN.AI.Infrastructure.AI.Ollama;
using LRN.AI.Infrastructure.Observability;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace LRN.AI.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddLrnAiInfrastructure(this IServiceCollection services, IConfiguration configuration)
    {
        var defaultProvider = configuration["AI:DefaultProvider"] ?? "Ollama";
        if (!string.Equals(defaultProvider, "Ollama", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"AI:DefaultProvider '{defaultProvider}' is not supported; Phase 1 supports Ollama only.");

        services.AddOptions<OllamaOptions>()
            .Bind(configuration.GetSection(OllamaOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<OllamaOptions>, OllamaOptionsValidator>();

        services.AddHttpClient<ILLMProvider, OllamaLLMProvider>((sp, client) =>
        {
            var ollama = sp.GetRequiredService<IOptions<OllamaOptions>>().Value;
            client.BaseAddress = new Uri(ollama.BaseUrl.TrimEnd('/') + "/");
            // The provider enforces each call's timeout itself (so a timeout is distinguishable from a cancelled
            // request); this client-level timeout is only a backstop.
            client.Timeout = TimeSpan.FromSeconds(Math.Max(ollama.TimeoutSeconds, ollama.ListTimeoutSeconds) + 30);
        });

        services.AddSingleton<IAiAuditLogger, LoggerAuditLogger>();
        return services;
    }
}
