using System.Text.RegularExpressions;
using LRN.AI.Application.Common;
using Microsoft.Extensions.Options;

namespace LRN.AI.Application.ModelComparison;

internal sealed record ComparisonValidation(
    IReadOnlyDictionary<string, string[]> Errors,
    IReadOnlyList<string> PhiCategories);

internal sealed class ModelComparisonValidator(IOptions<ComparisonOptions> options)
{
    // Model names are identifiers matched against the provider's tag list, never commands or paths.
    private static readonly Regex ModelNamePattern = new(
        @"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    public ComparisonValidation Validate(ModelComparisonRequest request)
    {
        var o = options.Value;
        var errors = new Dictionary<string, List<string>>();
        void Add(string field, string message)
        {
            if (!errors.TryGetValue(field, out var list)) errors[field] = list = [];
            list.Add(message);
        }

        if (string.IsNullOrWhiteSpace(request.Prompt))
            Add("prompt", "A prompt is required.");
        else if (request.Prompt.Length > o.MaxPromptCharacters)
            Add("prompt", $"The prompt must be {o.MaxPromptCharacters} characters or fewer.");

        if (request.SystemPrompt?.Length > o.MaxSystemPromptCharacters)
            Add("systemPrompt", $"The system prompt must be {o.MaxSystemPromptCharacters} characters or fewer.");

        var names = (request.ModelNames ?? Array.Empty<string>()).Select(n => n?.Trim() ?? string.Empty).ToList();
        if (names.Count < 1 || names.Count > o.MaxModelsPerRequest)
            Add("modelNames", $"Select between 1 and {o.MaxModelsPerRequest} models.");
        if (names.Any(n => !ModelNamePattern.IsMatch(n)))
            Add("modelNames", "Model names must be installed model tags (letters, digits and . _ : / - only).");
        if (names.Distinct(StringComparer.OrdinalIgnoreCase).Count() != names.Count)
            Add("modelNames", "Each model may be selected only once.");

        if (request.Temperature is { } temperature && (double.IsNaN(temperature) || temperature < 0 || temperature > o.MaxTemperature))
            Add("temperature", $"Temperature must be between 0 and {o.MaxTemperature}.");

        if (request.MaxTokens is { } maxTokens && (maxTokens < 1 || maxTokens > o.MaxOutputTokens))
            Add("maxTokens", $"Max tokens must be between 1 and {o.MaxOutputTokens}.");

        IReadOnlyList<string> phi = [];
        if (o.RejectLikelyPhi)
        {
            phi = LikelyPhiDetector.Detect(request.Prompt)
                .Concat(LikelyPhiDetector.Detect(request.SystemPrompt))
                .Distinct()
                .ToList();
            if (phi.Count > 0)
                Add("prompt", $"The prompt appears to contain patient identifiers ({string.Join(", ", phi)}). Model comparison accepts de-identified text only.");
        }

        return new ComparisonValidation(errors.ToDictionary(e => e.Key, e => e.Value.ToArray()), phi);
    }
}
