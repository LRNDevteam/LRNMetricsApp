namespace LRN.AzBlobSync.Models;

public sealed class FoundryOptions
{
    public const string Section = "Foundry";

    public bool Enabled { get; set; }

    public string AzureOpenAiEndpoint { get; set; } = string.Empty;

    public string DeploymentName { get; set; } = "gpt-5-mini-labmetrics";

    public string ApiVersion { get; set; } = "2024-12-01-preview";

    public string ApiKeySecretName { get; set; } = "lrn-foundry-api-key";

    public string OutputBlobPrefix { get; set; } = "Beech_Tree_Outputs";

    public string TrailingWindow { get; set; } = "m12";

    public int MaxCompletionTokens { get; set; } = 4000;

    public int TimeoutSeconds { get; set; } = 180;
}
