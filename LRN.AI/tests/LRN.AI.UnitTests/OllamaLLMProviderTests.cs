using System.Net;
using System.Text.Json;
using LRN.AI.Application.Common;
using LRN.AI.Application.Models;
using LRN.AI.Infrastructure.AI.Ollama;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace LRN.AI.UnitTests;

public sealed class OllamaLLMProviderTests
{
    private static OllamaLLMProvider CreateProvider(HttpMessageHandler handler, int timeoutSeconds = 30, string? keepAlive = "5m") =>
        new(new HttpClient(handler) { BaseAddress = new Uri("http://localhost:11434/") },
            Options.Create(new OllamaOptions { TimeoutSeconds = timeoutSeconds, ListTimeoutSeconds = timeoutSeconds, KeepAlive = keepAlive }),
            NullLogger<OllamaLLMProvider>.Instance);

    private static readonly LLMRequest Request = new("qwen2.5:7b", "Explain CO-11.", "Do not invent facts.", 0.2, 800);

    [Fact]
    public async Task GetAvailableModels_maps_installed_tags()
    {
        var handler = StubHttpMessageHandler.Json(HttpStatusCode.OK, """
            {"models":[
              {"name":"qwen2.5:7b","model":"qwen2.5:7b","size":4683087332,"modified_at":"2026-11-01T10:15:30.123456789-05:00"},
              {"name":"llama3.1:8b","size":4920753328,"modified_at":"2026-10-20T08:00:00Z"},
              {"name":""}
            ]}
            """);

        var models = await CreateProvider(handler).GetAvailableModelsAsync(CancellationToken.None);

        Assert.Equal(["qwen2.5:7b", "llama3.1:8b"], models.Select(m => m.Name));
        Assert.Equal(4683087332, models[0].SizeBytes);
        // Nanosecond precision is truncated to .NET's 100 ns ticks; DateTimeOffset equality compares the UTC instant.
        Assert.Equal(new DateTimeOffset(2026, 11, 1, 15, 15, 30, TimeSpan.Zero).AddTicks(1234567), models[0].ModifiedAt);
        Assert.Equal("/api/tags", handler.Requests.Single().Path);
    }

    [Fact]
    public async Task GetAvailableModels_reports_unavailable_when_connection_is_refused()
    {
        var handler = new StubHttpMessageHandler((_, _) => throw new HttpRequestException("No connection could be made", null, HttpStatusCode.ServiceUnavailable));

        var ex = await Assert.ThrowsAsync<LLMProviderException>(() => CreateProvider(handler).GetAvailableModelsAsync(CancellationToken.None));

        Assert.Equal(LLMErrorCode.ProviderUnavailable, ex.Code);
    }

    [Fact]
    public async Task Generate_sends_non_streaming_chat_with_identical_settings_and_maps_the_reply()
    {
        var handler = StubHttpMessageHandler.Json(HttpStatusCode.OK, """
            {"model":"qwen2.5:7b","message":{"role":"assistant","content":"CO-11 means..."},"done":true,
             "done_reason":"stop","prompt_eval_count":42,"eval_count":120}
            """);

        var response = await CreateProvider(handler).GenerateAsync(Request, CancellationToken.None);

        Assert.Equal("CO-11 means...", response.Content);
        Assert.Equal("qwen2.5:7b", response.ModelName);
        Assert.Equal(42, response.PromptTokens);
        Assert.Equal(120, response.OutputTokens);
        Assert.Equal("stop", response.FinishReason);

        var sent = handler.Requests.Single();
        Assert.Equal("/api/chat", sent.Path);
        using var body = JsonDocument.Parse(sent.Body!);
        var root = body.RootElement;
        Assert.Equal("qwen2.5:7b", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("stream").GetBoolean());
        Assert.Equal(0.2, root.GetProperty("options").GetProperty("temperature").GetDouble());
        Assert.Equal(800, root.GetProperty("options").GetProperty("num_predict").GetInt32());
        Assert.Equal("5m", root.GetProperty("keep_alive").GetString());
        var messages = root.GetProperty("messages").EnumerateArray().ToList();
        Assert.Equal(["system", "user"], messages.Select(m => m.GetProperty("role").GetString()));
        Assert.Equal("Explain CO-11.", messages[1].GetProperty("content").GetString());
    }

    [Fact]
    public async Task Generate_omits_system_message_and_keep_alive_when_not_set()
    {
        var handler = StubHttpMessageHandler.Json(HttpStatusCode.OK, """{"message":{"role":"assistant","content":"ok"}}""");

        await CreateProvider(handler, keepAlive: null).GenerateAsync(Request with { SystemPrompt = null }, CancellationToken.None);

        using var body = JsonDocument.Parse(handler.Requests.Single().Body!);
        Assert.False(body.RootElement.TryGetProperty("keep_alive", out _));
        Assert.Equal("user", body.RootElement.GetProperty("messages").EnumerateArray().Single().GetProperty("role").GetString());
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound, """{"error":"model 'qwen2.5:7b' not found"}""", LLMErrorCode.ModelNotFound)]
    [InlineData(HttpStatusCode.InternalServerError, """{"error":"out of memory"}""", LLMErrorCode.ProviderError)]
    [InlineData(HttpStatusCode.OK, "this is not json", LLMErrorCode.InvalidModelResponse)]
    [InlineData(HttpStatusCode.OK, """{"model":"qwen2.5:7b","done":true}""", LLMErrorCode.InvalidModelResponse)]
    [InlineData(HttpStatusCode.OK, """{"message":{"role":"assistant","content":"  "}}""", LLMErrorCode.InvalidModelResponse)]
    [InlineData(HttpStatusCode.OK, "null", LLMErrorCode.InvalidModelResponse)]
    public async Task Generate_maps_provider_failures(HttpStatusCode status, string body, LLMErrorCode expected)
    {
        var handler = StubHttpMessageHandler.Json(status, body);

        var ex = await Assert.ThrowsAsync<LLMProviderException>(() => CreateProvider(handler).GenerateAsync(Request, CancellationToken.None));

        Assert.Equal(expected, ex.Code);
        Assert.DoesNotContain("out of memory", ex.Message);
    }

    [Fact]
    public async Task Generate_reports_timeout_when_the_model_exceeds_the_configured_limit()
    {
        var handler = new StubHttpMessageHandler(async (_, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            throw new InvalidOperationException("unreachable");
        });

        var ex = await Assert.ThrowsAsync<LLMProviderException>(() => CreateProvider(handler, timeoutSeconds: 1).GenerateAsync(Request, CancellationToken.None));

        Assert.Equal(LLMErrorCode.ModelTimeout, ex.Code);
    }

    [Fact]
    public async Task Generate_rethrows_caller_cancellation_instead_of_reporting_a_timeout()
    {
        var handler = new StubHttpMessageHandler(async (_, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            throw new InvalidOperationException("unreachable");
        });
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => CreateProvider(handler).GenerateAsync(Request, cancellation.Token));
    }
}
