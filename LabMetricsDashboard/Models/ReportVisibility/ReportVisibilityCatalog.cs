namespace LabMetricsDashboard.Models.ReportVisibility;

/// <summary>
/// Per-role visibility for the Standard Reports pages: which tabs a role sees, and whether it can
/// see / edit the page's Key Insights. Edited on Admin &gt; Report Visibility.
/// </summary>
/// <remarks>
/// <para>Settings are stored as rows of <c>dbo.RoleFeatureAccess</c> (the same table the Role Menu
/// Mapping "Other screen access" toggles use), so no schema change is needed. The keys are:</para>
/// <list type="bullet">
/// <item><c>Report.{Page}.Tab.{Tab}.View</c> - 1 visible, 0 hidden</item>
/// <item><c>Report.{Page}.KeyInsights.View</c> - 1 visible, 0 hidden (everything below needs it)</item>
/// <item><c>Report.{Page}.KeyInsights.{Action}</c> - one row per <see cref="KeyInsightAction"/>
/// (Add, Edit, Delete, Import, Template, CopyWeek): 1 allowed, 0 denied. Each action is independent,
/// so a role can, for example, add insights but not import them.</item>
/// </list>
/// <para>No row means "Default": the page behaves exactly as it did before this feature existed.
/// Across a user's roles any role that enables a key wins (LRN.ReportsApi resolves this), the same
/// union rule menu access uses. Full admins are never restricted.</para>
/// <para>LRN.ReportsApi validates the key <i>shape</i> (ReportVisibilityFeatures), not this list, so
/// adding a tab here needs no API deployment.</para>
/// </remarks>
public static class ReportVisibilityCatalog
{
    public const string Prefix = "Report.";

    /// <summary>ViewData key a report view sets so the <c>lmd-report-tab</c> tag helper knows its page.</summary>
    public const string ViewDataKey = "ReportVisibilityPage";

    /// <summary>Pseudo tab key: the element is shown only when the page's Key Insights are visible.</summary>
    public const string KeyInsightsTab = "key-insights";

    public const string LisSummary = "LisSummary";
    public const string Production = "Production";
    public const string CollectionSummary = "CollectionSummary";
    public const string ExecutiveSummary = "ExecutiveSummary";
    public const string DenialSummary = "DenialSummary";

    /// <summary>The shared Key Insights panel (LIS / Production / Collection): every action it has.</summary>
    private static readonly IReadOnlyList<KeyInsightActionDefinition> PanelActions =
    [
        new(KeyInsightAction.Add, "Add insight", "The \"Add Insight\" button."),
        new(KeyInsightAction.Edit, "Edit insights", "Change an existing insight (Save Changes in the note detail)."),
        new(KeyInsightAction.Delete, "Delete insights", "The Delete button on each insight row."),
        new(KeyInsightAction.Import, "Import", "The \"Import\" button and import window (upload a filled-in workbook)."),
        new(KeyInsightAction.Template, "Download template", "The \"Template\" button and the Download Template link in the import window."),
    ];

    public static IReadOnlyList<ReportPageDefinition> Pages { get; } =
    [
        new(LisSummary, "LIS Summary", "LIS Report", PanelActions,
        [
            new("summary", "LIMS Summary"),
            new("line", "LIMS Line Data"),
        ]),
        new(Production, "Production Report / Production Summary Report", "Production Report", PanelActions,
        [
            new("monthly", "Monthly Claim Volume"),
            new("weekly", "Weekly Claim Volume"),
            new("coding", "Coding"),
            new("payer-breakdown", "Payer Breakdown"),
            new("payer-panel", "Payer X Panel"),
            new("unbilled-aging", "Unbilled X Aging"),
            new("cpt-breakdown", "CPT Breakdown"),
            new("panel-breakdown", "Panel Breakdown"),
            new("highest-payer", "Highest Payer Breakdown", "NorthWest only"),
            new("top10-payer", "Top 10 Payer", "NorthWest only"),
        ]),
        new(CollectionSummary, "Collection Summary", "Collection Report", PanelActions,
        [
            new("mcv", "Monthly Claim Volume"),
            new("wcv", "Weekly Claim Volume"),
            new("top5grid", "Top 5 Insurances", "Executive Summary highlight frame only"),
            new("avgpaydos", "Avg Payments - DOS / Panel Averages - by DOS", "Some labs only"),
            new("avgpay", "Avg Payments / Panel Averages - by Check Date"),
            new("avgpay3", "Avg Payments Last 3 Months", "Some labs only"),
            new("panelavg", "Panel Average", "Some labs only"),
            new("aging", "Insurance vs Aging / No Response vs Aging"),
            new("panelpay", "Panel vs Payment"),
            new("inspctpay", "Insurance vs Payment %"),
            new("insvspay", "Insurance vs Payment / Payer vs Payment", "Some labs only"),
            new("cptpctpay", "CPT vs Payment %"),
            new("statussummary", "Status Summary", "Some labs only"),
            new("whpanel", "Women's Health Panel", "NorthWest only"),
            new("genidavg", "Genetics vs ID Avg", "Some labs only"),
            new("provider", "Provider", "Some labs only"),
        ]),
        new(ExecutiveSummary, "Executive Summary", "Notes & Insights",
        [
            new(KeyInsightAction.Add, "Add insight row", "The \"Add Insight Row\" button (Save Changes saves it)."),
            new(KeyInsightAction.Edit, "Edit insights", "Change existing rows in the grid and Save Changes."),
            new(KeyInsightAction.Delete, "Delete insights", "The delete (bin) button on each row."),
            new(KeyInsightAction.Import, "Import Excel", "The \"Import Excel\" toolbar button."),
            new(KeyInsightAction.Template, "Template Library", "The \"Template Library\" toolbar button."),
        ],
        [
            new("prod", "2. Production Highlights", "Labs with highlight tabs"),
            new("coll", "3. Collection Highlights", "Labs with highlight tabs"),
            new("lims", "4. LIMS Highlights", "Labs with highlight tabs"),
            new("denial", "5. Denial Highlights", "Labs with highlight tabs"),
        ]),
        new(DenialSummary, "Denial Summary", "Denial Insight tab",
        [
            new(KeyInsightAction.Import, "Import denial insights", "The \"Import\" button on Current Week and Previous Week (upload the Denial Insight workbook)."),
            new(KeyInsightAction.Edit, "Edit rows", "The pencil (Edit) and Save buttons on each Current Week row."),
            new(KeyInsightAction.Delete, "Delete rows", "The bin (Delete) button on each Current Week row."),
            new(KeyInsightAction.CopyWeek, "Copy to Previous Week", "The \"Copy to Previous Week\" button."),
            new(KeyInsightAction.Template, "Export / template", "The \"Export\" button (downloads the tab as the import template)."),
        ],
        [
            new("monthly", "Monthly Summary"),
            new("weekly", "Weekly Summary"),
            new("list", "Denial List", "Some labs only"),
            new("plantype", "Plan Type", "Some labs only"),
            new("payor", "Panel vs Payer", "Some labs only"),
            new("facility", "Facility wise Denial", "Some labs only"),
            new("facilitypct", "Denial vs Facility %", "Some labs only"),
            new("claims", "Claim Level"),
        ]),
    ];

    public static ReportPageDefinition? FindPage(string? pageKey) =>
        Pages.FirstOrDefault(p => string.Equals(p.Key, pageKey, StringComparison.OrdinalIgnoreCase));

    /// <summary>The page whose Key Insights the Notes API serves under a Notes report name.</summary>
    public static string? PageForNotesReport(string? reportName) => reportName?.Trim() switch
    {
        { } r when r.Equals("Executive Summary", StringComparison.OrdinalIgnoreCase) => ExecutiveSummary,
        { } r when r.Equals("Production Report", StringComparison.OrdinalIgnoreCase) => Production,
        { } r when r.Equals("LIS Report", StringComparison.OrdinalIgnoreCase) => LisSummary,
        { } r when r.Equals("Collection Report", StringComparison.OrdinalIgnoreCase) => CollectionSummary,
        _ => null
    };

    public static string TabViewKey(string page, string tab) => $"{Prefix}{page}.Tab.{tab}.View";
    public static string KeyInsightsViewKey(string page) => $"{Prefix}{page}.KeyInsights.View";
    public static string KeyInsightsKey(string page, KeyInsightAction action) => $"{Prefix}{page}.KeyInsights.{action}";
}

/// <summary>
/// What a role may do with a page's Key Insights beyond seeing them. Each is a separate
/// Allow / Deny / Default setting; all of them need Key Insights to be visible.
/// </summary>
public enum KeyInsightAction
{
    Add,
    Edit,
    Delete,
    Import,
    Template,
    /// <summary>Denial Summary only: Copy to Previous Week.</summary>
    CopyWeek,
}

public sealed record KeyInsightActionDefinition(KeyInsightAction Action, string DisplayName, string Description);

/// <param name="KeyInsightActions">The actions this page's Key Insights actually has (Denial has no Add, for example).</param>
public sealed record ReportPageDefinition(string Key, string DisplayName, string KeyInsightsLabel,
    IReadOnlyList<KeyInsightActionDefinition> KeyInsightActions, IReadOnlyList<ReportTabDefinition> Tabs);

/// <param name="Note">When the tab only appears for some labs, so an admin is not surprised it is missing.</param>
public sealed record ReportTabDefinition(string Key, string DisplayName, string? Note = null);
