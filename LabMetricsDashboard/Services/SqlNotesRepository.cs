using LabMetricsDashboard.Models.Notes;
using Microsoft.Data.SqlClient;
using System.Data;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Stored-procedure-only implementation of <see cref="INotesRepository"/>.
/// Mirrors the connection convention used by the Executive Summary
/// repositories: the caller passes the resolved lab connection string.
/// All reads/writes invoke dbo.usp_Notes* procedures.
/// </summary>
public sealed class SqlNotesRepository : INotesRepository
{
    private const int CommandTimeoutSeconds = 120;
    private readonly ILogger<SqlNotesRepository> _logger;

    public SqlNotesRepository(ILogger<SqlNotesRepository> logger) => _logger = logger;

    // ── Feature availability ─────────────────────────────────────────────
    // Bootstrap metadata check (not a data transaction): the Notes feature is
    // only enabled on lab databases where the schema has been deployed. Any
    // error (including an unreachable DB) is treated as "not available".
    public async Task<bool> IsFeatureAvailableAsync(string connectionString, CancellationToken ct = default)
    {
        const string sql =
            "SELECT CASE WHEN OBJECT_ID('dbo.NotesInsight','U') IS NOT NULL " +
            "AND OBJECT_ID('dbo.usp_NotesInsight_GetActive','P') IS NOT NULL " +
            "AND OBJECT_ID('dbo.usp_NotesLookup_GetAll','P') IS NOT NULL THEN 1 ELSE 0 END;";
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 15 };
            var result = await cmd.ExecuteScalarAsync(ct);
            return result != null && result != DBNull.Value && Convert.ToInt32(result) == 1;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Notes: feature-availability check failed; treating as unavailable.");
            return false;
        }
    }

    // ── Report registry ──────────────────────────────────────────────────
    public async Task<int> EnsureReportAsync(string connectionString, string reportName, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesReport_Ensure", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@ReportName", reportName);
        var outId = new SqlParameter("@ReportKeyId", SqlDbType.Int) { Direction = ParameterDirection.Output };
        cmd.Parameters.Add(outId);
        await cmd.ExecuteNonQueryAsync(ct);
        return outId.Value == DBNull.Value ? 0 : Convert.ToInt32(outId.Value);
    }

    // ── Lookups ──────────────────────────────────────────────────────────
    public async Task<NotesLookups> GetLookupsAsync(string connectionString, CancellationToken ct = default)
    {
        var result = new NotesLookups();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand("dbo.usp_NotesLookup_GetAll", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds })
        await using (var rdr = await cmd.ExecuteReaderAsync(ct))
        {
            while (await rdr.ReadAsync(ct))
                result.Risks.Add(new NotesLookupItem { Id = GetInt(rdr, "RiskLevelId"), Code = GetString(rdr, "RiskCode"), Label = GetString(rdr, "RiskLabel"), ColorHex = GetString(rdr, "ColorHex") });

            if (await rdr.NextResultAsync(ct))
                while (await rdr.ReadAsync(ct))
                    result.Statuses.Add(new NotesLookupItem { Id = GetInt(rdr, "StatusId"), Code = GetString(rdr, "StatusCode"), Label = GetString(rdr, "StatusLabel") });
        }

        // Responsible Party master (drives the Add/Edit dropdown)
        await using (var cmd2 = new SqlCommand("dbo.usp_NotesResponsibleParty_GetAll", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds })
        await using (var rdr2 = await cmd2.ExecuteReaderAsync(ct))
        {
            while (await rdr2.ReadAsync(ct))
                result.ResponsibleParties.Add(GetString(rdr2, "PartyName"));
        }

        return result;
    }

    // ── Active log ───────────────────────────────────────────────────────
    public async Task<IReadOnlyList<NoteInsight>> GetActiveAsync(
        string connectionString, int reportKeyId,
        DateTime? weekRangeStart = null, string? statusCode = null,
        string? riskCode = null, string? responsibility = null,
        string? searchText = null, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_GetActive", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@ReportKeyId", reportKeyId);
        cmd.Parameters.AddWithValue("@WeekRangeStart", (object?)weekRangeStart ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StatusCode", (object?)NullIfEmpty(statusCode) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RiskCode", (object?)NullIfEmpty(riskCode) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Responsibility", (object?)NullIfEmpty(responsibility) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@SearchText", (object?)NullIfEmpty(searchText) ?? DBNull.Value);

        var rows = new List<NoteInsight>();
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct)) rows.Add(MapListRow(rdr, includeArchive: false));
        return rows;
    }

    // ── Archive ──────────────────────────────────────────────────────────
    public async Task<IReadOnlyList<NoteInsight>> GetArchivedAsync(
        string connectionString, int reportKeyId,
        string? statusCode = null, string? riskCode = null,
        string? searchText = null, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_GetArchived", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@ReportKeyId", reportKeyId);
        cmd.Parameters.AddWithValue("@StatusCode", (object?)NullIfEmpty(statusCode) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RiskCode", (object?)NullIfEmpty(riskCode) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@SearchText", (object?)NullIfEmpty(searchText) ?? DBNull.Value);

        var rows = new List<NoteInsight>();
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct)) rows.Add(MapListRow(rdr, includeArchive: true));
        return rows;
    }

    // ── Detail ───────────────────────────────────────────────────────────
    public async Task<NoteInsight?> GetByIdAsync(string connectionString, int noteId, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_GetById", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@NoteId", noteId);
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        if (!await rdr.ReadAsync(ct)) return null;

        var n = MapListRow(rdr, includeArchive: true);
        n.ReportKeyId  = GetInt(rdr, "ReportKeyId");
        n.DataLink     = GetString(rdr, "DataLink");
        n.IsEditable   = GetInt(rdr, "IsEditable") == 1;
        return n;
    }

    // ── Revision history ─────────────────────────────────────────────────
    public async Task<IReadOnlyList<NoteRevision>> GetRevisionHistoryAsync(string connectionString, int noteId, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_GetRevisionHistory", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@NoteId", noteId);
        var rows = new List<NoteRevision>();
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct))
            rows.Add(new NoteRevision
            {
                RevisionId = GetInt(rdr, "RevisionId"),
                NoteId = GetInt(rdr, "NoteId"),
                VersionNumber = GetInt(rdr, "VersionNumber"),
                EventType = GetString(rdr, "EventType"),
                SourceAction = GetString(rdr, "SourceAction"),
                RevisionSummary = GetString(rdr, "RevisionSummary"),
                EventUser = GetString(rdr, "EventUser"),
                EventDateTime = GetDate(rdr, "EventDateTime"),
            });
        return rows;
    }

    // ── Archive summary cards ────────────────────────────────────────────
    public async Task<NotesArchiveSummary> GetArchiveSummaryAsync(string connectionString, int reportKeyId, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_GetArchiveSummary", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@ReportKeyId", reportKeyId);
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        var s = new NotesArchiveSummary();
        if (await rdr.ReadAsync(ct))
        {
            s.TotalArchived = GetInt(rdr, "TotalArchived");
            s.RedRiskArchived = GetInt(rdr, "RedRiskArchived");
            s.ClosedThisMonth = GetInt(rdr, "ClosedThisMonth");
            s.LastArchivedDate = GetDate(rdr, "LastArchivedDate");
        }
        return s;
    }

    // ── Insert ───────────────────────────────────────────────────────────
    public async Task<NotesResult> InsertAsync(string connectionString, int reportKeyId, NoteSaveRequest req, string createdBy, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_Insert", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@ReportKeyId", reportKeyId);
        cmd.Parameters.AddWithValue("@ReportRunId", (object?)NullIfEmpty(req.ReportRunId) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@WeekRangeStart", (object?)req.WeekRangeStart ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@WeekRangeEnd", (object?)req.WeekRangeEnd ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@WeekRangeText", (object?)NullIfEmpty(req.WeekRangeText) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RiskCode", req.RiskCode);
        cmd.Parameters.AddWithValue("@ResponsibleParty", (object?)NullIfEmpty(req.ResponsibleParty) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Insights", (object?)req.Insights ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@NoOfSamples", (object?)req.NoOfSamples ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@DataLink", (object?)NullIfEmpty(req.DataLink) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ActionSolution", (object?)req.ActionSolution ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FeedbackResponse", (object?)req.FeedbackResponse ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Responsibility", (object?)NullIfEmpty(req.Responsibility) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@DiscussionDate", (object?)req.DiscussionDate ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ETA", (object?)req.ETA ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ClosedDate", (object?)req.ClosedDate ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StatusCode", req.StatusCode);
        cmd.Parameters.AddWithValue("@SourceAction", "Add Row");
        cmd.Parameters.AddWithValue("@CreatedBy", createdBy);
        var outId = new SqlParameter("@NewNoteId", SqlDbType.Int) { Direction = ParameterDirection.Output };
        cmd.Parameters.Add(outId);

        await cmd.ExecuteNonQueryAsync(ct);
        var newId = outId.Value == DBNull.Value ? 0 : Convert.ToInt32(outId.Value);
        return new NotesResult { Success = newId > 0, NoteId = newId, Message = newId > 0 ? "Note created." : "Insert failed." };
    }

    // ── Update ───────────────────────────────────────────────────────────
    public async Task<NotesResult> UpdateAsync(string connectionString, NoteSaveRequest req, string editedBy, CancellationToken ct = default)
    {
        if (req.NoteId is null or <= 0) return new NotesResult { Success = false, Message = "NoteId is required for update." };

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_Update", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@NoteId", req.NoteId!.Value);
        cmd.Parameters.AddWithValue("@RiskCode", req.RiskCode);
        cmd.Parameters.AddWithValue("@ResponsibleParty", (object?)NullIfEmpty(req.ResponsibleParty) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Insights", (object?)req.Insights ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@NoOfSamples", (object?)req.NoOfSamples ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@DataLink", (object?)NullIfEmpty(req.DataLink) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ActionSolution", (object?)req.ActionSolution ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FeedbackResponse", (object?)req.FeedbackResponse ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Responsibility", (object?)NullIfEmpty(req.Responsibility) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@DiscussionDate", (object?)req.DiscussionDate ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ETA", (object?)req.ETA ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ClosedDate", (object?)req.ClosedDate ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StatusCode", req.StatusCode);
        cmd.Parameters.AddWithValue("@SourceAction", "Save Changes");
        cmd.Parameters.AddWithValue("@LastEditedBy", editedBy);

        await cmd.ExecuteNonQueryAsync(ct);
        return new NotesResult { Success = true, NoteId = req.NoteId!.Value, Message = "Changes saved." };
    }

    // ── Delete (soft) ────────────────────────────────────────────────────
    public async Task<NotesResult> DeleteAsync(string connectionString, int noteId, string deletedBy, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_NotesInsight_Delete", conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };
        cmd.Parameters.AddWithValue("@NoteId", noteId);
        cmd.Parameters.AddWithValue("@DeletedBy", deletedBy);
        await cmd.ExecuteNonQueryAsync(ct);
        return new NotesResult { Success = true, NoteId = noteId, Message = "Note deleted." };
    }

    // ── Mapping helpers ──────────────────────────────────────────────────
    private static NoteInsight MapListRow(SqlDataReader r, bool includeArchive)
    {
        var n = new NoteInsight
        {
            NoteId = GetInt(r, "NoteId"),
            EntryNo = GetNullableInt(r, "EntryNo"),
            ReportName = GetString(r, "ReportName"),
            ReportRunId = GetString(r, "ReportRunId"),
            WeekRangeText = GetString(r, "WeekRangeText"),
            WeekRangeStart = GetDate(r, "WeekRangeStart"),
            WeekRangeEnd = GetDate(r, "WeekRangeEnd"),
            RiskCode = GetString(r, "RiskCode"),
            RiskLabel = GetString(r, "RiskLabel"),
            ColorHex = GetString(r, "ColorHex"),
            ResponsibleParty = GetString(r, "ResponsibleParty"),
            Insights = GetString(r, "Insights"),
            NoOfSamples = GetNullableInt(r, "NoOfSamples"),
            ActionSolution = GetString(r, "ActionSolution"),
            FeedbackResponse = GetString(r, "FeedbackResponse"),
            Responsibility = GetString(r, "Responsibility"),
            DiscussionDate = GetDate(r, "DiscussionDate"),
            ETA = GetDate(r, "ETA"),
            ClosedDate = GetDate(r, "ClosedDate"),
            StatusCode = GetString(r, "StatusCode"),
            StatusLabel = GetString(r, "StatusLabel"),
            ArchiveStatus = GetString(r, "ArchiveStatus"),
            VersionNumber = GetInt(r, "VersionNumber"),
            CreatedBy = GetString(r, "CreatedBy"),
            CreatedDateTime = GetDate(r, "CreatedDateTime"),
            LastEditedBy = GetString(r, "LastEditedBy"),
            LastEditedDateTime = GetDate(r, "LastEditedDateTime"),
        };
        if (HasColumn(r, "IsOverdueETA")) n.IsOverdueETA = GetInt(r, "IsOverdueETA") == 1;
        if (includeArchive && HasColumn(r, "ArchivedDate")) n.ArchivedDate = GetDate(r, "ArchivedDate");
        return n;
    }

    private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    private static bool HasColumn(IDataRecord r, string n)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), n, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
    private static string GetString(IDataRecord r, string n) => r[n] == DBNull.Value ? string.Empty : Convert.ToString(r[n]) ?? string.Empty;
    private static int GetInt(IDataRecord r, string n) => r[n] == DBNull.Value ? 0 : Convert.ToInt32(r[n]);
    private static int? GetNullableInt(IDataRecord r, string n) => r[n] == DBNull.Value ? null : Convert.ToInt32(r[n]);
    private static DateTime? GetDate(IDataRecord r, string n) => r[n] == DBNull.Value ? null : Convert.ToDateTime(r[n]);
}
