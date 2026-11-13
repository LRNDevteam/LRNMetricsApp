using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;

namespace LRN.AI.Infrastructure.AI.Ollama;

public sealed class OllamaOptions
{
    public const string SectionName = "AI:Ollama";

    public string BaseUrl { get; set; } = "http://localhost:11434";

    /// <summary>Per-model generation timeout.</summary>
    public int TimeoutSeconds { get; set; } = 180;

    /// <summary>Timeout for the installed-model list, which should answer almost immediately.</summary>
    public int ListTimeoutSeconds { get; set; } = 10;

    /// <summary>Ollama keep_alive (Go duration, e.g. "5m", "0" to unload at once). Null leaves Ollama's default.</summary>
    public string? KeepAlive { get; set; } = "5m";
}

internal sealed class OllamaOptionsValidator : IValidateOptions<OllamaOptions>
{
    private static readonly Regex GoDuration = new(
        @"^-?(?:\d+|(?:\d+(?:\.\d+)?(?:ns|us|µs|ms|s|m|h))+)$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    public ValidateOptionsResult Validate(string? name, OllamaOptions options)
    {
        var failures = new List<string>();

        if (!Uri.TryCreate(options.BaseUrl, UriKind.Absolute, out var uri) || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            failures.Add($"{OllamaOptions.SectionName}:BaseUrl must be an absolute http or https URL.");
        else if (!uri.IsLoopback && uri.Scheme != Uri.UriSchemeHttps)
            // HIPAA transmission security (164.312(e)): prompts may carry PHI once live data is connected, so any
            // model host that is not this machine must be reached over TLS (e.g. Ollama behind a TLS reverse proxy).
            failures.Add($"{OllamaOptions.SectionName}:BaseUrl must use https when Ollama is not on this machine.");

        if (options.TimeoutSeconds is < 5 or > 1800)
            failures.Add($"{OllamaOptions.SectionName}:TimeoutSeconds must be between 5 and 1800.");
        if (options.ListTimeoutSeconds is < 1 or > 120)
            failures.Add($"{OllamaOptions.SectionName}:ListTimeoutSeconds must be between 1 and 120.");
        if (!string.IsNullOrEmpty(options.KeepAlive) && !GoDuration.IsMatch(options.KeepAlive))
            failures.Add($"{OllamaOptions.SectionName}:KeepAlive must be a duration such as 5m, 30s, 0 or -1.");

        return failures.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(failures);
    }
}
