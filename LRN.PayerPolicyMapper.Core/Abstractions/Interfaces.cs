namespace LRN.PayerPolicyMapper.Core.Abstractions;

/// <summary>Loads the reference tables + Payer Policy master for the Step 0 index, plus a change watermark.</summary>
public interface IReferenceDataRepository
{
    Task<ReferenceDataSet> LoadAsync(CancellationToken ct);
    /// <summary>
    /// Opaque version string combining MAX(CreatedOn/ModifiedOn/CreatedDate/ConfirmedDate) and row counts
    /// across PayerPolicyInsuranceMaster, the rules tables and PayerAlias. A change means the index must
    /// be rebuilt and unmapped rows re-evaluated.
    /// </summary>
    Task<string> GetRulesVersionAsync(CancellationToken ct);
}

/// <summary>Provides the current Step 0 index; implementations rebuild atomically when the rules version changes.</summary>
public interface IPayerPolicyIndexProvider
{
    Task<PayerPolicyIndex> GetAsync(CancellationToken ct);
    /// <summary>Forces a version check now; Rebuilt is true when the index was swapped for a new snapshot.</summary>
    Task<(PayerPolicyIndex Index, bool Rebuilt)> RefreshIfChangedAsync(CancellationToken ct);
}

/// <summary>Step 9 persistence against dbo.LabInsuranceMaster + dbo.PendingMatchCandidates.</summary>
public interface ILabInsuranceRepository
{
    Task<LabInsuranceRow?> GetRowAsync(int labInsuranceMasterId, CancellationToken ct);

    /// <summary>
    /// Worker claim: atomically stamps LastEvaluatedOn on up to batchSize rows where
    /// GlobalPayerID IS NULL AND LastEvaluatedOn IS NULL (UPDATE TOP ... OUTPUT with READPAST)
    /// so concurrent workers never double-process a row.
    /// </summary>
    Task<IReadOnlyList<LabInsuranceRow>> ClaimUnmappedBatchAsync(int batchSize, CancellationToken ct);

    /// <summary>Clears LastEvaluatedOn for every unmapped row so the next poll cycles re-evaluate them.</summary>
    Task<int> ResetUnmappedEvaluationsAsync(CancellationToken ct);

    Task ApplyAutoMapAsync(int labInsuranceMasterId, int globalPayerId, string payerNameNormalized, string mappedBy, CancellationToken ct);
    Task ApplyManualReviewAsync(int labInsuranceMasterId, string payerNameNormalized, IReadOnlyList<MatchCandidate> candidates, CancellationToken ct);
    Task ApplyNoMatchAsync(int labInsuranceMasterId, string payerNameNormalized, string remarksNote, CancellationToken ct);

    /// <summary>
    /// User-confirmed mapping (Approve / Manual Map): writes GlobalPayerID + status, carries the
    /// matched policy record's reference columns (normalized name, Global Payer Code, group code,
    /// plan type, state, benefit admin) over to the Lab record where the policy has a value, and
    /// clears PendingMatchCandidates.
    /// </summary>
    Task<bool> ApplyUserMappingAsync(int labInsuranceMasterId, PayerPolicyRecord policyRecord, string mappedBy, string userName, CancellationToken ct);

    Task<IReadOnlyList<PendingCandidateRow>> GetPendingCandidatesAsync(int labInsuranceMasterId, CancellationToken ct);

    /// <summary>Row counts per MappingStatus (for the notification bell / dashboards).</summary>
    Task<IReadOnlyDictionary<string, int>> GetMappingStatusCountsAsync(CancellationToken ct);
}

/// <summary>One stored dbo.PendingMatchCandidates row.</summary>
public sealed record PendingCandidateRow(
    int LabInsuranceMasterId, int PPInsuranceMasterId, int? GlobalPayerId,
    decimal Score, byte Rank, decimal BaseNameScore, int StateAdjustment, int ProgramAdjustment);

/// <summary>Writes dbo.PayerMatchAudit rows and upserts dbo.PayerAlias.</summary>
public interface IAuditRepository
{
    Task WriteAsync(PayerMatchAuditEntry entry, CancellationToken ct);
    /// <summary>Idempotent upsert keyed on (CanonicalName, ResolvedStateCode) - re-running the same mapping never duplicates.</summary>
    Task UpsertAliasAsync(string canonicalName, string? resolvedStateCode, string? stateSignalSource,
        int globalPayerId, string confirmedBy, string sourceAction, string? exampleRawName, CancellationToken ct);
}

public sealed class PayerMatchAuditEntry
{
    public int? LabInsuranceMasterId { get; init; }
    public string? PayerNameRaw { get; init; }
    public string? CanonicalName { get; init; }
    public string? ResolvedStateCode { get; init; }
    public string? StateSignalSource { get; init; }
    public string? ResolvedProgramType { get; init; }
    public string? CandidateFamily { get; init; }
    public string? Decision { get; init; }
    public decimal? ConfidenceScore { get; init; }
    public int? SelectedGlobalPayerId { get; init; }
    public string? CandidatesJson { get; init; }
    public bool AliasHit { get; init; }
    public string ActionType { get; init; } = "Evaluate";
    public string PerformedBy { get; init; } = "System";
}

/// <summary>
/// Review notification hook. The solution already has a Payer Master notification mechanism
/// (dbo.PayerMasterNotifications); the SQL implementation writes there. Hosts without it can
/// register the logging stub.
/// </summary>
public interface INotificationService
{
    Task NotifyReviewNeededAsync(LabInsuranceRow row, MatchResult result, CancellationToken ct);
}
