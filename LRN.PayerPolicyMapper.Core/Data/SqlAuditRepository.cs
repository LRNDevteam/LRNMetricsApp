using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Data.SqlClient;

namespace LRN.PayerPolicyMapper.Core.Data;

/// <summary>Writes dbo.PayerMatchAudit rows and upserts dbo.PayerAlias.</summary>
public sealed class SqlAuditRepository : IAuditRepository
{
    private readonly string _connectionString;

    public SqlAuditRepository(string connectionString) => _connectionString = connectionString;

    public async Task WriteAsync(PayerMatchAuditEntry e, CancellationToken ct)
    {
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            INSERT INTO dbo.PayerMatchAudit
                (LabInsuranceMasterId, PayerNameRaw, CanonicalName, ResolvedStateCode, StateSignalSource,
                 ResolvedProgramType, CandidateFamily, Decision, ConfidenceScore, SelectedGlobalPayerId,
                 CandidatesJson, AliasHit, ActionType, PerformedBy)
            VALUES
                (@LabId, @PayerNameRaw, @CanonicalName, @StateCode, @StateSource,
                 @Program, @Family, @Decision, @Confidence, @SelectedGid,
                 @CandidatesJson, @AliasHit, @ActionType, @PerformedBy);
            """, conn);
        cmd.Parameters.AddWithValue("@LabId", (object?)e.LabInsuranceMasterId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PayerNameRaw", (object?)e.PayerNameRaw ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@CanonicalName", (object?)e.CanonicalName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StateCode", (object?)e.ResolvedStateCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StateSource", (object?)e.StateSignalSource ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Program", (object?)e.ResolvedProgramType ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Family", (object?)e.CandidateFamily ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Decision", (object?)e.Decision ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Confidence", (object?)e.ConfidenceScore ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@SelectedGid", (object?)e.SelectedGlobalPayerId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@CandidatesJson", (object?)e.CandidatesJson ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@AliasHit", e.AliasHit);
        cmd.Parameters.AddWithValue("@ActionType", e.ActionType);
        cmd.Parameters.AddWithValue("@PerformedBy", e.PerformedBy);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task UpsertAliasAsync(string canonicalName, string? resolvedStateCode, string? stateSignalSource,
        int globalPayerId, string confirmedBy, string sourceAction, string? exampleRawName, CancellationToken ct)
    {
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        // PayerAlias.AliasId is a plain (non-identity) PK - seeded with explicit ids - so new rows take
        // MAX+1 under UPDLOCK/HOLDLOCK. The unique index on (CanonicalName, ResolvedStateCode) plus this
        // update-first upsert make re-confirming the same mapping idempotent: exactly one row per key.
        await using var cmd = new SqlCommand("""
            SET XACT_ABORT ON;
            BEGIN TRAN;
            UPDATE dbo.PayerAlias WITH (UPDLOCK, HOLDLOCK)
            SET GlobalPayerId = @Gid, ConfirmedBy = @ConfirmedBy, ConfirmedDate = GETDATE(),
                SourceAction = @SourceAction, StateSignalSource = @StateSource,
                ExampleRawName = COALESCE(@ExampleRaw, ExampleRawName),
                SourceRowCount = ISNULL(SourceRowCount, 0) + 1
            WHERE CanonicalName = @Name
              AND ((ResolvedStateCode IS NULL AND @State IS NULL) OR ResolvedStateCode = @State);
            IF @@ROWCOUNT = 0
                INSERT INTO dbo.PayerAlias
                    (AliasId, CanonicalName, ResolvedStateCode, StateSignalSource, GlobalPayerId,
                     ConfirmedBy, ConfirmedDate, SourceAction, ExampleRawName, SourceRowCount)
                SELECT ISNULL(MAX(AliasId), 0) + 1, @Name, @State, @StateSource, @Gid,
                       @ConfirmedBy, GETDATE(), @SourceAction, @ExampleRaw, 1
                FROM dbo.PayerAlias WITH (UPDLOCK, HOLDLOCK);
            COMMIT;
            """, conn);
        cmd.Parameters.AddWithValue("@Name", canonicalName);
        cmd.Parameters.AddWithValue("@State", (object?)resolvedStateCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StateSource", (object?)stateSignalSource ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Gid", globalPayerId);
        cmd.Parameters.AddWithValue("@ConfirmedBy", confirmedBy);
        cmd.Parameters.AddWithValue("@SourceAction", sourceAction);
        cmd.Parameters.AddWithValue("@ExampleRaw", (object?)exampleRawName ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);
    }
}
