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

    /// <summary>Display order for the board, which is deliberately not the SP's column order.</summary>
    public static readonly IReadOnlyList<ReportCatalogEntry> Entries =
    [
        new("Line Level Master",       "Line Level Master",       "Line",     "bi-list-ul",              GroupSource,    "Dashboard",              "LineLevel",               "LineClaimEnable"),
        new("Claim Level Master",      "Claim Level Master",      "Claim",    "bi-file-text",            GroupSource,    "Dashboard",              "ClaimLevel",              "LineClaimEnable"),

        new("LIS Summary",             "LIS Summary",             "LIS",      "bi-clipboard2-pulse",     GroupSummary,   "LisSummary",             "Index",                   null),
        new("Production Summary",      "Production Summary",      "Prod",     "bi-bar-chart-steps",      GroupSummary,   "Dashboard",              "ProductionSummaryReport", "EnableProductionSummaryReport"),
        new("Collection Summary",      "Collection Summary",      "Collect",  "bi-cash-stack",           GroupSummary,   "CollectionSummary",      "Index",                   "EnableCollectionReport"),
        new("Executive Summary",       "Executive Summary",       "Exec",     "bi-table",                GroupSummary,   "ExecutiveSummary",       "Index",                   null),
        new("Clinic Summary",          "Clinic Summary",          "Clinic",   "bi-hospital",             GroupSummary,   "Dashboard",              "ClinicSummary",           "EnableClinicsummary"),
        new("Sales Rep Summary",       "Sales Rep Summary",       "Sales",    "bi-people-fill",          GroupSummary,   "Dashboard",              "SalesRepSummary",         "EnableSalesRepsummary"),
        new("Denial Report",           "Denial Report",           "Denial",   "bi-exclamation-triangle", GroupSummary,   "DenialDashboard",        "Index",                   null),

        new("Coding Validation",       "Coding Validation",       "Coding",   "bi-pencil-square",        GroupAnalytics, "Coding",                 "Summary",                 "EnableCoding"),
        new("Payer Policy Validation", "Payer Policy Validation", "Policy",   "bi-shield-check",         GroupAnalytics, "PayerPolicyValidation",  "Index",                   "EnablePrediction"),
        new("Prediction Analysis",     "Prediction Analysis",     "Predict",  "bi-activity",             GroupAnalytics, "Prediction",             "Index",                   "EnablePrediction"),
        new("Forecasting",             "Forecasting",             "Forecast", "bi-calendar3",            GroupAnalytics, "Prediction",             "ForecastingSummary",      "EnableForcast"),
        // The tracker's own "Error Log" column: a run-level artifact, so it points at the board's
        // error page rather than a report page. No feature flag - every lab has a run log.
        new("Error Log",               "Error Log",               "Errors",   "bi-journal-text",         GroupAnalytics, "ReportBoard",            "RunErrors",               null)
    ];

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
        var present = new HashSet<string>(trackerColumns, StringComparer.OrdinalIgnoreCase);
        var known = Entries.Where(e => present.Contains(e.TrackerColumn)).ToList();
        var knownColumns = new HashSet<string>(known.Select(e => e.TrackerColumn), StringComparer.OrdinalIgnoreCase);
        var unknown = trackerColumns.Where(c => !knownColumns.Contains(c)).Select(Unknown);
        return [.. known, .. unknown];
    }

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
