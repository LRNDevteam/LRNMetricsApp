using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Data.SqlClient;

namespace LRN.PayerPolicyMapper.Core.Data;

/// <summary>dbo.PayerMapperRun lifecycle + run detail reads (Sql/002_payer_mapper_service_audit.sql).</summary>
public sealed class SqlPayerMapperRunRepository : IPayerMapperRunRepository
{
    private readonly string _connectionString;

    public SqlPayerMapperRunRepository(string connectionString) => _connectionString = connectionString;

    public async Task<Guid> RequestRunAsync(string requestedBy, RunScope scope, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            INSERT INTO dbo.PayerMapperRun (TriggerType, RequestedBy, Status, Scope)
            OUTPUT INSERTED.RunId
            VALUES ('Manual', @RequestedBy, 'Requested', @Scope);
            """, conn);
        cmd.Parameters.AddWithValue("@RequestedBy", requestedBy);
        cmd.Parameters.AddWithValue("@Scope", scope.ToString());
        return (Guid)(await cmd.ExecuteScalarAsync(ct))!;
    }

    public async Task<Guid> CreateRunAsync(string triggerType, RunScope scope, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            INSERT INTO dbo.PayerMapperRun (TriggerType, Status, Scope, StartedOn)
            OUTPUT INSERTED.RunId
            VALUES (@TriggerType, 'InProgress', @Scope, SYSUTCDATETIME());
            """, conn);
        cmd.Parameters.AddWithValue("@TriggerType", triggerType);
        cmd.Parameters.AddWithValue("@Scope", scope.ToString());
        return (Guid)(await cmd.ExecuteScalarAsync(ct))!;
    }

    public async Task<RequestedRun?> ClaimRequestedRunAsync(CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            UPDATE TOP (1) r
            SET Status = 'InProgress', StartedOn = SYSUTCDATETIME()
            OUTPUT inserted.RunId, inserted.Scope
            FROM dbo.PayerMapperRun r WITH (ROWLOCK, READPAST, UPDLOCK)
            WHERE r.Status = 'Requested';
            """, conn);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        var scope = !r.IsDBNull(1) && Enum.TryParse<RunScope>(r.GetString(1), out var parsed)
            ? parsed
            : RunScope.AllUnmapped;
        return new RequestedRun(r.GetGuid(0), scope);
    }

    public async Task CompleteRunAsync(Guid runId, string status, int total, int autoMapped, int pendingReview, int noMatch, int failedRows, string? errorMessage, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            UPDATE dbo.PayerMapperRun
            SET Status = @Status, CompletedOn = SYSUTCDATETIME(),
                TotalProcessed = @Total, AutoMapped = @Auto, PendingReview = @Review,
                NoMatch = @NoMatch, FailedRows = @FailedRows, ErrorMessage = @Error
            WHERE RunId = @RunId;
            """, conn);
        cmd.Parameters.AddWithValue("@RunId", runId);
        cmd.Parameters.AddWithValue("@Status", status);
        cmd.Parameters.AddWithValue("@Total", total);
        cmd.Parameters.AddWithValue("@Auto", autoMapped);
        cmd.Parameters.AddWithValue("@Review", pendingReview);
        cmd.Parameters.AddWithValue("@NoMatch", noMatch);
        cmd.Parameters.AddWithValue("@FailedRows", failedRows);
        cmd.Parameters.AddWithValue("@Error", (object?)errorMessage ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<(IReadOnlyList<PayerMapperRunInfo> Runs, int TotalCount)> GetRunsAsync(int page, int pageSize, CancellationToken ct)
    {
        page = Math.Max(1, page);
        pageSize = Math.Clamp(pageSize <= 0 ? 25 : pageSize, 10, 200);
        var runs = new List<PayerMapperRunInfo>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        int total;
        await using (var count = new SqlCommand("SELECT COUNT(1) FROM dbo.PayerMapperRun;", conn))
            total = Convert.ToInt32(await count.ExecuteScalarAsync(ct) ?? 0);
        await using var cmd = new SqlCommand($"""
            SELECT RunId, TriggerType, RequestedBy, Status, CreatedOn, StartedOn, CompletedOn,
                   TotalProcessed, AutoMapped, PendingReview, NoMatch, FailedRows, ErrorMessage, Scope
            FROM dbo.PayerMapperRun
            ORDER BY CreatedOn DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """, conn);
        cmd.Parameters.AddWithValue("@Offset", (page - 1) * pageSize);
        cmd.Parameters.AddWithValue("@PageSize", pageSize);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) runs.Add(Map(r));
        return (runs, total);
    }

    public async Task<PayerMapperRunInfo?> GetRunAsync(Guid runId, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT RunId, TriggerType, RequestedBy, Status, CreatedOn, StartedOn, CompletedOn,
                   TotalProcessed, AutoMapped, PendingReview, NoMatch, FailedRows, ErrorMessage, Scope
            FROM dbo.PayerMapperRun WHERE RunId = @RunId;
            """, conn);
        cmd.Parameters.AddWithValue("@RunId", runId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? Map(r) : null;
    }

    public async Task<IReadOnlyList<PayerMapperRunDetailRow>> GetRunDetailsAsync(Guid runId, CancellationToken ct)
    {
        var rows = new List<PayerMapperRunDetailRow>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT a.AuditId, a.LabInsuranceMasterId, a.PayerNameRaw, a.CanonicalName,
                   a.Decision, a.ConfidenceScore, a.SelectedGlobalPayerId,
                   m.MappingStatus, a.ActionType, a.PerformedOn
            FROM dbo.PayerMatchAudit a
            LEFT JOIN dbo.LabInsuranceMaster m ON m.LabInsuranceMasterId = a.LabInsuranceMasterId
            WHERE a.RunId = @RunId
            ORDER BY a.AuditId;
            """, conn);
        cmd.Parameters.AddWithValue("@RunId", runId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new PayerMapperRunDetailRow(
                r.GetInt64(0),
                r.IsDBNull(1) ? null : r.GetInt32(1),
                r.IsDBNull(2) ? null : r.GetString(2),
                r.IsDBNull(3) ? null : r.GetString(3),
                r.IsDBNull(4) ? null : r.GetString(4),
                r.IsDBNull(5) ? null : r.GetDecimal(5),
                r.IsDBNull(6) ? null : r.GetInt32(6),
                r.IsDBNull(7) ? null : r.GetString(7),
                r.IsDBNull(8) ? null : r.GetString(8),
                r.GetDateTime(9)));
        return rows;
    }

    private static PayerMapperRunInfo Map(SqlDataReader r) => new()
    {
        RunId = r.GetGuid(0),
        TriggerType = r.GetString(1),
        RequestedBy = r.IsDBNull(2) ? null : r.GetString(2),
        Status = r.GetString(3),
        CreatedOn = r.GetDateTime(4),
        StartedOn = r.IsDBNull(5) ? null : r.GetDateTime(5),
        CompletedOn = r.IsDBNull(6) ? null : r.GetDateTime(6),
        TotalProcessed = r.GetInt32(7),
        AutoMapped = r.GetInt32(8),
        PendingReview = r.GetInt32(9),
        NoMatch = r.GetInt32(10),
        FailedRows = r.GetInt32(11),
        ErrorMessage = r.IsDBNull(12) ? null : r.GetString(12),
        Scope = r.IsDBNull(13) ? null : r.GetString(13)
    };

    private SqlConnection Open() => new(_connectionString);
}
