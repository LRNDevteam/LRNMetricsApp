using System.Collections.Concurrent;
using System.Net;
using System.Text;
using LRN.AI.Application.Abstractions;
using LRN.AI.Application.Common;
using LRN.AI.Application.Models;

namespace LRN.AI.UnitTests;

internal sealed class StubHttpMessageHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    public List<(HttpMethod Method, string Path, string? Body)> Requests { get; } = [];

    public static StubHttpMessageHandler Json(HttpStatusCode status, string json) =>
        new((_, _) => Task.FromResult(new HttpResponseMessage(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        }));

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        Requests.Add((request.Method, request.RequestUri!.AbsolutePath, body));
        return await respond(request, cancellationToken);
    }
}

internal sealed class FakeLLMProvider : ILLMProvider
{
    public string ProviderName => "Fake";
    public List<LLMModelInfo> Installed { get; } = [];
    public Exception? ListFailure { get; set; }
    public Dictionary<string, Func<LLMRequest, CancellationToken, Task<LLMResponse>>> Behaviours { get; } = [];
    public ConcurrentQueue<LLMRequest> Requests { get; } = new();

    public FakeLLMProvider WithModels(params string[] names)
    {
        Installed.AddRange(names.Select(n => new LLMModelInfo(n, 1, null)));
        return this;
    }

    public Task<IReadOnlyList<LLMModelInfo>> GetAvailableModelsAsync(CancellationToken cancellationToken) =>
        ListFailure is null ? Task.FromResult<IReadOnlyList<LLMModelInfo>>(Installed) : Task.FromException<IReadOnlyList<LLMModelInfo>>(ListFailure);

    public Task<LLMResponse> GenerateAsync(LLMRequest request, CancellationToken cancellationToken)
    {
        Requests.Enqueue(request);
        return Behaviours.TryGetValue(request.ModelName, out var behaviour)
            ? behaviour(request, cancellationToken)
            : Task.FromResult(new LLMResponse(request.ModelName, $"answer from {request.ModelName}", 5));
    }
}

internal sealed class RecordingAuditLogger : IAiAuditLogger
{
    public ConcurrentQueue<AiAuditEvent> Events { get; } = new();
    public void Record(AiAuditEvent auditEvent) => Events.Enqueue(auditEvent);
}
