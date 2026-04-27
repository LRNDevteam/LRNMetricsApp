namespace LabMetricsDashboard.Models;

/// <summary>
/// Mirrors the "LabConfig" section in appsettings.json.
/// </summary>
public sealed class LabConfigOptions
{
    public const string Section = "LabConfig";

    public string LabConfigFolder { get; init; } = string.Empty;
    public List<string> Labs { get; init; } = [];
    public List<LabIdInfo> LabsID { get; init; } = [];

    public string? GetLabNameById(int id) =>
        LabsID.FirstOrDefault(l => l.Id == id)?.Name;

    public int? GetLabIdByName(string name) =>
        LabsID.FirstOrDefault(l => string.Equals(l.Name, name, StringComparison.OrdinalIgnoreCase))?.Id;
}

/// <summary>
/// Lab Id ? Name mapping, sourced from <c>LabConfig:LabsID</c> in appsettings.json.
/// </summary>
public sealed class LabIdInfo
{
    public int Id { get; init; }
    public string Name { get; init; } = string.Empty;
}

/// <summary>
/// Runtime-resolved CSV paths for every lab, keyed by lab name.
/// Populated in Program.cs from the per-lab JSON files in LabConfigFolder.
/// </summary>
public sealed class LabSettings
{
    // NOTE: This is updated at runtime when lab JSON files change (reloadOnChange).
    // Replace the dictionary reference atomically to avoid thread-safety issues.
    public Dictionary<string, LabCsvConfig> Labs { get; set; } = [];
}
