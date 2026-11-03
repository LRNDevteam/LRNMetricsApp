using Microsoft.AspNetCore.Mvc.Razor;

namespace LabMetricsDashboard.Services.ReportSnapshots;

/// <summary>
/// The snapshot viewer renders the report pages' own views (by full path), and those views name their
/// partials the short way ("_CsTabWcv", "_DenialInsightPanel", "ProductionReport"), which Razor looks up
/// under the current controller's folder. For ReportSnapshotViewer that folder is not theirs, so this adds
/// the report pages' folders to its search - and only to its search.
/// </summary>
public sealed class ReportSnapshotViewLocationExpander : IViewLocationExpander
{
    private const string Controller = "ReportSnapshotViewer";

    private static readonly string[] ReportFolders =
    [
        "/Views/ExecutiveSummary/{0}.cshtml",
        "/Views/LisSummary/{0}.cshtml",
        "/Views/Dashboard/{0}.cshtml",
        "/Views/CollectionSummary/{0}.cshtml",
        "/Views/DenialClaimReport/{0}.cshtml",
    ];

    public void PopulateValues(ViewLocationExpanderContext context) { }

    public IEnumerable<string> ExpandViewLocations(ViewLocationExpanderContext context, IEnumerable<string> viewLocations) =>
        string.Equals(context.ControllerName, Controller, StringComparison.OrdinalIgnoreCase)
            ? viewLocations.Concat(ReportFolders)
            : viewLocations;
}
