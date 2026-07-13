using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Data.SqlClient;

namespace LRN.PayerPolicyMapper.Core.Data;

/// <summary>Step 9 persistence + worker claim against dbo.LabInsuranceMaster / dbo.PendingMatchCandidates.</summary>
public sealed class SqlLabInsuranceRepository : ILabInsuranceRepository
{
    private readonly string _connectionString;

    public SqlLabInsuranceRepository(string connectionString) => _connectionString = connectionString;

    public async Task<LabInsuranceRow?> GetRowAsync(int labInsuranceMasterId, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT LabInsuranceMasterId, PayerNameRaw, PlanType, LabState, LabStateCode, Remarks, GlobalPayerID
            FROM dbo.LabInsuranceMaster WHERE LabInsuranceMasterId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", labInsuranceMasterId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? Map(r) : null;
    }

    // Which rows a scope covers (shared by claim + reset). UnmappedPending excludes
    // 'No Match Found' so scheduled hourly runs don't re-grind them; AllUnmapped includes them
    // (rules-change / nightly rescue); All covers every record regardless of mapping.
    private static string ScopeWhere(RunScope scope) => scope switch
    {
        RunScope.UnmappedPending => """
            lab.GlobalPayerID IS NULL
            AND (lab.MappingStatus IS NULL OR LTRIM(RTRIM(lab.MappingStatus)) IN ('', 'Unmapped', 'Unmapped - Pending Review'))
            """,
        RunScope.AllUnmapped => "lab.GlobalPayerID IS NULL",
        _ => "1 = 1"
    };

    public async Task<IReadOnlyList<LabInsuranceRow>> ClaimUnmappedBatchAsync(int batchSize, RunScope scope, CancellationToken ct)
    {
        var rows = new List<LabInsuranceRow>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        // READPAST + UPDLOCK: multiple worker instances skip each other's locked rows, so a
        // LabInsuranceMasterId is never claimed twice. Stamping LastEvaluatedOn IS the claim.
        await using var cmd = new SqlCommand($"""
            UPDATE TOP (@BatchSize) lab
            SET LastEvaluatedOn = SYSUTCDATETIME()
            OUTPUT inserted.LabInsuranceMasterId, inserted.PayerNameRaw, inserted.PlanType,
                   inserted.LabState, inserted.LabStateCode, inserted.Remarks, inserted.GlobalPayerID
            FROM dbo.LabInsuranceMaster lab WITH (ROWLOCK, READPAST, UPDLOCK)
            WHERE {ScopeWhere(scope)}
              AND lab.LastEvaluatedOn IS NULL
              AND NULLIF(LTRIM(RTRIM(lab.PayerNameRaw)), '') IS NOT NULL;
            """, conn);
        cmd.Parameters.AddWithValue("@BatchSize", batchSize);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) rows.Add(Map(r));
        return rows;
    }

    public async Task<int> ResetEvaluationsAsync(RunScope scope, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(
            $"UPDATE lab SET LastEvaluatedOn = NULL FROM dbo.LabInsuranceMaster lab WHERE {ScopeWhere(scope)};", conn)
        { CommandTimeout = 300 };
        return await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task StampEvaluatedAsync(int labInsuranceMasterId, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(
            "UPDATE dbo.LabInsuranceMaster SET LastEvaluatedOn = SYSUTCDATETIME() WHERE LabInsuranceMasterId = @Id;", conn);
        cmd.Parameters.AddWithValue("@Id", labInsuranceMasterId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task ApplyAutoMapAsync(int labInsuranceMasterId, int globalPayerId, string payerNameNormalized, string mappedBy, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            UPDATE dbo.LabInsuranceMaster
            SET GlobalPayerID = @Gid, PayerNameNormalized = @Normalized, MappingStatus = 'Mapped',
                MappedBy = @MappedBy, ModifiedBy = @MappedBy, ModifiedOn = SYSUTCDATETIME(),
                LastEvaluatedOn = SYSUTCDATETIME()
            WHERE LabInsuranceMasterId = @Id;
            DELETE FROM dbo.PendingMatchCandidates WHERE LabInsuranceMasterId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", labInsuranceMasterId);
        cmd.Parameters.AddWithValue("@Gid", globalPayerId);
        cmd.Parameters.AddWithValue("@Normalized", payerNameNormalized);
        cmd.Parameters.AddWithValue("@MappedBy", mappedBy);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task ApplyManualReviewAsync(int labInsuranceMasterId, string payerNameNormalized, IReadOnlyList<MatchCandidate> candidates, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);
        try
        {
            await using (var upd = new SqlCommand("""
                UPDATE dbo.LabInsuranceMaster
                SET PayerNameNormalized = @Normalized, MappingStatus = 'Unmapped - Pending Review',
                    LastEvaluatedOn = SYSUTCDATETIME()
                WHERE LabInsuranceMasterId = @Id;
                DELETE FROM dbo.PendingMatchCandidates WHERE LabInsuranceMasterId = @Id;
                """, conn, tx))
            {
                upd.Parameters.AddWithValue("@Id", labInsuranceMasterId);
                upd.Parameters.AddWithValue("@Normalized", payerNameNormalized);
                await upd.ExecuteNonQueryAsync(ct);
            }

            foreach (var c in candidates)
            {
                await using var ins = new SqlCommand("""
                    INSERT INTO dbo.PendingMatchCandidates
                        (LabInsuranceMasterId, PPInsuranceMasterId, GlobalPayerId, Score, [Rank], BaseNameScore, StateAdjustment, ProgramAdjustment)
                    VALUES (@LabId, @PpId, @Gid, @Score, @Rank, @Base, @State, @Program);
                    """, conn, tx);
                ins.Parameters.AddWithValue("@LabId", labInsuranceMasterId);
                ins.Parameters.AddWithValue("@PpId", c.Record.PPInsuranceMasterId);
                ins.Parameters.AddWithValue("@Gid", (object?)c.Record.GlobalPayerId ?? DBNull.Value);
                ins.Parameters.AddWithValue("@Score", c.Score);
                ins.Parameters.AddWithValue("@Rank", (byte)c.Rank);
                ins.Parameters.AddWithValue("@Base", c.BaseNameScore);
                ins.Parameters.AddWithValue("@State", c.StateAdjustment);
                ins.Parameters.AddWithValue("@Program", c.ProgramAdjustment);
                await ins.ExecuteNonQueryAsync(ct);
            }
            await tx.CommitAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    public async Task ApplyNoMatchAsync(int labInsuranceMasterId, string payerNameNormalized, string remarksNote, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            UPDATE dbo.LabInsuranceMaster
            SET PayerNameNormalized = @Normalized, MappingStatus = 'No Match Found',
                Remarks = CASE
                    WHEN Remarks IS NULL OR LTRIM(RTRIM(Remarks)) = '' THEN @Note
                    WHEN Remarks LIKE '%' + @Note + '%' THEN Remarks
                    ELSE CONCAT(Remarks, '; ', @Note) END,
                LastEvaluatedOn = SYSUTCDATETIME()
            WHERE LabInsuranceMasterId = @Id;
            DELETE FROM dbo.PendingMatchCandidates WHERE LabInsuranceMasterId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", labInsuranceMasterId);
        cmd.Parameters.AddWithValue("@Normalized", payerNameNormalized);
        cmd.Parameters.AddWithValue("@Note", remarksNote);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<bool> ApplyUserMappingAsync(int labInsuranceMasterId, PayerPolicyRecord policyRecord, string mappedBy, string userName, CancellationToken ct)
    {
        if (policyRecord.GlobalPayerId is null)
            throw new ArgumentException("Policy record has no parseable Global Payer ID and cannot be mapped.", nameof(policyRecord));

        await using var conn = Open();
        await conn.OpenAsync(ct);
        // The matched policy record is the reference source: carry its columns over to the Lab
        // record wherever the policy side has a value (COALESCE keeps existing Lab values where
        // the policy side is blank). Payer Common Code carries the policy Global Payer Code per
        // requirements spec 4.4.
        await using var cmd = new SqlCommand("""
            UPDATE dbo.LabInsuranceMaster
            SET GlobalPayerID = @Gid, MappingStatus = 'Mapped', MappedBy = @MappedBy,
                PayerNameNormalized = COALESCE(@PayerNameNormalized, PayerNameNormalized),
                PayerCommonCode = COALESCE(@GlobalPayerCode, PayerCommonCode),
                PayerGroupCode = COALESCE(@PayerGroupCode, PayerGroupCode),
                PlanType = COALESCE(@PlanType, PlanType),
                PayerState = COALESCE(@PayerState, PayerState),
                BenefitAdminCode = COALESCE(@BenefitAdminCode, BenefitAdminCode),
                BenefitAdministrator = COALESCE(@BenefitAdministrator, BenefitAdministrator),
                ModifiedBy = @UserName, ModifiedOn = SYSUTCDATETIME(), LastEvaluatedOn = SYSUTCDATETIME()
            WHERE LabInsuranceMasterId = @Id;
            DELETE FROM dbo.PendingMatchCandidates WHERE LabInsuranceMasterId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", labInsuranceMasterId);
        cmd.Parameters.AddWithValue("@Gid", policyRecord.GlobalPayerId.Value);
        cmd.Parameters.AddWithValue("@MappedBy", mappedBy);
        cmd.Parameters.AddWithValue("@UserName", userName);
        cmd.Parameters.AddWithValue("@PayerNameNormalized", (object?)policyRecord.PayerNameNormalized ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@GlobalPayerCode", (object?)policyRecord.GlobalPayerCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PayerGroupCode", (object?)policyRecord.PayerGroupCode?.ToString() ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PlanType", (object?)policyRecord.PlanType ?? DBNull.Value);
        // Prefer the resolved 2-letter code (the Lab column is a state-code dropdown), else the raw value.
        cmd.Parameters.AddWithValue("@PayerState", (object?)(policyRecord.StateCode ?? policyRecord.PayerState) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@BenefitAdminCode", (object?)policyRecord.BenefitAdminCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@BenefitAdministrator", (object?)policyRecord.BenefitAdministrator ?? DBNull.Value);
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public async Task<IReadOnlyList<PendingCandidateRow>> GetPendingCandidatesAsync(int labInsuranceMasterId, CancellationToken ct)
    {
        var rows = new List<PendingCandidateRow>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT LabInsuranceMasterId, PPInsuranceMasterId, GlobalPayerId, Score, [Rank], BaseNameScore, StateAdjustment, ProgramAdjustment
            FROM dbo.PendingMatchCandidates
            WHERE LabInsuranceMasterId = @Id
            ORDER BY [Rank];
            """, conn);
        cmd.Parameters.AddWithValue("@Id", labInsuranceMasterId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new PendingCandidateRow(
                r.GetInt32(0), r.GetInt32(1), r.IsDBNull(2) ? null : r.GetInt32(2),
                r.IsDBNull(3) ? 0m : r.GetDecimal(3), r.IsDBNull(4) ? (byte)0 : r.GetByte(4),
                r.IsDBNull(5) ? 0m : r.GetDecimal(5), r.IsDBNull(6) ? 0 : r.GetInt32(6), r.IsDBNull(7) ? 0 : r.GetInt32(7)));
        return rows;
    }

    public async Task<IReadOnlyDictionary<string, int>> GetMappingStatusCountsAsync(CancellationToken ct)
    {
        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT ISNULL(NULLIF(LTRIM(RTRIM(MappingStatus)), ''),
                          CASE WHEN GlobalPayerID IS NOT NULL THEN 'Mapped' ELSE 'Unmapped' END) AS Status,
                   COUNT(1)
            FROM dbo.LabInsuranceMaster
            GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(MappingStatus)), ''),
                            CASE WHEN GlobalPayerID IS NOT NULL THEN 'Mapped' ELSE 'Unmapped' END);
            """, conn);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) counts[r.GetString(0)] = r.GetInt32(1);
        return counts;
    }

    private SqlConnection Open() => new(_connectionString);

    private static LabInsuranceRow Map(SqlDataReader r) => new()
    {
        LabInsuranceMasterId = r.GetInt32(0),
        PayerNameRaw = r.IsDBNull(1) ? string.Empty : r.GetString(1),
        PlanType = r.IsDBNull(2) ? null : r.GetString(2),
        LabState = r.IsDBNull(3) ? null : r.GetString(3),
        LabStateCode = r.IsDBNull(4) ? null : r.GetString(4),
        Remarks = r.IsDBNull(5) ? null : r.GetString(5),
        GlobalPayerId = r.IsDBNull(6) ? null : r.GetInt32(6)
    };
}
