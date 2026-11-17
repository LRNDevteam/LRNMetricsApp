using Microsoft.Extensions.Options;

namespace LRN.AI.Application.ModelComparison;

public sealed class ComparisonOptions
{
    public const string SectionName = "AI:Comparison";

    /// <summary>The compare endpoint never runs more than three models, whatever the configuration says.</summary>
    public const int HardMaxModels = 3;

    public int MaxModelsPerRequest { get; set; } = HardMaxModels;
    public int MaxConcurrency { get; set; } = HardMaxModels;
    public int MaxPromptCharacters { get; set; } = 12000;
    public int MaxSystemPromptCharacters { get; set; } = 4000;

    /// <summary>Used when a request supplies no system prompt.</summary>
    public string? DefaultSystemPrompt { get; set; }

    public double DefaultTemperature { get; set; } = 0.2;
    public double MaxTemperature { get; set; } = 1.0;
    public int DefaultMaxTokens { get; set; } = 1200;
    public int MaxOutputTokens { get; set; } = 4096;

    /// <summary>
    /// When true (the default) every requested model must appear in the provider's installed-model list.
    /// Turning it off is a deliberate choice that lets the provider report unknown models per result instead.
    /// </summary>
    public bool RequireInstalledModels { get; set; } = true;

    /// <summary>
    /// When true (the default) prompts that look like they carry patient identifiers are rejected. Phase 1
    /// accepts de-identified text only; this is a heuristic backstop, not a de-identification guarantee.
    /// </summary>
    public bool RejectLikelyPhi { get; set; } = true;
}

internal sealed class ComparisonOptionsValidator : IValidateOptions<ComparisonOptions>
{
    public ValidateOptionsResult Validate(string? name, ComparisonOptions options)
    {
        var failures = new List<string>();

        if (options.MaxModelsPerRequest is < 1 or > ComparisonOptions.HardMaxModels)
            failures.Add($"{ComparisonOptions.SectionName}:MaxModelsPerRequest must be between 1 and {ComparisonOptions.HardMaxModels}.");
        if (options.MaxConcurrency is < 1 or > ComparisonOptions.HardMaxModels)
            failures.Add($"{ComparisonOptions.SectionName}:MaxConcurrency must be between 1 and {ComparisonOptions.HardMaxModels}.");
        if (options.MaxPromptCharacters is < 1 or > 100_000)
            failures.Add($"{ComparisonOptions.SectionName}:MaxPromptCharacters must be between 1 and 100000.");
        if (options.MaxSystemPromptCharacters is < 0 or > 20_000)
            failures.Add($"{ComparisonOptions.SectionName}:MaxSystemPromptCharacters must be between 0 and 20000.");
        if (options.DefaultSystemPrompt?.Length > options.MaxSystemPromptCharacters)
            failures.Add($"{ComparisonOptions.SectionName}:DefaultSystemPrompt is longer than MaxSystemPromptCharacters.");
        if (double.IsNaN(options.MaxTemperature) || options.MaxTemperature is < 0 or > 2)
            failures.Add($"{ComparisonOptions.SectionName}:MaxTemperature must be between 0 and 2.");
        if (double.IsNaN(options.DefaultTemperature) || options.DefaultTemperature < 0 || options.DefaultTemperature > options.MaxTemperature)
            failures.Add($"{ComparisonOptions.SectionName}:DefaultTemperature must be between 0 and MaxTemperature.");
        if (options.MaxOutputTokens is < 1 or > 32_768)
            failures.Add($"{ComparisonOptions.SectionName}:MaxOutputTokens must be between 1 and 32768.");
        if (options.DefaultMaxTokens < 1 || options.DefaultMaxTokens > options.MaxOutputTokens)
            failures.Add($"{ComparisonOptions.SectionName}:DefaultMaxTokens must be between 1 and MaxOutputTokens.");

        return failures.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(failures);
    }
}
