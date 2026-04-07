using System.Text.Json;
using System.Text.Json.Serialization;
using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

/// <summary>
/// Accepts both JSON boolean (true/false) and string ("true"/"false"/"1"/"0")
/// so lab config files edited by hand stay resilient to quoting mistakes.
/// </summary>
file sealed class LenientBoolConverter : JsonConverter<bool>
{
    public override bool Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.True)  return true;
        if (reader.TokenType == JsonTokenType.False) return false;

        if (reader.TokenType == JsonTokenType.String)
        {
            var s = reader.GetString() ?? string.Empty;
            if (bool.TryParse(s, out var result)) return result;
            if (s == "1") return true;
            if (s == "0") return false;
        }

        throw new JsonException(
            $"Cannot convert token '{reader.TokenType}' to bool. " +
            $"Use true/false or \"true\"/\"false\" in the lab JSON.");
    }

    public override void Write(Utf8JsonWriter writer, bool value, JsonSerializerOptions options)
        => writer.WriteBooleanValue(value);
}

public static class LabConfigLoader
{
    private static readonly JsonSerializerOptions _readOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling         = JsonCommentHandling.Skip,
        AllowTrailingCommas         = true,
        Converters                  = { new LenientBoolConverter() }
    };

    private static readonly JsonSerializerOptions _writeOptions = new()
    {
        WriteIndented          = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    /// <summary>
    /// Loads all active lab configs from {LabConfigFolder}\{labName}.json.
    /// Auto-derives ProcessingFolderPath if absent.
    /// Auto-creates Processing and Output directories.
    /// Clears stale LastProcessedFile when the file no longer exists on disk.
    /// </summary>
    public static List<(LabConfig Config, string ConfigFilePath)> LoadAll(
        LabConfigSettings labConfigSettings)
    {
        var results = new List<(LabConfig, string)>();

        if (!Directory.Exists(labConfigSettings.LabConfigFolder))
        {
            Directory.CreateDirectory(labConfigSettings.LabConfigFolder);
            Console.WriteLine($"[LabConfig] Created LabConfigFolder: {labConfigSettings.LabConfigFolder}");
            return results;
        }

        foreach (var labName in labConfigSettings.Labs)
        {
            var configFile = Path.Combine(labConfigSettings.LabConfigFolder, $"{labName}.json");

            if (!File.Exists(configFile))
            {
                Console.WriteLine($"[WARN] Lab config not found, skipping '{labName}': {configFile}");
                continue;
            }

            LabConfig config;
            try
            {
                config = JsonSerializer.Deserialize<LabConfig>(
                             File.ReadAllText(configFile), _readOptions)
                         ?? throw new InvalidOperationException("Deserialised to null.");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[ERROR] Failed to parse '{configFile}': {ex.Message}");
                continue;
            }

            // ── Clear stale runtime fields if the source file no longer exists ─
            if (!string.IsNullOrWhiteSpace(config.LastProcessedFile)
                && !File.Exists(config.LastProcessedFile))
            {
                Console.WriteLine($"[LabConfig] LastProcessedFile gone from disk — clearing: {config.LastProcessedFile}");
                config.LastProcessedFile         = null;
                config.LastProcessedRelativePath = null;
                config.LastOutputFilePath        = null;
                PatchConfigFile(configFile, config);
            }

            if (!Directory.Exists(config.InputFolderPath))
            {
                Console.WriteLine($"[WARN] Input folder missing, skipping '{labName}': {config.InputFolderPath}");
                continue;
            }

            // ── Auto-derive ProcessingFolderPath if not set ───────────────────
            bool patched = false;
            if (string.IsNullOrWhiteSpace(config.ProcessingFolderPath))
            {
                var parent = Path.GetDirectoryName(
                    config.InputFolderPath.TrimEnd(Path.DirectorySeparatorChar,
                                                   Path.AltDirectorySeparatorChar));
                config.ProcessingFolderPath = string.IsNullOrWhiteSpace(parent)
                    ? Path.Combine(config.InputFolderPath, "Processing")
                    : Path.Combine(parent, "Processing");
                Console.WriteLine($"[LabConfig] Derived ProcessingFolderPath: {config.ProcessingFolderPath}");
                patched = true;
            }

            if (!Directory.Exists(config.ProcessingFolderPath))
            {
                Directory.CreateDirectory(config.ProcessingFolderPath);
                Console.WriteLine($"[LabConfig] Created ProcessingFolderPath: {config.ProcessingFolderPath}");
            }

            if (!Directory.Exists(config.OutputFolderPath))
            {
                Directory.CreateDirectory(config.OutputFolderPath);
                Console.WriteLine($"[LabConfig] Created OutputFolderPath: {config.OutputFolderPath}");
            }

            if (patched) PatchConfigFile(configFile, config);

            Console.WriteLine($"[LabConfig] Loaded '{labName}'");
            Console.WriteLine($"            Input             : {config.InputFolderPath}");
            Console.WriteLine($"            Processing        : {config.ProcessingFolderPath}");
            Console.WriteLine($"            Output            : {config.OutputFolderPath}");
            Console.WriteLine($"            Last Processed    : {config.LastProcessedFile         ?? "(none)"}");
            Console.WriteLine($"            Last Relative Path: {config.LastProcessedRelativePath ?? "(none)"}");
            Console.WriteLine($"            Last Output File  : {config.LastOutputFilePath        ?? "(none)"}");

            // ── Log DB status ─────────────────────────────────────────────────
            if (config.EnableDatabaseInsert && !string.IsNullOrWhiteSpace(config.DbConnectionString))
                Console.WriteLine($"            DB Insert         : ENABLED");
            else if (config.EnableDatabaseInsert && string.IsNullOrWhiteSpace(config.DbConnectionString))
                Console.WriteLine($"            DB Insert         : ENABLED — [WARN] DbConnectionString is empty; DB insert will be skipped");
            else
                Console.WriteLine($"            DB Insert         : Disabled");

            results.Add((config, configFile));
        }

        return results;
    }

    /// <summary>Saves all runtime fields back to {LabName}.json after a successful run.</summary>
    public static void SaveLastProcessed(string configFilePath, LabConfig config)
    {
        try
        {
            File.WriteAllText(configFilePath, JsonSerializer.Serialize(config, _writeOptions));
            Console.WriteLine($"[LabConfig] Saved '{Path.GetFileName(configFilePath)}':");
            Console.WriteLine($"            LastProcessedFile         = {config.LastProcessedFile}");
            Console.WriteLine($"            LastProcessedRelativePath = {config.LastProcessedRelativePath}");
            Console.WriteLine($"            LastOutputFilePath        = {config.LastOutputFilePath}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[LabConfig] Failed to save '{configFilePath}': {ex.Message}");
        }
    }

    private static void PatchConfigFile(string configFilePath, LabConfig config)
    {
        try
        {
            File.WriteAllText(configFilePath, JsonSerializer.Serialize(config, _writeOptions));
            Console.WriteLine($"[LabConfig] Patched '{Path.GetFileName(configFilePath)}'.");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[LabConfig] [WARN] Could not patch '{configFilePath}': {ex.Message}");
        }
    }
}