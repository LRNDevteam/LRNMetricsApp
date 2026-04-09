using System.Text.Json;
using ClaimLineCSVDataCapture.Models;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Loads all lab configs from the LabConfigFolder.
/// Each file is named {LabName}.json and contains a flat <see cref="LabConfig"/> object at the root.
/// </summary>
public static class LabConfigLoader
{
    private static readonly JsonSerializerOptions _opts = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling         = JsonCommentHandling.Skip,
        AllowTrailingCommas         = true,
    };

    public static List<LabConfig> LoadAll(string labConfigFolder, IEnumerable<string> labNames, AppLogger log)
    {
        var results = new List<LabConfig>();

        foreach (var labName in labNames)
        {
            var filePath = Path.Combine(labConfigFolder, $"{labName}.json");
            if (!File.Exists(filePath))
            {
                log.Warn($"  [WARN] Lab config not found, skipping '{labName}': {filePath}");
                continue;
            }

            try
            {
                var json = File.ReadAllText(filePath);
                var config = JsonSerializer.Deserialize<LabConfig>(json, _opts)
                             ?? new LabConfig();

                config.LabName = labName;
                results.Add(config);

                log.Info($"  [OK] Loaded config for '{labName}' — ClaimLineInsert={config.ClaimLineInsert}, DBEnabled={config.DBEnabled}");
            }
            catch (Exception ex)
            {
                log.Error($"  Failed to load '{labName}': {ex.Message}");
            }
        }

        return results;
    }
}
