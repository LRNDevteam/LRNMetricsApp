namespace LRN.AI.Application.Common;

public enum LLMErrorCode
{
    ProviderUnavailable,
    ModelTimeout,
    ModelNotFound,
    InvalidModelResponse,
    ProviderError
}

/// <summary>
/// A model-provider failure. <see cref="Exception.Message"/> is an internal diagnostic written by the provider
/// and never contains prompt or response text; callers are shown <see cref="LLMErrorCodeExtensions.ToCallerMessage"/>.
/// </summary>
public sealed class LLMProviderException(LLMErrorCode code, string message, Exception? innerException = null)
    : Exception(message, innerException)
{
    public LLMErrorCode Code { get; } = code;
}

public static class LLMErrorCodeExtensions
{
    public static string ToCallerMessage(this LLMErrorCode code) => code switch
    {
        LLMErrorCode.ProviderUnavailable => "The model provider could not be reached.",
        LLMErrorCode.ModelTimeout => "The model did not complete within the configured timeout.",
        LLMErrorCode.ModelNotFound => "The model is not installed in the model provider.",
        LLMErrorCode.InvalidModelResponse => "The model provider returned a response that could not be read.",
        _ => "The model provider returned an error."
    };
}
