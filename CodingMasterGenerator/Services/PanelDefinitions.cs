namespace CodingMasterGenerator.Services;

/// <summary>
/// Static reference data: panel CPT definitions, ABR CPT list, and
/// the mapping from Coding Master Panel Name to Production Panel Name.
/// </summary>
public static class PanelDefinitions
{
    /// <summary>
    /// Known panel CPT definitions. Key = panel base name, Value = set of expected CPT codes.
    /// Used when the data does not already have a Panelname populated.
    /// </summary>
    public static readonly Dictionary<string, HashSet<string>> PanelCptMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["GI Panel"] = ["87507", "87506"],
        ["RPP Panel"] = ["87798", "87594", "87653", "87651", "87640", "87581", "87541", "87486", "87633"],
        ["UTI"] = ["87481", "87500", "87640", "87641", "87653", "87798"],
        ["STI"] = ["87491", "87511", "87529", "87563", "87591", "87625", "87640", "87653", "87661", "87798"],
        ["Womens Health"] = ["87481", "87491", "87500", "87511", "87529", "87563", "87591", "87625", "87640", "87653", "87661", "87798"],
        ["Nail-87798"] = ["87481", "87798"],
        ["Nail-87801"] = ["87481", "87801"],
        ["Wound-87798"] = ["87529", "87640", "87651", "87653", "87481", "87798"],
        ["Wound-87801"] = ["87481", "87500", "87529", "87640", "87641", "87651", "87653", "87801"],
    };

    /// <summary>ABR CPT codes. If any of these appear on a claim, " + ABR" is appended to the panel name.</summary>
    public static readonly HashSet<string> AbrCpts =
        ["87500", "87640", "87486", "87529", "87563", "87798", "87633", "87631"];

    /// <summary>Panels that should NOT get the ABR suffix even if ABR CPTs are present.</summary>
    public static readonly HashSet<string> AbrExcludedBasePanels =
        new(StringComparer.OrdinalIgnoreCase) { "GI Panel", "GI", "STI" };

    /// <summary>
    /// Maps Coding Master Panel Name ? Production Panel Name.
    /// If a key is not found, the Coding Master Panel Name itself is used as production name.
    /// </summary>
    public static readonly Dictionary<string, string> ProductionPanelMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["GI Panel"] = "GI",
        ["RPP Panel"] = "RPP",
        ["RPP + ABR"] = "RPP",
        ["RPP Panel + ABR"] = "RPP",
        ["UTI"] = "UTI",
        ["UTI + ABR"] = "UTI",
        ["STI"] = "STI",
        ["Womens Health"] = "WOMEN'S HEALTH",
        ["Womens Health + ABR"] = "WOMEN'S HEALTH",
        ["Nail-87798"] = "Nail-87798",
        ["Nail-87798 + ABR"] = "Nail-87798",
        ["Nail-87801"] = "Nail-87801",
        ["Wound-87798"] = "WOUND",
        ["Wound-87798 + ABR"] = "WOUND",
        ["Wound-87801"] = "WOUND",
        ["Wound + ABR-87801"] = "WOUND",
    };

    /// <summary>
    /// Detects a panel name by comparing the claim's CPT set against known panel definitions.
    /// Returns the panel with the most matching CPTs, or "Unknown" if no match.
    /// </summary>
    public static string DetectPanel(HashSet<string> claimCpts)
    {
        string bestPanel = "Unknown";
        int bestCount = 0;

        foreach (var (panel, expectedCpts) in PanelCptMap)
        {
            int matchCount = claimCpts.Count(c => expectedCpts.Contains(c));
            if (matchCount > bestCount)
            {
                bestCount = matchCount;
                bestPanel = panel;
            }
        }

        return bestPanel;
    }

    /// <summary>
    /// Determines if ABR suffix should be appended based on the claim's CPTs and base panel.
    /// </summary>
    public static bool ShouldAppendAbr(HashSet<string> claimCpts, string basePanel)
    {
        if (AbrExcludedBasePanels.Contains(basePanel))
            return false;

        return claimCpts.Any(c => AbrCpts.Contains(c));
    }

    /// <summary>
    /// Gets the Production Panel Name for a given Coding Master Panel Name.
    /// Falls back to the input if no mapping is found.
    /// </summary>
    public static string GetProductionPanelName(string codingMasterPanelName)
    {
        return ProductionPanelMap.TryGetValue(codingMasterPanelName, out var prod)
            ? prod
            : codingMasterPanelName;
    }
}
