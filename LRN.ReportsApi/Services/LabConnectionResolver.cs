using System.Text.Json;

namespace LRN.ReportsApi.Services;

internal static class LabConnectionResolver
{
    public static string Resolve(IConfiguration configuration, int labId, string labName, string? connectionKey = null)
    {
        var byId = configuration.GetConnectionString($"Lab_{labId}");
        if (!string.IsNullOrWhiteSpace(byId)) return byId;

        var fromLabFile = ReadLabFileConnection(configuration["LabConfig:LabConfigFolder"], labName);
        if (!string.IsNullOrWhiteSpace(fromLabFile)) return fromLabFile;

        if (!string.IsNullOrWhiteSpace(connectionKey))
        {
            var byConnectionKey = configuration.GetConnectionString(connectionKey.Trim());
            if (!string.IsNullOrWhiteSpace(byConnectionKey)) return byConnectionKey;
        }

        var normalized = NormalizeKey(labName);
        var knownKey = normalized switch
        {
            "PCRLABSOFAMERICA" or "PCRLOA" => "PCRLOAConnStr",
            "COVE" => "CoveConnection",
            "INHEALTHDTR" or "INHEALTH" => "InHealthConn",
            "ELIXIR" => "ElixirConnection",
            "CERTUS" or "CERTUSLABORATORIES" => "CertusConnection",
            "BEECHTREE" => "BeechTreeConnStr",
            "AUGUSTUSLABS" or "AUGUSTUS" => "AugustusConnStr",
            "NORTHWEST" or "NWL" => "NWLConnection",
            "PCRDXAL" => "PCRALConnection",
            "PCRDXCO" => "PCRDxConnection",
            "PHILIFE" => "PhiLifeConnStr",
            "RISINGTIDES" => "RisingTidesConnStr",
            _ => string.Empty
        };

        if (!string.IsNullOrWhiteSpace(knownKey))
        {
            var conn = configuration.GetConnectionString(knownKey);
            if (!string.IsNullOrWhiteSpace(conn)) return conn;
        }

        foreach (var section in configuration.GetSection("ConnectionStrings").GetChildren())
        {
            var key = NormalizeKey(section.Key);
            if (key.Contains(normalized, StringComparison.OrdinalIgnoreCase)
                || normalized.Contains(key.Replace("CONNECTION", "").Replace("CONNSTR", ""), StringComparison.OrdinalIgnoreCase))
                return section.Value ?? string.Empty;
        }

        return string.Empty;
    }

    private static string? ReadLabFileConnection(string? folder, string labName)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Directory.Exists(folder)) return null;

        var exactPath = Path.Combine(folder, $"{labName}.json");
        var paths = File.Exists(exactPath)
            ? new[] { exactPath }
            : Directory.EnumerateFiles(folder, "*.json", SearchOption.TopDirectoryOnly)
                .Where(path => NormalizeKey(Path.GetFileNameWithoutExtension(path)) == NormalizeKey(labName));

        foreach (var path in paths)
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(path));
                if (TryFindConnection(document.RootElement, out var connection))
                    return connection;
            }
            catch (JsonException)
            {
                // Ignore malformed optional lab files and continue with configured fallbacks.
            }
            catch (IOException)
            {
                // Ignore unavailable optional lab files and continue with configured fallbacks.
            }
        }

        return null;
    }

    private static bool TryFindConnection(JsonElement element, out string? connection)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Name.Equals("DbConnectionString", StringComparison.OrdinalIgnoreCase)
                    && property.Value.ValueKind == JsonValueKind.String)
                {
                    connection = property.Value.GetString();
                    return !string.IsNullOrWhiteSpace(connection);
                }

                if (TryFindConnection(property.Value, out connection)) return true;
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
                if (TryFindConnection(item, out connection)) return true;
        }

        connection = null;
        return false;
    }

    private static string NormalizeKey(string value)
        => new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
}
