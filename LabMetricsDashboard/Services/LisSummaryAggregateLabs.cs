namespace LabMetricsDashboard.Services;

/// <summary>
/// Labs whose LIS Summary is served from pre-built aggregate tables
/// (dbo.{Prefix}LIS_FieldSets / _SummaryGroups / _KeyMetricsDaily / _FilterOptions / _RefreshLog)
/// instead of grouping dbo.LIMSMaster on every page load. The tables are created by
/// Sql/{Lab}/25_{Lab}_LISSummary_Aggregate_Tables.sql and refreshed by
/// ClaimLineCSVDataCapture when a new LIMS file lands.
/// </summary>
public static class LisSummaryAggregateLabs
{
    private static readonly Dictionary<string, string> PrefixByLabName = new(StringComparer.OrdinalIgnoreCase)
    {
        ["AnalyzePathology"] = "AnP_",
        ["Analyze_Pathology"] = "AnP_",
        ["Analyze Pathology"] = "AnP_",
        ["AnalyzePathology_LRN"] = "AnP_",
    };

    private static readonly Dictionary<int, string> PrefixByLabId = new()
    {
        [26] = "AnP_",
    };

    public static bool TryGetTablePrefix(string? labName, int? labId, out string prefix)
    {
        if (!string.IsNullOrWhiteSpace(labName) && PrefixByLabName.TryGetValue(labName.Trim(), out var byName))
        {
            prefix = byName;
            return true;
        }

        if (labId.HasValue && PrefixByLabId.TryGetValue(labId.Value, out var byId))
        {
            prefix = byId;
            return true;
        }

        prefix = string.Empty;
        return false;
    }
}
