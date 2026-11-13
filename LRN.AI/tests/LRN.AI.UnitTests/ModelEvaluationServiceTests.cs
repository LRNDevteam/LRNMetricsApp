using System.Text.Json;
using LRN.AI.Application.Common;
using LRN.AI.Application.ModelComparison;
using LRN.AI.Application.Models;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace LRN.AI.UnitTests;

public sealed class ModelEvaluationServiceTests
{
    private static readonly CallerContext Caller = new("user-1", "corr-1");
    private const string Prompt = "Explain the likely causes of a CO-11 denial. Do not assume claim-specific facts.";

    private readonly FakeLLMProvider _provider = new FakeLLMProvider().WithModels("qwen2.5:7b", "llama3.1:8b", "deepseek-r1:8b");
    private readonly RecordingAuditLogger _audit = new();

    private ModelEvaluationService CreateService(ComparisonOptions? options = null)
    {
        var wrapped = Options.Create(options ?? new ComparisonOptions { DefaultSystemPrompt = "default system" });
        return new ModelEvaluationService(_provider, new ModelComparisonValidator(wrapped), wrapped, _audit, NullLogger<ModelEvaluationService>.Instance);
    }

    [Fact]
    public async Task Compare_sends_identical_prompt_and_settings_to_every_model()
    {
        var result = await CreateService().CompareAsync(
            new ModelComparisonRequest(Prompt, ["qwen2.5:7b", "llama3.1:8b", "deepseek-r1:8b"], "system", 0.3, 900), Caller, CancellationToken.None);

        Assert.Equal(3, result.Results.Count);
        Assert.All(result.Results, r => Assert.True(r.Success));
        var requests = _provider.Requests.ToList();
        Assert.Equal(3, requests.Count);
        Assert.Single(requests.Select(r => (r.Prompt, r.SystemPrompt, r.Temperature, r.MaxTokens)).Distinct());
        Assert.Equal((Prompt, "system", 0.3, 900), (requests[0].Prompt, requests[0].SystemPrompt, requests[0].Temperature, requests[0].MaxTokens));
        Assert.Equal(["qwen2.5:7b", "llama3.1:8b", "deepseek-r1:8b"], result.Results.Select(r => r.ModelName));
    }

    [Fact]
    public async Task Compare_applies_configured_defaults()
    {
        await CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b"]), Caller, CancellationToken.None);

        var sent = Assert.Single(_provider.Requests);
        Assert.Equal("default system", sent.SystemPrompt);
        Assert.Equal(0.2, sent.Temperature);
        Assert.Equal(1200, sent.MaxTokens);
    }

    [Fact]
    public async Task Compare_keeps_successful_results_when_another_model_fails()
    {
        _provider.Behaviours["deepseek-r1:8b"] = (_, _) => throw new LLMProviderException(LLMErrorCode.ModelTimeout, "timed out");
        _provider.Behaviours["llama3.1:8b"] = (_, _) => throw new InvalidOperationException("unexpected");

        var result = await CreateService().CompareAsync(
            new ModelComparisonRequest(Prompt, ["qwen2.5:7b", "llama3.1:8b", "deepseek-r1:8b"]), Caller, CancellationToken.None);

        var qwen = result.Results.Single(r => r.ModelName == "qwen2.5:7b");
        Assert.True(qwen.Success);
        Assert.Equal("answer from qwen2.5:7b", qwen.Response);

        var deepseek = result.Results.Single(r => r.ModelName == "deepseek-r1:8b");
        Assert.False(deepseek.Success);
        Assert.Null(deepseek.Response);
        Assert.Equal("ModelTimeout", deepseek.Error!.Code);
        Assert.Equal("The model did not complete within the configured timeout.", deepseek.Error.Message);

        Assert.Equal("ProviderError", result.Results.Single(r => r.ModelName == "llama3.1:8b").Error!.Code);
        Assert.Equal(AuditOutcomes.PartiallySucceeded, _audit.Events.Single().Outcome);
    }

    [Fact]
    public async Task Compare_measures_each_model_independently()
    {
        _provider.Behaviours["llama3.1:8b"] = async (r, ct) =>
        {
            await Task.Delay(300, ct);
            return new LLMResponse(r.ModelName, "slow", 300);
        };

        var result = await CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b", "llama3.1:8b"]), Caller, CancellationToken.None);

        Assert.True(result.Results.Single(r => r.ModelName == "llama3.1:8b").DurationMs >= 250);
        Assert.True(result.Results.Single(r => r.ModelName == "qwen2.5:7b").DurationMs < 250);
    }

    [Theory]
    [InlineData(null, "prompt")]
    [InlineData("   ", "prompt")]
    public async Task Compare_rejects_a_missing_prompt(string? prompt, string field)
    {
        var ex = await Assert.ThrowsAsync<RequestValidationException>(() =>
            CreateService().CompareAsync(new ModelComparisonRequest(prompt, ["qwen2.5:7b"]), Caller, CancellationToken.None));

        Assert.Contains(field, ex.Errors.Keys);
        Assert.Empty(_provider.Requests);
    }

    [Fact]
    public async Task Compare_rejects_a_prompt_over_the_configured_length()
    {
        var service = CreateService(new ComparisonOptions { MaxPromptCharacters = 10 });

        var ex = await Assert.ThrowsAsync<RequestValidationException>(() =>
            service.CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b"]), Caller, CancellationToken.None));

        Assert.Contains("prompt", ex.Errors.Keys);
    }

    [Theory]
    [MemberData(nameof(InvalidModelLists))]
    public async Task Compare_rejects_invalid_model_lists(string[] modelNames)
    {
        var ex = await Assert.ThrowsAsync<RequestValidationException>(() =>
            CreateService().CompareAsync(new ModelComparisonRequest(Prompt, modelNames), Caller, CancellationToken.None));

        Assert.Contains("modelNames", ex.Errors.Keys);
        Assert.Empty(_provider.Requests);
    }

    public static TheoryData<string[]> InvalidModelLists => new()
    {
        Array.Empty<string>(),
        new[] { "qwen2.5:7b", "llama3.1:8b", "deepseek-r1:8b", "mistral:7b" },
        new[] { "qwen2.5:7b", "QWEN2.5:7b" },
        new[] { "qwen2.5:7b; rm -rf /" },
        new[] { "" },
    };

    [Theory]
    [InlineData(-0.1, null, "temperature")]
    [InlineData(1.5, null, "temperature")]
    [InlineData(double.NaN, null, "temperature")]
    [InlineData(null, 0, "maxTokens")]
    [InlineData(null, 5000, "maxTokens")]
    public async Task Compare_rejects_out_of_range_generation_settings(double? temperature, int? maxTokens, string field)
    {
        var ex = await Assert.ThrowsAsync<RequestValidationException>(() =>
            CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b"], null, temperature, maxTokens), Caller, CancellationToken.None));

        Assert.Contains(field, ex.Errors.Keys);
    }

    [Fact]
    public async Task Compare_rejects_models_that_are_not_installed()
    {
        var ex = await Assert.ThrowsAsync<RequestValidationException>(() =>
            CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b", "mistral:7b"]), Caller, CancellationToken.None));

        Assert.Contains("mistral:7b", Assert.Single(ex.Errors["modelNames"]));
        Assert.Empty(_provider.Requests);
    }

    [Fact]
    public async Task Compare_accepts_a_bare_name_for_its_latest_tag()
    {
        _provider.WithModels("phi3:latest");

        var result = await CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["phi3"]), Caller, CancellationToken.None);

        Assert.Equal("phi3:latest", Assert.Single(result.Results).ModelName);
    }

    [Fact]
    public async Task Compare_skips_the_installed_check_when_deliberately_disabled()
    {
        var result = await CreateService(new ComparisonOptions { RequireInstalledModels = false })
            .CompareAsync(new ModelComparisonRequest(Prompt, ["not-listed:1b"]), Caller, CancellationToken.None);

        Assert.True(Assert.Single(result.Results).Success);
    }

    [Fact]
    public async Task Compare_propagates_provider_unavailable_when_ollama_cannot_be_reached()
    {
        _provider.ListFailure = new LLMProviderException(LLMErrorCode.ProviderUnavailable, "refused");

        var ex = await Assert.ThrowsAsync<LLMProviderException>(() =>
            CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b"]), Caller, CancellationToken.None));

        Assert.Equal(LLMErrorCode.ProviderUnavailable, ex.Code);
        Assert.Equal(AuditOutcomes.Failed, _audit.Events.Single().Outcome);
    }

    [Fact]
    public async Task Compare_rejects_prompts_with_likely_patient_identifiers_without_echoing_them()
    {
        const string ssn = "123-45-6789";

        var ex = await Assert.ThrowsAsync<RequestValidationException>(() =>
            CreateService().CompareAsync(new ModelComparisonRequest($"Why was the claim for SSN {ssn} denied?", ["qwen2.5:7b"]), Caller, CancellationToken.None));

        Assert.Contains("SSN", ex.Errors["prompt"].Single());
        Assert.DoesNotContain(ex.Errors.Values.SelectMany(v => v), m => m.Contains(ssn));
        var auditEvent = _audit.Events.Single();
        Assert.Equal(AuditOutcomes.Rejected, auditEvent.Outcome);
        Assert.Equal("LikelyPhi:SSN", auditEvent.Reason);
        Assert.DoesNotContain(ssn, JsonSerializer.Serialize(auditEvent));
        Assert.Empty(_provider.Requests);
    }

    [Fact]
    public async Task Compare_audit_records_outcomes_but_never_prompt_or_response_text()
    {
        var result = await CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b"], "secret system text"), Caller, CancellationToken.None);

        var auditEvent = _audit.Events.Single();
        Assert.Equal(AuditActions.ModelsCompare, auditEvent.Action);
        Assert.Equal(AuditOutcomes.Succeeded, auditEvent.Outcome);
        Assert.Equal("user-1", auditEvent.Caller.UserId);
        Assert.Equal(result.ComparisonId.ToString(), auditEvent.ReferenceId);
        Assert.Equal(Prompt.Length, auditEvent.PromptCharacters);

        var serialized = JsonSerializer.Serialize(auditEvent);
        Assert.DoesNotContain(Prompt, serialized);
        Assert.DoesNotContain("secret system text", serialized);
        Assert.DoesNotContain("answer from", serialized);
    }

    [Fact]
    public async Task Compare_propagates_caller_cancellation_and_audits_it()
    {
        _provider.Behaviours["qwen2.5:7b"] = async (r, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            return new LLMResponse(r.ModelName, "never", 0);
        };
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CreateService().CompareAsync(new ModelComparisonRequest(Prompt, ["qwen2.5:7b"]), Caller, cancellation.Token));

        Assert.Equal(AuditOutcomes.Cancelled, _audit.Events.Single().Outcome);
    }

    [Fact]
    public async Task ListModels_returns_installed_models_and_audits()
    {
        var catalog = await CreateService().ListModelsAsync(Caller, CancellationToken.None);

        Assert.Equal("Fake", catalog.Provider);
        Assert.Equal(3, catalog.Models.Count);
        Assert.Equal(AuditActions.ModelsList, _audit.Events.Single().Action);
    }
}
