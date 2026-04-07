namespace LabMetricsDashboard.Models;

/// <summary>
/// Mirrors the "LabConfig" section in appsettings.json.
/// </summary>
public sealed class LabConfigOptions
{
    public const string Section = "LabConfig";

    public string LabConfigFolder { get; init; } = string.Empty;
    public List<string> Labs { get; init; } = [];
}

/// <summary>
/// Runtime-resolved CSV paths for every lab, keyed by lab name.
/// Populated in Program.cs from the per-lab JSON files in LabConfigFolder.
/// </summary>
public sealed class LabSettings
{
    public Dictionary<string, LabCsvConfig> Labs { get; init; } = [];
}
