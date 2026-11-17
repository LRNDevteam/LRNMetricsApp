using LRN.AI.Application.Models;
using LRN.AI.Infrastructure.AI.Ollama;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace LRN.AI.IntegrationTests;

/// <summary>Runs only when LRN_AI_OLLAMA_TESTS=1; otherwise reported as skipped, never as passed.</summary>
public sealed class OllamaFactAttribute : FactAttribute
{
    public OllamaFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("LRN_AI_OLLAMA_TESTS") != "1")
            Skip = "Live Ollama test. Set LRN_AI_OLLAMA_TESTS=1 with Ollama running to enable.";
    }
}

public sealed class OllamaLiveTests
{
    private static OllamaLLMProvider CreateProvider()
    {
        var options = new OllamaOptions
        {
            BaseUrl = Environment.GetEnvironmentVariable("LRN_AI_OLLAMA_URL") ?? "http://localhost:11434",
            TimeoutSeconds = 300
        };
        return new OllamaLLMProvider(
            new HttpClient { BaseAddress = new Uri(options.BaseUrl.TrimEnd('/') + "/"), Timeout = TimeSpan.FromMinutes(6) },
            Options.Create(options),
            NullLogger<OllamaLLMProvider>.Instance);
    }

    [OllamaFact]
    public async Task Lists_the_installed_models()
    {
        var models = await CreateProvider().GetAvailableModelsAsync(CancellationToken.None);

        Assert.NotEmpty(models);
        Assert.All(models, m => Assert.False(string.IsNullOrWhiteSpace(m.Name)));
    }

    [OllamaFact]
    public async Task Generates_with_the_first_installed_model_or_LRN_AI_TEST_MODEL()
    {
        var provider = CreateProvider();
        var model = Environment.GetEnvironmentVariable("LRN_AI_TEST_MODEL")
            ?? (await provider.GetAvailableModelsAsync(CancellationToken.None)).First().Name;

        var response = await provider.GenerateAsync(
            new LLMRequest(model, "In one sentence, what does CARC CO-11 mean?", "Answer briefly. Do not invent facts.", 0.2, 200),
            CancellationToken.None);

        Assert.False(string.IsNullOrWhiteSpace(response.Content));
        Assert.True(response.DurationMs > 0);
    }
}
