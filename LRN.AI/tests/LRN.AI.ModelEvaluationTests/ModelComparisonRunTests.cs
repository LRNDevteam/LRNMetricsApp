using System.Text.Json;
using LRN.AI.Application.Abstractions;
using LRN.AI.Application.Common;
using LRN.AI.Application.ModelComparison;
using LRN.AI.Infrastructure.AI.Ollama;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace LRN.AI.ModelEvaluationTests;

/// <summary>Runs only when LRN_AI_EVAL_MODELS lists 1-3 installed tags (comma separated).</summary>
public sealed class EvaluationFactAttribute : FactAttribute
{
    public EvaluationFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("LRN_AI_EVAL_MODELS")))
            Skip = "Live model evaluation. Set LRN_AI_EVAL_MODELS=tag1,tag2,tag3 with Ollama running to enable.";
    }
}

/// <summary>
/// Phase 1 baseline: sends a fixed set of PHI-free denial-concept prompts to the selected models with identical
/// settings and writes the responses and timings to evaluation-results/ for side-by-side review. The Phase 5
/// evaluation over 100-300 de-identified historical cases replaces this prompt set; that dataset must never be
/// committed to source control.
/// </summary>
public sealed class ModelComparisonRunTests
{
    private sealed record EvaluationPrompt(string Id, string Prompt);

    private sealed class NoopAudit : IAiAuditLogger
    {
        public void Record(AiAuditEvent auditEvent) { }
    }

    [EvaluationFact]
    public async Task Compare_selected_models_over_the_baseline_prompt_set()
    {
        var models = Environment.GetEnvironmentVariable("LRN_AI_EVAL_MODELS")!
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var ollama = new OllamaOptions
        {
            BaseUrl = Environment.GetEnvironmentVariable("LRN_AI_OLLAMA_URL") ?? "http://localhost:11434",
            TimeoutSeconds = 600
        };
        var provider = new OllamaLLMProvider(
            new HttpClient { BaseAddress = new Uri(ollama.BaseUrl.TrimEnd('/') + "/"), Timeout = TimeSpan.FromMinutes(11) },
            Options.Create(ollama),
            NullLogger<OllamaLLMProvider>.Instance);
        // Concurrency 1 so each model gets the machine to itself and timings are comparable on one GPU/CPU.
        var comparison = Options.Create(new ComparisonOptions
        {
            MaxConcurrency = 1,
            DefaultSystemPrompt = "You are an assistant evaluating medical billing denial concepts. Do not invent facts. Say when information is missing."
        });
        var service = new ModelEvaluationService(provider, new ModelComparisonValidator(comparison), comparison, new NoopAudit(),
            NullLogger<ModelEvaluationService>.Instance);

        var prompts = JsonSerializer.Deserialize<List<EvaluationPrompt>>(
            await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "EvaluationPrompts.json")),
            new JsonSerializerOptions(JsonSerializerDefaults.Web))!;

        var runs = new List<object>();
        foreach (var prompt in prompts)
        {
            var result = await service.CompareAsync(new ModelComparisonRequest(prompt.Prompt, models), new CallerContext("model-evaluation", prompt.Id), CancellationToken.None);
            runs.Add(new { promptId = prompt.Id, result });
        }

        var outputDirectory = Path.Combine(AppContext.BaseDirectory, "evaluation-results");
        Directory.CreateDirectory(outputDirectory);
        var outputFile = Path.Combine(outputDirectory, $"comparison-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}.json");
        await File.WriteAllTextAsync(outputFile, JsonSerializer.Serialize(new
        {
            runAt = DateTimeOffset.UtcNow,
            ollama = new { ollama.BaseUrl, ollama.KeepAlive },
            settings = new { comparison.Value.DefaultTemperature, comparison.Value.DefaultMaxTokens, comparison.Value.DefaultSystemPrompt },
            models,
            runs
        }, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));

        Assert.True(File.Exists(outputFile));
    }
}
