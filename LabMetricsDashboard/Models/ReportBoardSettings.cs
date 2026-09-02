using LabMetricsDashboard.Services;

namespace LabMetricsDashboard.Models;

/// <summary>
/// The "ReportBoard" section of appsettings.json — the two per-lab knobs on the Report Control
/// Board that are easier to get right in one central list than spread across a dozen lab files:
/// the order the labs appear in, and which labs never raise the "not generated" warning.
///
/// Deliberately kept out of the per-lab config: <see cref="LabOrder"/> is a SEQUENCE, and a
/// sequence stored as a number in twelve separate files drifts the first time a lab is inserted
/// in the middle. Here the position in the list IS the order — reorder the lines, done.
///
/// Bound through <see cref="Microsoft.Extensions.Options.IOptionsMonitor{T}"/>, and appsettings.json
/// is loaded with reloadOnChange, so an edit takes effect on the next page load without a restart.
/// </summary>
public sealed class ReportBoardSettings
{
    public const string Section = "ReportBoard";

    /// <summary>
    /// Labs in the order they appear on the board. Position in the list is the order; labs not
    /// listed here fall to the end, ordered A–Z. Names are matched on the same normalised token
    /// the rest of the board uses, so "Cove", "CoveLRN" and "Cove_LRN" are the same lab.
    /// </summary>
    public List<string> LabOrder { get; set; } = [];

    /// <summary>
    /// Labs whose missing reports are expected rather than stalled — still live on the board, but
    /// no warning banner, no Overdue count and no row badge. For labs that have stopped billing
    /// and so have no recent reports to generate. Matched the same way as <see cref="LabOrder"/>.
    /// </summary>
    public List<string> NoMissingReportWarning { get; set; } = [];

    /// <summary>
    /// Board position for a lab: its index in <see cref="LabOrder"/>, or <see cref="int.MaxValue"/>
    /// when it is not listed. Both the config key and the tracker's display name are tried, since
    /// an unmapped lab has only the latter.
    /// </summary>
    public int OrderOf(string? labKey, string? labDisplayName)
    {
        var candidates = Tokens(labKey, labDisplayName);
        if (candidates.Count == 0) return int.MaxValue;

        for (var i = 0; i < LabOrder.Count; i++)
        {
            var token = ReportCatalog.LabToken(LabOrder[i]);
            if (token.Length > 0 && candidates.Contains(token)) return i;
        }

        return int.MaxValue;
    }

    /// <summary>Whether this lab is on the <see cref="NoMissingReportWarning"/> list.</summary>
    public bool SuppressesMissingReportWarning(string? labKey, string? labDisplayName)
    {
        if (NoMissingReportWarning.Count == 0) return false;

        var candidates = Tokens(labKey, labDisplayName);
        if (candidates.Count == 0) return false;

        return NoMissingReportWarning.Any(lab =>
        {
            var token = ReportCatalog.LabToken(lab);
            return token.Length > 0 && candidates.Contains(token);
        });
    }

    private static HashSet<string> Tokens(string? labKey, string? labDisplayName)
        => new[] { labKey, labDisplayName }
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(ReportCatalog.LabToken)
            .Where(t => t.Length > 0)
            .ToHashSet(StringComparer.Ordinal);
}
