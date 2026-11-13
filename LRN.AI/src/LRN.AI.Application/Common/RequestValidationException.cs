namespace LRN.AI.Application.Common;

/// <summary>Invalid caller input, keyed by the camelCase request field it applies to.</summary>
public sealed class RequestValidationException(IReadOnlyDictionary<string, string[]> errors)
    : Exception("The request failed validation.")
{
    public IReadOnlyDictionary<string, string[]> Errors { get; } = errors;
}
