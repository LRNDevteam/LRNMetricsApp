using System.Globalization;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace LRN.AI.Infrastructure.AI.Ollama;

// Wire contracts for the Ollama REST API (https://github.com/ollama/ollama/blob/main/docs/api.md).
// Only the fields LRN.AI uses are declared; Ollama adds fields over time and unknown ones are ignored.

internal sealed class OllamaTagsResponse
{
    [JsonPropertyName("models")] public List<OllamaModelTag>? Models { get; init; }
}

internal sealed class OllamaModelTag
{
    [JsonPropertyName("name")] public string? Name { get; init; }
    [JsonPropertyName("size")] public long? Size { get; init; }
    [JsonPropertyName("modified_at")] public string? ModifiedAt { get; init; }
}

internal sealed class OllamaChatRequest
{
    [JsonPropertyName("model")] public required string Model { get; init; }
    [JsonPropertyName("messages")] public required List<OllamaChatMessage> Messages { get; init; }
    [JsonPropertyName("stream")] public bool Stream { get; init; }
    [JsonPropertyName("options")] public required OllamaGenerationOptions Options { get; init; }
    [JsonPropertyName("keep_alive")] public string? KeepAlive { get; init; }
}

internal sealed class OllamaGenerationOptions
{
    [JsonPropertyName("temperature")] public double Temperature { get; init; }
    [JsonPropertyName("num_predict")] public int NumPredict { get; init; }
}

internal sealed class OllamaChatMessage
{
    [JsonPropertyName("role")] public string? Role { get; init; }
    [JsonPropertyName("content")] public string? Content { get; init; }
}

internal sealed class OllamaChatResponse
{
    [JsonPropertyName("model")] public string? Model { get; init; }
    [JsonPropertyName("message")] public OllamaChatMessage? Message { get; init; }
    [JsonPropertyName("done_reason")] public string? DoneReason { get; init; }
    [JsonPropertyName("prompt_eval_count")] public int? PromptEvalCount { get; init; }
    [JsonPropertyName("eval_count")] public int? EvalCount { get; init; }
}

internal static class OllamaTimestamp
{
    // Ollama writes Go RFC 3339 timestamps with nanosecond precision (2026-11-07T10:15:30.123456789-05:00);
    // .NET parses at most seven fractional digits, so the extra ones are dropped first.
    private static readonly Regex ExtraFractionDigits = new(@"(\.\d{7})\d+", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    public static DateTimeOffset? Parse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var trimmed = ExtraFractionDigits.Replace(value, "$1", 1);
        return DateTimeOffset.TryParse(trimmed, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed : null;
    }
}
