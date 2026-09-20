namespace LabMetricsDashboard.Services;

/// <summary>
/// The lab whose <b>reporting logic</b> a lab borrows: the table and stored-procedure prefixes
/// (<c>Cove_UnbilledAging</c>, <c>usp_GetCove_PayerBreakdown</c>), the claim-level column set and
/// the LIS Summary template.
///
/// <para>Only the demo lab needs one. LRNLabDemo is a de-identified clone, so its database carries
/// the prefixes of the lab it was cloned from rather than its own name - every report resolved
/// <c>LRNLabDemo_*</c>, found nothing, and came up empty. Pointing it at the clone source fixes all
/// of them at once instead of adding an LRNLabDemo entry to each of the five prefix maps.</para>
/// </summary>
/// <remarks>
/// <b>This is a logic alias, never a data one.</b> The connection string still comes from the lab's
/// own config, so an aliased lab reads its own database - the alias only decides which object names
/// are asked for inside it. Two things must therefore keep using the lab's real name:
/// <list type="bullet">
///   <item>connection-string and lab-config lookups, or the demo would read the source lab's data;</item>
///   <item><see cref="DemoLabPrivacy"/>, which withholds identifying columns by matching the lab's
///   OWN name - aliasing there would un-redact the demo.</item>
/// </list>
/// </remarks>
public static class LabLogicAlias
{
    private static readonly Dictionary<string, string> _aliases = new(StringComparer.OrdinalIgnoreCase)
    {
        // Re-cloned from Cove: LRNDemoLab holds Cove_* tables and usp_GetCove_* procedures.
        // It was cloned from PCR originally, which is why several maps still said "PCR".
        ["LRNLabDemo"] = "Cove",
        ["LRNDemo"] = "Cove",
    };

    /// <summary>
    /// The lab name to resolve report objects under: the clone source for a demo lab, and the lab
    /// itself for every other. Never returns null for a non-empty input.
    /// </summary>
    public static string? Resolve(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName)) return labName;

        var name = labName.Trim();
        if (_aliases.TryGetValue(name, out var alias)) return alias;

        // Tolerant of the underscore/space variants the configs and the tracker disagree on.
        var squashed = name.Replace("_", string.Empty).Replace(" ", string.Empty);
        return _aliases.TryGetValue(squashed, out var alias2) ? alias2 : name;
    }

    /// <summary>True when the lab reports under another lab's object names.</summary>
    public static bool IsAliased(string? labName)
        => !string.IsNullOrWhiteSpace(labName)
           && !string.Equals(Resolve(labName), labName!.Trim(), StringComparison.OrdinalIgnoreCase);
}
