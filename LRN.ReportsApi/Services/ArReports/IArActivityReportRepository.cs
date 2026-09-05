using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArReports;

/// <summary>
/// RPT-01 - AR Follow-up Activity Detail, and the catalog/saved-view plumbing the AR report suite
/// shares. Kept out of <see cref="IDenialWorkflowRepository"/>: the workflow repository answers
/// "what is the current state of this claim", these methods answer "what work was performed", and
/// the two read different grains for different audiences (spec section 2.1, FR-008).
/// </summary>
public interface IArActivityReportRepository
{
    /// <summary>
    /// Applies the additive schema RPT-01 needs (see Sql/ArReports/RPT01_ActivityDetail_Setup.sql)
    /// once per lab per process lifetime. Every statement is metadata-only or a small new table, so
    /// this is safe to run on first request; the checked-in script exists so a DBA can pre-apply it.
    /// </summary>
    Task EnsureReportObjectsAsync(int labId, CancellationToken ct);

    Task<IReadOnlyList<ArReportCatalogItem>> GetCatalogAsync(int labId, CancellationToken ct);

    Task<ArActivityFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct);

    /// <summary>Metadata + summary measures + the requested detail page + the requested grouping.</summary>
    Task<ArActivityReportResult> GetActivityDetailAsync(ArActivityReportFilter filter, CancellationToken ct);

    /// <summary>The complete activity timeline for one claim - the end of the spec's drill-down path.</summary>
    Task<IReadOnlyList<ArActivityTimelineRow>> GetClaimTimelineAsync(ArActivityReportFilter filter, string claimId, CancellationToken ct);

    Task<IReadOnlyList<ArReportSavedView>> GetSavedViewsAsync(string reportCode, int labId, string ownerUserName, CancellationToken ct);
    Task<ArReportSavedView> SaveViewAsync(string reportCode, string ownerUserName, ArReportSavedViewRequest request, CancellationToken ct);
    Task<int> DeleteSavedViewAsync(string reportCode, int labId, string ownerUserName, int savedViewId, CancellationToken ct);

    /// <summary>FR-001 / NFR-003: records the run that produced a screen or an export.</summary>
    Task LogRunAsync(ArReportRunMetadata metadata, string outputType, int rowCount, int durationMs, CancellationToken ct);
}
