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
    /// LastEvaluatedOn IS NULL and the row falls inside the scope (UPDATE TOP ... OUTPUT with
    /// READPAST) so concurrent workers never double-process a row.
    /// </summary>
    Task<IReadOnlyList<LabInsuranceRow>> ClaimUnmappedBatchAsync(int batchSize, RunScope scope, CancellationToken ct);

    /// <summary>Clears LastEvaluatedOn for every row inside the scope so the run (re-)evaluates them.</summary>
    Task<int> ResetEvaluationsAsync(RunScope scope, CancellationToken ct);

    /// <summary>Stamps LastEvaluatedOn only (used after audit-only revalidation of a mapped row).</summary>
    Task StampEvaluatedAsync(int labInsuranceMasterId, CancellationToken ct);

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

/// <summary>
/// Service run audit: one dbo.PayerMapperRun row per worker run (hourly scheduled, manual
/// trigger from the Payer Service Audit page, rules-change, nightly rescan). The rows a run
/// updated are the dbo.PayerMatchAudit rows carrying its RunId.
/// </summary>
public interface IPayerMapperRunRepository
{
    /// <summary>Web trigger: queues a run (Status='Requested') with its scope; the worker claims it within one poll cycle.</summary>
    Task<Guid> RequestRunAsync(string requestedBy, RunScope scope, CancellationToken ct);
    /// <summary>Worker: starts its own run immediately (Status='InProgress').</summary>
    Task<Guid> CreateRunAsync(string triggerType, RunScope scope, CancellationToken ct);
    /// <summary>Worker: atomically claims the oldest 'Requested' run (READPAST - never double-claimed).</summary>
    Task<RequestedRun?> ClaimRequestedRunAsync(CancellationToken ct);
    Task CompleteRunAsync(Guid runId, string status, int total, int autoMapped, int pendingReview, int noMatch, int failedRows, string? errorMessage, CancellationToken ct);
    /// <summary>
    /// Removes a run header that never actually did anything (a scheduled/nightly/rules-change
    /// heartbeat that processed nothing), so the audit page is not littered with empty rows.
    /// User-initiated (Manual) runs are always kept, even when they process nothing.
    /// </summary>
    Task DeleteRunAsync(Guid runId, CancellationToken ct);
    Task<(IReadOnlyList<PayerMapperRunInfo> Runs, int TotalCount)> GetRunsAsync(int page, int pageSize, CancellationToken ct);
    Task<PayerMapperRunInfo?> GetRunAsync(Guid runId, CancellationToken ct);
    /// <summary>The PayerMatchAudit rows written under this run (the payers the run updated).</summary>
    Task<IReadOnlyList<PayerMapperRunDetailRow>> GetRunDetailsAsync(Guid runId, CancellationToken ct);
}

public sealed record RequestedRun(Guid RunId, RunScope Scope);

public sealed class PayerMapperRunInfo
{
    public Guid RunId { get; init; }
    public string TriggerType { get; init; } = string.Empty;
    public string? Scope { get; init; }
    public string? RequestedBy { get; init; }
    public string Status { get; init; } = string.Empty;
    public DateTime CreatedOn { get; init; }
    public DateTime? StartedOn { get; init; }
    public DateTime? CompletedOn { get; init; }
    public int TotalProcessed { get; init; }
    public int AutoMapped { get; init; }
    public int PendingReview { get; init; }
    public int NoMatch { get; init; }
    public int FailedRows { get; init; }
    public string? ErrorMessage { get; init; }
}

public sealed record PayerMapperRunDetailRow(
    long AuditId, int? LabInsuranceMasterId, string? PayerNameRaw, string? CanonicalName,
    string? Decision, decimal? ConfidenceScore, int? SelectedGlobalPayerId,
    string? MappingStatus, string? ActionType, DateTime PerformedOn,
    string? LabName, string? LabState, string? PayerState);

public sealed class PayerMatchAuditEntry
{
    /// <summary>Service run this evaluation belongs to (null for web-request evaluations and user actions).</summary>
    public Guid? RunId { get; init; }
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
