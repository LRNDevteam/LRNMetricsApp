using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Maps a workflow-tracker column to the page that shows that report.
///
/// The tracker is a pivot: report types are rows in dbo.ReportTypeMaster and become columns at
/// execution time, so this catalog is a lookup, never the source of the column list. A tracker
/// column with no entry here still renders - as a status-only cell - which is what keeps the board
/// working the day a new report type is added upstream. See docs/REPORT_CONTROL_BOARD.md.
/// </summary>
public static class ReportCatalog
{
    public const string GroupSource = "Source data";
    public const string GroupSummary = "Summary reports";
    public const string GroupAnalytics = "Analytics & validation";

    /// <summary>
    /// Labs that produce a Sales Rep Summary. Matched loosely — see <see cref="LabToken"/>.
    /// MUST stay declared above <see cref="Entries"/>: static field initialisers run in
    /// declaration order, so an entry built before this one would capture null and silently
    /// allow the report for every lab.
    /// </summary>
    private static readonly string[] SalesRepSummaryLabs = ["Cove", "Elixir"];

    /// <summary>Display order for the board, which is deliberately not the SP's column order.</summary>
    public static readonly IReadOnlyList<ReportCatalogEntry> Entries =
    [
        // LIMS Master is the first source (raw LIMS data), before Line/Claim Level. It is not a tracker
        // column of its own — always shown, and its status MIRRORS "LIS Summary" (StatusFrom): success
        // when LIS Summary succeeded, else failed. Opens the LIS Summary page's LIMS line-level tab.
        new("LIMS Master",             "LIMS Master",             "LIMS",     "bi-hdd-stack",            GroupSource,    "LisSummary",             "Index",                   null,               "line", "LIS Summary"),
        new("Line Level Master",       "Line Level Master",       "Line",     "bi-list-ul",              GroupSource,    "Dashboard",              "LineLevel",               "LineClaimEnable"),
        new("Claim Level Master",      "Claim Level Master",      "Claim",    "bi-file-text",            GroupSource,    "Dashboard",              "ClaimLevel",              "LineClaimEnable"),

        new("LIS Summary",             "LIS Summary",             "LIS",      "bi-clipboard2-pulse",     GroupSummary,   "LisSummary",             "Index",                   null),
        new("Production Summary",      "Production Summary",      "Prod",     "bi-bar-chart-steps",      GroupSummary,   "Dashboard",              "ProductionSummaryReport", "EnableProductionSummaryReport"),
        new("Collection Summary",      "Collection Summary",      "Collect",  "bi-cash-stack",           GroupSummary,   "CollectionSummary",      "Index",                   "EnableCollectionReport"),
        new("Executive Summary",       "Executive Summary",       "Exec",     "bi-table",                GroupSummary,   "ExecutiveSummary",       "Index",                   null),
        new("Clinic Summary",          "Clinic Summary",          "Clinic",   "bi-hospital",             GroupSummary,   "Dashboard",              "ClinicSummary",           "EnableClinicsummary"),
        // Sales Rep Summary is only produced for Cove and Elixir; everywhere else it is greyed
        // out as "not produced for this lab" rather than sitting empty as if it had failed.
        new("Sales Rep Summary",       "Sales Rep Summary",       "Sales",    "bi-people-fill",          GroupSummary,   "Dashboard",              "SalesRepSummary",         "EnableSalesRepsummary", null, null, SalesRepSummaryLabs),
        new("Denial Report",           "Denial Report",           "Denial",   "bi-exclamation-triangle", GroupSummary,   "DenialDashboard",        "Index",                   null),

        new("Coding Validation",       "Coding Validation",       "Coding",   "bi-pencil-square",        GroupAnalytics, "Coding",                 "Summary",                 "EnableCoding"),
        new("Payer Policy Validation", "Payer Policy Validation", "Policy",   "bi-shield-check",         GroupAnalytics, "PayerPolicyValidation",  "Index",                   "EnablePrediction"),
        new("Prediction Analysis",     "Prediction Analysis",     "Predict",  "bi-activity",             GroupAnalytics, "Prediction",             "Index",                   "EnablePrediction"),
        new("Forecasting",             "Forecasting",             "Forecast", "bi-calendar3",            GroupAnalytics, "Prediction",             "ForecastingSummary",      "EnableForcast")
    ];

    /// <summary>
    /// The three source reports. When all three succeed for a run, every other report available
    /// to that lab is expected to follow, so a missing one is "still running", not "never runs".
    /// </summary>
    public static readonly string[] SourceReportColumns =
        ["LIS Summary", "Line Level Master", "Claim Level Master"];

    /// <summary>
    /// Normalises a lab name for comparison: letters and digits only, upper-cased, with a
    /// trailing LRN/DTR dropped. Lets "Cove", "CoveLRN" and "Cove_LRN" all match one another.
    /// </summary>
    private static string LabToken(string? value)
    {
        var token = new string((value ?? string.Empty)
            .Where(char.IsLetterOrDigit)
            .Select(char.ToUpperInvariant)
            .ToArray());
        if (token.EndsWith("LRN", StringComparison.Ordinal)) token = token[..^3];
        if (token.EndsWith("DTR", StringComparison.Ordinal)) token = token[..^3];
        return token;
    }

    /// <summary>
    /// Whether this report is produced for the lab at all, ignoring run status. False means the
    /// cell is greyed with a dash — never a failure, and never "still running".
    /// </summary>
    public static bool IsAvailableForLab(ReportCatalogEntry entry, string? labKey, string? labDisplayName = null)
    {
        if (entry.AllowedLabs is not { Length: > 0 }) return true;

        var candidates = new[] { labKey, labDisplayName }
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(LabToken)
            .ToList();
        if (candidates.Count == 0) return false;

        return entry.AllowedLabs.Any(allowed =>
        {
            var token = LabToken(allowed);
            return candidates.Any(c => c == token);
        });
    }

    /// <summary>True for always-shown tiles (e.g. LIMS Master) that the tracker SP does not return as
    /// a column of their own — they still appear on every lab (their status can mirror another report).</summary>
    public static bool IsNavShortcut(string? trackerColumn)
        => trackerColumn is not null && AlwaysShow.Contains(trackerColumn);

    /// <summary>
    /// Tracker columns that are run artifacts, not reports, and must never appear on the board
    /// (as a tile or a matrix/worklist column) even though the SP still returns them.
    /// </summary>
    private static readonly HashSet<string> Hidden =
        new(StringComparer.OrdinalIgnoreCase) { "Error Log" };

    private static readonly Dictionary<string, ReportCatalogEntry> ByColumn =
        Entries.ToDictionary(e => e.TrackerColumn, StringComparer.OrdinalIgnoreCase);

    public static ReportCatalogEntry? Find(string trackerColumn)
        => ByColumn.TryGetValue(trackerColumn, out var entry) ? entry : null;

    /// <summary>
    /// A placeholder entry for a tracker column the catalog has never seen. Status-only: no route,
    /// no flag, raw column name as both the header and the tooltip.
    /// </summary>
    public static ReportCatalogEntry Unknown(string trackerColumn)
        => new(trackerColumn, trackerColumn, ShortenUnknown(trackerColumn), "bi-question-circle", GroupAnalytics, null, null, null);

    /// <summary>
    /// Orders the SP's columns for display: known columns in catalog order, then unknown ones in the
    /// order the SP returned them, so a newly added report type appears at the end rather than
    /// silently disappearing.
    /// </summary>
    public static List<ReportCatalogEntry> Order(IEnumerable<string> trackerColumns)
    {
        // Drop run-artifact columns (e.g. Error Log) entirely — never a tile or a matrix column.
        var visibleTracker = trackerColumns.Where(c => !Hidden.Contains(c)).ToList();
        var present = new HashSet<string>(visibleTracker, StringComparer.OrdinalIgnoreCase);
        // Known catalog entries that the tracker produced, PLUS always-on nav tiles (LIMS Master) that
        // are shortcuts to a page rather than a tracked report, so they show on every lab.
        var known = Entries.Where(e => present.Contains(e.TrackerColumn) || AlwaysShow.Contains(e.TrackerColumn)).ToList();
        var knownColumns = new HashSet<string>(known.Select(e => e.TrackerColumn), StringComparer.OrdinalIgnoreCase);
        var unknown = visibleTracker.Where(c => !knownColumns.Contains(c)).Select(Unknown);
        return [.. known, .. unknown];
    }

    /// <summary>Catalog entries shown on every lab regardless of whether the tracker returned them —
    /// navigation shortcuts (not tracked reports).</summary>
    private static readonly HashSet<string> AlwaysShow =
        new(StringComparer.OrdinalIgnoreCase) { "LIMS Master" };

    /// <summary>Initials-ish short header for an unknown column, so the matrix column stays narrow.</summary>
    private static string ShortenUnknown(string name)
    {
        var trimmed = (name ?? string.Empty).Trim();
        if (trimmed.Length <= 8) return trimmed;
        var words = trimmed.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Length > 1
            ? string.Concat(words.Take(3).Select(w => w[0])).ToUpperInvariant()
            : trimmed[..8];
    }
}
