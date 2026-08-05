using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Resolves the tracker's lab display name to the LabSettings config key used by every
/// <c>?lab=</c> route.
///
/// The two never agreed: the tracker writes what the pipeline calls the lab
/// ("PCR Labs of America", "Phi Life"), while the config is keyed on the folder-safe name
/// ("PCRLabsofAmerica", "Phi_Life"). Matching is therefore attempted exact first, then on a
/// squashed form, then on the DB lab name a lab may override.
/// </summary>
public interface ILabNameResolver
{
    /// <summary>The config key for a tracker lab name, or null when nothing matches.</summary>
    string? Resolve(string? trackerLabName);
}

public sealed class LabNameResolver : ILabNameResolver
{
    private readonly LabSettings _labSettings;
    private readonly ILogger<LabNameResolver> _logger;

    public LabNameResolver(LabSettings labSettings, ILogger<LabNameResolver> logger)
    {
        _labSettings = labSettings;
        _logger = logger;
    }

    public string? Resolve(string? trackerLabName)
    {
        if (string.IsNullOrWhiteSpace(trackerLabName)) return null;
        var name = trackerLabName.Trim();

        // The dictionary reference is swapped atomically on config reload - read it once.
        var labs = _labSettings.Labs;

        // 1. exact key
        var exact = labs.Keys.FirstOrDefault(k => string.Equals(k, name, StringComparison.OrdinalIgnoreCase));
        if (exact is not null) return exact;

        // 2. squashed: "PCR Labs of America" == "PCRLabsofAmerica", "Phi Life" == "Phi_Life"
        var squashed = Squash(name);
        var loose = labs.Keys.FirstOrDefault(k => Squash(k) == squashed);
        if (loose is not null) return loose;

        // 3. the lab's own DB name override
        var byDbName = labs.FirstOrDefault(kv =>
            !string.IsNullOrWhiteSpace(kv.Value.DbLabName) &&
            (string.Equals(kv.Value.DbLabName, name, StringComparison.OrdinalIgnoreCase) ||
             Squash(kv.Value.DbLabName!) == squashed));
        if (byDbName.Key is not null) return byDbName.Key;

        _logger.LogWarning("Report board: tracker lab '{TrackerLab}' does not match any lab configuration; its row will be read-only.", name);
        return null;
    }

    /// <summary>Lower-cased with spaces, underscores, dots and hyphens removed.</summary>
    internal static string Squash(string value)
        => new((value ?? string.Empty)
            .Where(c => c is not (' ' or '_' or '.' or '-'))
            .Select(char.ToLowerInvariant)
            .ToArray());
}
