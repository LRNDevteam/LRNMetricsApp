using LabMetricsDashboard.Models.Notes;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Data access for the generic Notes &amp; Insights feature. Every method
/// routes through a stored procedure (see SQL_Scripts/NotesInsights) — no
/// inline SQL. The caller supplies the lab-specific connection string, the
/// same way the Executive Summary repository does.
/// </summary>
public interface INotesRepository
{
    /// <summary>
    /// True only when the Insights schema (core table + procedures) is
    /// deployed in the given lab database. Used to enable/disable the
    /// Notes &amp; Insights feature per lab.
    /// </summary>
    Task<bool> IsFeatureAvailableAsync(string connectionString, CancellationToken ct = default);

    Task<int> EnsureReportAsync(string connectionString, string reportName, CancellationToken ct = default);

    Task<NotesLookups> GetLookupsAsync(string connectionString, CancellationToken ct = default);

    Task<IReadOnlyList<NoteInsight>> GetActiveAsync(
        string connectionString, int reportKeyId,
        DateTime? weekRangeStart = null, string? statusCode = null,
        string? riskCode = null, string? responsibility = null,
        string? searchText = null, CancellationToken ct = default);

    Task<IReadOnlyList<NoteInsight>> GetArchivedAsync(
        string connectionString, int reportKeyId,
        string? statusCode = null, string? riskCode = null,
        string? searchText = null, CancellationToken ct = default);

    Task<NoteInsight?> GetByIdAsync(string connectionString, int noteId, CancellationToken ct = default);

    Task<IReadOnlyList<NoteRevision>> GetRevisionHistoryAsync(
        string connectionString, int noteId, CancellationToken ct = default);

    Task<NotesArchiveSummary> GetArchiveSummaryAsync(
        string connectionString, int reportKeyId, CancellationToken ct = default);

    Task<NotesResult> InsertAsync(
        string connectionString, int reportKeyId, NoteSaveRequest req, string createdBy, CancellationToken ct = default);

    Task<NotesResult> UpdateAsync(
        string connectionString, NoteSaveRequest req, string editedBy, CancellationToken ct = default);

    Task<NotesResult> DeleteAsync(
        string connectionString, int noteId, string deletedBy, CancellationToken ct = default);

    Task<IReadOnlyList<NotesTemplateBundle>> GetTemplatesByReportAsync(
        string connectionString, int reportKeyId, CancellationToken ct = default);

    Task<NotesTemplateResult> UpsertTemplateAsync(
        string connectionString, int reportKeyId, NotesTemplateSaveRequest req, string editedBy, CancellationToken ct = default);

    Task<NotesTemplateResult> UpsertTemplateColumnAsync(
        string connectionString, NotesTemplateColumnSaveRequest req, CancellationToken ct = default);

    Task<NotesTemplateResult> DeleteTemplateColumnAsync(
        string connectionString, int columnId, CancellationToken ct = default);
}
