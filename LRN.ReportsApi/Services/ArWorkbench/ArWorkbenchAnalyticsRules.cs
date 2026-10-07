using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// The pure parts of Recovery &amp; Financial Analytics (T071), kept out of the SQL so they can be
/// unit-tested.
/// </summary>
public static class ArWorkbenchAnalyticsRules
{
    /// <summary>How many bars a high-cardinality dimension (payer, panel, agent) shows before the rest roll up.</summary>
    public const int MaxBars = 15;

    /// <summary>
    /// The mockup's groupRecovery order (recovered + outstanding, largest first), keeping the first
    /// <paramref name="max"/> rows and summing the rest into one "All other (n)" row that cannot drill.
    /// </summary>
    public static List<ArWorkbenchRecoveryRow> TopWithOther(IEnumerable<ArWorkbenchRecoveryRow> rows, int max = MaxBars)
    {
        var ordered = rows.OrderByDescending(r => r.Recovered + r.Outstanding).ThenBy(r => r.Label, StringComparer.OrdinalIgnoreCase).ToList();
        if (max < 1 || ordered.Count <= max) return ordered;

        var rest = ordered.Skip(max - 1).ToList();
        var result = ordered.Take(max - 1).ToList();
        result.Add(new ArWorkbenchRecoveryRow
        {
            Label = $"All other ({rest.Count})",
            Key = null,
            Count = rest.Sum(r => r.Count),
            InitialAR = rest.Sum(r => r.InitialAR),
            Recovered = rest.Sum(r => r.Recovered),
            Outstanding = rest.Sum(r => r.Outstanding)
        });
        return result;
    }

    /// <summary>Recovered / initial insurance AR; 0 when nothing was identified (no divide by zero).</summary>
    public static decimal RecoveryRate(decimal recovered, decimal initialAR)
        => initialAR > 0 ? Math.Round(recovered / initialAR, 4) : 0m;
}
