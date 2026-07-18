namespace LabMetricsDashboard.Services;

/// <summary>
/// Maps a lab key (as it appears in <c>appsettings</c>'s <c>Labs</c> section) to the
/// 2-4 letter table prefix used by the Collection Summary aggregate tables
/// (e.g. <c>NW_CS_Top5ReimbursementPct</c>, <c>Aug_CS_PanelAverages</c>).
///
/// The same prefixes are used by <c>ClaimLineDbService.BuildCollectionSummarySpList</c>
/// and by every <c>13_{Lab}_CollectionSummary.sql</c> / <c>11_NorthWest_CollectionSummary.sql</c> deployment file.
/// Keep all three in sync when adding a new lab.
/// </summary>
internal static class LabCollectionPrefix
{
    private static readonly Dictionary<string, string> _map = new(StringComparer.OrdinalIgnoreCase)
    {
        // Keys mirror the lab names in appsettings.json -> LabConfig.Labs / LabsID.Name.
        // Both with-underscore and no-underscore variants are accepted to be tolerant
        // of legacy configs and the LabSelectionHelper.Resolve normalisation.
        ["NorthWest"]          = "NW",
        ["NW"]                 = "NW",   // alias: lab config key may be "NW" not "NorthWest"
        ["North_West"]         = "NW",
        ["Augustus"]           = "Aug",
        ["Augustus_Labs"]      = "Aug",
        ["AugustusLabs"]       = "Aug",
        ["BeechTree"]          = "BT",
        ["Beech_Tree"]         = "BT",
        // Certus: UI/config key is usually "Certus"; some DBs/scripts use CERT / Cert.
        ["Certus"]             = "Cert",
        ["Certus_LRN"]         = "Cert",
        ["CertusLabs"]         = "Cert",
        ["Certus_Labs"]        = "Cert",
        ["CERT"]               = "Cert",
        ["Cert"]               = "Cert",
        ["Cove"]               = "Cove",
        ["Elixir"]             = "Elix",
        ["PhiLife"]            = "Phi",
        ["Phi_Life"]           = "Phi",
        ["PCRLabsofAmerica"]   = "PCR",
        ["PCR_Labs_of_America"]= "PCR",
        ["RisingTides"]        = "RT",
        ["Rising_Tides"]       = "RT",
        ["InHealthDTR"]        = "IHD",
        ["Inhealth_DTR"]       = "IHD",
        ["InHealthDTRLRN"]     = "IHD",
        ["InHealth_DTR"]       = "IHD",
    };

    /// <summary>
    /// Returns the table prefix for the given lab name, or <c>null</c> when the lab
    /// has no Collection Summary aggregate tables deployed.
    /// Matching is case-insensitive and tolerant of underscores / spaces, so
    /// <c>"Beech_Tree"</c>, <c>"BeechTree"</c> and <c>"beech tree"</c> all resolve to <c>"BT"</c>.
    /// </summary>
    public static string? GetPrefix(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName)) return null;
        if (_map.TryGetValue(labName, out var p)) return p;

        // Fallback: strip underscores/spaces and re-try (handles "Beech Tree" → "BeechTree").
        var normalized = labName.Replace("_", string.Empty).Replace(" ", string.Empty);
        return _map.TryGetValue(normalized, out var p2) ? p2 : null;
    }

    /// <summary>
    /// Prefixes to try when resolving Collection Summary SPs/tables.
    /// For Certus, both <c>Cert</c> and <c>CERT</c> are tried (some deployments use either).
    /// </summary>
    public static IReadOnlyList<string> GetPrefixCandidates(string? labName)
    {
        var primary = GetPrefix(labName);
        if (string.IsNullOrWhiteSpace(primary))
            return Array.Empty<string>();

        if (primary.Equals("Cert", StringComparison.OrdinalIgnoreCase))
            return ["Cert", "CERT"];

        return [primary];
    }

    /// <summary>
    /// Returns the correct <c>ClaimLevelData</c> column to use for the Panel filter dropdown.
    /// <list type="bullet">
    ///   <item>NorthWest ? <c>PanelType</c> (NW field-mappings write to PanelType)</item>
    ///   <item>All other labs ? <c>PanelName</c> (confirmed by SSMS results and aggregate SP schemas)</item>
    /// </list>
    /// NOTE: Augustus was originally thought to use PanelNew, but its CollectionSummary SPs
    /// and actual ClaimLevelData rows both use PanelName � confirmed by live SSMS query.
    /// </summary>
    public static string GetPanelColumn(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName)) return "PanelName";

        var normalized = labName.Replace("_", string.Empty).Replace(" ", string.Empty);

        return normalized.Equals("NorthWest", StringComparison.OrdinalIgnoreCase)
            || normalized.Equals("NW", StringComparison.OrdinalIgnoreCase)
            ? "PanelType"
            : "PanelName";
    }
}
