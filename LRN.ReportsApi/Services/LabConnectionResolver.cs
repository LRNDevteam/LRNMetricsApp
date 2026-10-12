using System.Text.Json;

namespace LRN.ReportsApi.Services;

internal static class LabConnectionResolver
{
    public static string Resolve(IConfiguration configuration, int labId, string labName, string? connectionKey = null)
        => Resolve(configuration, labId, labName, connectionKey, out _);

    /// <param name="source">Which setting supplied the connection (ConnectionStrings:Lab_2, a lab file,
    /// ConnectionStrings:InHealthConn ...), so a lab that reaches the wrong database can be traced.</param>
    public static string Resolve(IConfiguration configuration, int labId, string labName, string? connectionKey, out string source)
    {
        // With a Key Vault configured, lab connections come from the vault's secrets ONLY: no lab
        // file, no appsettings, no environment variable can point an environment at another
        // environment's database. Without a vault (local development) every source is used as before.
        var vault = KeyVaultProvider(configuration);
        var from = vault is null ? "" : "Key Vault secret ";
        string? Get(string name)
        {
            if (vault is null) return configuration.GetConnectionString(name);
            return vault.TryGet($"ConnectionStrings:{name}", out var value) ? value : null;
        }

        source = $"{from}ConnectionStrings:Lab_{labId}";
        var byId = Get($"Lab_{labId}");
        if (!string.IsNullOrWhiteSpace(byId)) return byId;

        if (vault is null)
        {
            var fromLabFile = ReadLabFileConnection(configuration["LabConfig:LabConfigFolder"], labName, out var labFile);
            source = $"lab file {labFile}";
            if (!string.IsNullOrWhiteSpace(fromLabFile)) return fromLabFile;
        }

        if (!string.IsNullOrWhiteSpace(connectionKey))
        {
            source = $"{from}ConnectionStrings:{connectionKey.Trim()}";
            var byConnectionKey = Get(connectionKey.Trim());
            if (!string.IsNullOrWhiteSpace(byConnectionKey)) return byConnectionKey;
        }

        var normalized = NormalizeKey(labName);
        var knownKey = normalized switch
        {
            "PCRLABSOFAMERICA" or "PCRLOA" => "PCRLOAConnStr",
            "COVE" => "CoveConnection",
            "INHEALTHDTR" or "INHEALTH" => "InHealthConn",
            "ELIXIR" => "ElixirConnection",
            "VARIANTX" => "VariantXConnection",
            "ANALYZEPATHOLOGY" => "AnalyzePathologyConnStr",
            "WELLHEALTH" => "WellHealthConnStr",
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
            source = $"{from}ConnectionStrings:{knownKey}";
            var conn = Get(knownKey);
            if (!string.IsNullOrWhiteSpace(conn)) return conn;
        }

        var names = vault is null
            ? configuration.GetSection("ConnectionStrings").GetChildren().Select(s => s.Key)
            : vault.GetChildKeys([], "ConnectionStrings").Distinct(StringComparer.OrdinalIgnoreCase);
        foreach (var name in names)
        {
            var key = NormalizeKey(name);
            if (key.Contains(normalized, StringComparison.OrdinalIgnoreCase)
                || normalized.Contains(key.Replace("CONNECTION", "").Replace("CONNSTR", ""), StringComparison.OrdinalIgnoreCase))
            {
                source = $"{from}ConnectionStrings:{name} (name match)";
                return Get(name) ?? string.Empty;
            }
        }

        source = vault is null ? "none" : "none - no matching Key Vault secret";
        return string.Empty;
    }

    /// <summary>The Azure Key Vault configuration provider, when KeyVault:Uri added one.</summary>
    private static IConfigurationProvider? KeyVaultProvider(IConfiguration configuration)
        => (configuration as IConfigurationRoot)?.Providers
            .LastOrDefault(p => p.GetType().Name.Contains("AzureKeyVault", StringComparison.OrdinalIgnoreCase));

    /// <summary>Server and database of a connection string, never the credentials.</summary>
    public static string Describe(string? connectionString)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return "(none)";
        try
        {
            var b = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder(connectionString);
            return $"database '{b.InitialCatalog}' on '{b.DataSource}'";
        }
        catch (ArgumentException)
        {
            return "(unreadable connection string)";
        }
    }

    private static string? ReadLabFileConnection(string? folder, string labName, out string? path)
    {
        path = null;
        if (string.IsNullOrWhiteSpace(folder) || !Directory.Exists(folder)) return null;

        var exactPath = Path.Combine(folder, $"{labName}.json");
        var paths = File.Exists(exactPath)
            ? new[] { exactPath }
            : Directory.EnumerateFiles(folder, "*.json", SearchOption.TopDirectoryOnly)
                .Where(path => NormalizeKey(Path.GetFileNameWithoutExtension(path)) == NormalizeKey(labName));

        foreach (var candidate in paths)
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(candidate));
                if (TryFindConnection(document.RootElement, out var connection))
                {
                    path = candidate;
                    return connection;
                }
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
