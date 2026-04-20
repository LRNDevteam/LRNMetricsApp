using System.Text.Json;
using CodingMasterGenerator.Models;

namespace CodingMasterGenerator.Services;

/// <summary>
/// Loads lab configs from individual JSON files in the LabConfigFolder.
/// Each file is named {LabName}.json.
/// </summary>
public static class LabConfigLoader
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    /// <summary>Loads configs for all specified lab names. Skips labs whose config file is missing.</summary>
    public static List<LabConfig> LoadAll(string labConfigFolder, IEnumerable<string> labNames, AppLogger log)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(labConfigFolder);
        ArgumentNullException.ThrowIfNull(labNames);

        var results = new List<LabConfig>();

        foreach (var labName in labNames)
        {
            var filePath = Path.Combine(labConfigFolder, $"{labName}.json");
            if (!File.Exists(filePath))
            {
                log.Warn($"  Lab config not found, skipping '{labName}': {filePath}");
                continue;
            }

            try
            {
                var json = File.ReadAllText(filePath);
                var config = JsonSerializer.Deserialize<LabConfig>(json, JsonOpts) ?? new LabConfig();
                config.LabName = labName;
                results.Add(config);
                log.Info($"  Loaded config for '{labName}'");
            }
            catch (Exception ex)
            {
                log.Error($"  Failed to load '{labName}': {ex.Message}");
            }
        }

        return results;
    }
}
