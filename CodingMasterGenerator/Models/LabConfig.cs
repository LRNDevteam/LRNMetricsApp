using System.Text.Json.Serialization;

namespace CodingMasterGenerator.Models;

/// <summary>
/// Configuration for a single lab, loaded from its dedicated JSON config file.
/// Only the fields needed by CodingMasterGenerator are included.
/// </summary>
public sealed class LabConfig
{
    public string LabName { get; set; } = string.Empty;

    [JsonPropertyName("Paths")]
    public LabPaths Paths { get; set; } = new();

    [JsonPropertyName("Output")]
    public LabOutput Output { get; set; } = new();

    /// <summary>
    /// Combined path: <c>ServerMastersBasePath</c> \ <c>ServerMasterFolderName</c>.
    /// This is where Claim Level and Line Level CSV files are located.
    /// </summary>
    [JsonIgnore]
    public string ServerMastersPath =>
        string.IsNullOrWhiteSpace(Paths.ServerMastersBasePath) || string.IsNullOrWhiteSpace(Paths.ServerMasterFolderName)
            ? string.Empty
            : Path.Combine(Paths.ServerMastersBasePath, Paths.ServerMasterFolderName);
}

public sealed class LabPaths
{
    /// <summary>Root base folder for this lab's server master files.</summary>
    public string ServerMastersBasePath { get; set; } = string.Empty;

    /// <summary>Sub-folder name under <see cref="ServerMastersBasePath"/> that contains the CSV hierarchy.</summary>
    public string ServerMasterFolderName { get; set; } = string.Empty;
}

public sealed class LabOutput
{
    /// <summary>Root output folder for reports (e.g., CodingMaster Excel files).</summary>
    public string Reports { get; set; } = string.Empty;
}
