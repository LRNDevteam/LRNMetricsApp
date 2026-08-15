namespace LabMetricsDashboard.Models;

/// <summary>
/// The "ReportAvailability" section of appsettings.json — which labs each report on the Report
/// Control Board is offered to, and whether the report is offered at all.
///
/// This is the knob an admin turns: a report with no rule here keeps the built-in behaviour
/// (the catalog's own lab list plus the lab's feature flag), so the section starts out as an
/// override layer and only the reports listed in it are governed from configuration.
///
/// Bound through <see cref="Microsoft.Extensions.Options.IOptionsMonitor{T}"/>, and appsettings.json
/// is loaded with reloadOnChange, so adding or removing a lab takes effect on the next page load
/// without restarting the site.
/// </summary>
public sealed class ReportAvailabilitySettings
{
    /// <summary>
    /// Keyed by report name. The key is matched loosely against the report's tracker column
    /// ("Coding Validation"), its display name, and its short column header ("Coding"), ignoring
    /// case, spaces and punctuation — so "Coding Validation", "CodingValidation" and "Coding" all
    /// address the same report.
    /// </summary>
    public Dictionary<string, ReportAvailabilityRule> Reports { get; set; } =
        new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>One report's availability rule. See <see cref="ReportAvailabilitySettings"/>.</summary>
public sealed class ReportAvailabilityRule
{
    /// <summary>
    /// Master switch. False locks the report for every lab — use it to retire or pause a report
    /// without deleting its lab list.
    /// </summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// The labs this report is offered to. Empty means every lab. Names are matched on a
    /// normalised token, so "PCRLabsofAmerica", "PCR Labs of America" and "PCRLabsofAmericaLRN"
    /// are the same lab.
    /// </summary>
    public List<string> Labs { get; set; } = [];

    /// <summary>
    /// Labs to lock out even when <see cref="Labs"/> would allow them. Lets you keep "every lab
    /// except these two" without listing the other ten. Applied before <see cref="Labs"/>.
    /// </summary>
    public List<string> ExcludeLabs { get; set; } = [];

    /// <summary>
    /// Shown in the cell tooltip when this rule locks a report, so the board can say WHY rather
    /// than just "not available". Optional.
    /// </summary>
    public string? Note { get; set; }
}
