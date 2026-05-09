using System.Text.Json;
using System.Text.Json.Nodes;
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

    /// <summary>
    /// Resets the <c>ClaimLineRefresh</c> flag to <c>false</c> in the lab's JSON config file
    /// after a successful refresh run, so the next scheduled execution resumes normal
    /// (skip-if-already-loaded) behaviour.
    /// Uses <see cref="JsonNode"/> for a surgical single-field update that leaves all
    /// other keys and values in the file unchanged.
    /// </summary>
    /// <returns><c>true</c> when the file was updated; <c>false</c> on any error.</returns>
    public static bool TryResetClaimLineRefresh(string labConfigFolder, string labName, AppLogger log)
    {
        var filePath = Path.Combine(labConfigFolder, $"{labName}.json");
        try
        {
            var json = File.ReadAllText(filePath);
            var node = JsonNode.Parse(json);

            if (node is not JsonObject obj)
            {
                log.Warn($"  [Refresh] Cannot reset ClaimLineRefresh — {filePath} is not a JSON object.");
                return false;
            }

            // Find the key case-insensitively (mirrors how the deserialiser loads it).
            var existingKey = obj.Select(p => p.Key)
                                 .FirstOrDefault(k => k.Equals("ClaimLineRefresh", StringComparison.OrdinalIgnoreCase));

            if (existingKey is null)
            {
                log.Warn($"  [Refresh] ClaimLineRefresh key not found in {filePath} — nothing to reset.");
                return false;
            }

            obj[existingKey] = false;

            File.WriteAllText(filePath,
                obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

            log.Info($"  [Refresh] ClaimLineRefresh reset to false in {filePath}.");
            return true;
        }
        catch (Exception ex)
        {
            log.Error($"  [Refresh] Failed to reset ClaimLineRefresh in {filePath}: {ex.Message}");
            return false;
        }
    }
}
