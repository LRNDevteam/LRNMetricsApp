using LRN.PayerPolicyMapper.Core;
using LRN.PayerPolicyMapper.Core.Abstractions;

namespace LRN.PayerPolicyMapper.Tests;

public sealed class StaticIndexProvider : IPayerPolicyIndexProvider
{
    private readonly PayerPolicyIndex _index;
    public StaticIndexProvider(PayerPolicyIndex index) => _index = index;
    public Task<PayerPolicyIndex> GetAsync(CancellationToken ct) => Task.FromResult(_index);
    public Task<(PayerPolicyIndex Index, bool Rebuilt)> RefreshIfChangedAsync(CancellationToken ct) => Task.FromResult((_index, false));
}

/// <summary>
/// In-memory ILabInsuranceRepository. The claim mirrors the SQL contract
/// (UPDATE TOP ... OUTPUT with READPAST): stamping LastEvaluatedOn IS the claim,
/// and two concurrent claimers can never receive the same row.
/// </summary>
public sealed class InMemoryLabRepository : ILabInsuranceRepository
{
    public sealed class State
    {
        public required LabInsuranceRow Row;
        public int? GlobalPayerId;
        public string? PayerNameNormalized;
        public string? MappingStatus;
        public string? MappedBy;
        public string? Remarks;
        public DateTime? LastEvaluatedOn;
    }

    private readonly object _lock = new();
    public Dictionary<int, State> Rows { get; } = new();
    public Dictionary<int, List<MatchCandidate>> PendingCandidates { get; } = new();

    public void Add(LabInsuranceRow row) => Rows[row.LabInsuranceMasterId] = new State { Row = row, Remarks = row.Remarks };

    public Task<LabInsuranceRow?> GetRowAsync(int id, CancellationToken ct)
        => Task.FromResult(Rows.TryGetValue(id, out var s) ? s.Row : null);

    public Task<IReadOnlyList<LabInsuranceRow>> ClaimUnmappedBatchAsync(int batchSize, CancellationToken ct)
    {
        lock (_lock)
        {
            var claimed = Rows.Values
                .Where(s => s.GlobalPayerId is null && s.LastEvaluatedOn is null)
                .OrderBy(s => s.Row.LabInsuranceMasterId)
                .Take(batchSize)
                .ToList();
            foreach (var s in claimed) s.LastEvaluatedOn = DateTime.UtcNow;
            return Task.FromResult<IReadOnlyList<LabInsuranceRow>>(claimed.Select(s => s.Row).ToList());
        }
    }

    public Task<int> ResetUnmappedEvaluationsAsync(CancellationToken ct)
    {
        lock (_lock)
        {
            var n = 0;
            foreach (var s in Rows.Values.Where(s => s.GlobalPayerId is null)) { s.LastEvaluatedOn = null; n++; }
            return Task.FromResult(n);
        }
    }

    public Task ApplyAutoMapAsync(int id, int globalPayerId, string normalized, string mappedBy, CancellationToken ct)
    {
        var s = Rows[id];
        s.GlobalPayerId = globalPayerId;
        s.PayerNameNormalized = normalized;
        s.MappingStatus = "Mapped";
        s.MappedBy = mappedBy;
        s.LastEvaluatedOn = DateTime.UtcNow;
        PendingCandidates.Remove(id);
        return Task.CompletedTask;
    }

    public Task ApplyManualReviewAsync(int id, string normalized, IReadOnlyList<MatchCandidate> candidates, CancellationToken ct)
    {
        var s = Rows[id];
        s.PayerNameNormalized = normalized;
        s.MappingStatus = "Unmapped - Pending Review";
        s.LastEvaluatedOn = DateTime.UtcNow;
        PendingCandidates[id] = candidates.ToList();
        return Task.CompletedTask;
    }

    public Task ApplyNoMatchAsync(int id, string normalized, string remarksNote, CancellationToken ct)
    {
        var s = Rows[id];
        s.PayerNameNormalized = normalized;
        s.MappingStatus = "No Match Found";
        s.Remarks = string.IsNullOrWhiteSpace(s.Remarks) ? remarksNote
            : s.Remarks.Contains(remarksNote) ? s.Remarks : $"{s.Remarks}; {remarksNote}";
        s.LastEvaluatedOn = DateTime.UtcNow;
        return Task.CompletedTask;
    }

    public Task<bool> ApplyUserMappingAsync(int id, PayerPolicyRecord policyRecord, string mappedBy, string userName, CancellationToken ct)
    {
        if (!Rows.TryGetValue(id, out var s)) return Task.FromResult(false);
        s.GlobalPayerId = policyRecord.GlobalPayerId;
        s.PayerNameNormalized = policyRecord.PayerNameNormalized ?? s.PayerNameNormalized;
        s.MappingStatus = "Mapped";
        s.MappedBy = mappedBy;
        s.LastEvaluatedOn = DateTime.UtcNow;
        PendingCandidates.Remove(id);
        return Task.FromResult(true);
    }

    public Task<IReadOnlyDictionary<string, int>> GetMappingStatusCountsAsync(CancellationToken ct)
    {
        IReadOnlyDictionary<string, int> counts = Rows.Values
            .GroupBy(s => s.MappingStatus ?? (s.GlobalPayerId.HasValue ? "Mapped" : "Unmapped"))
            .ToDictionary(g => g.Key, g => g.Count());
        return Task.FromResult(counts);
    }

    public Task<IReadOnlyList<PendingCandidateRow>> GetPendingCandidatesAsync(int id, CancellationToken ct)
    {
        var list = PendingCandidates.TryGetValue(id, out var c)
            ? c.Select(x => new PendingCandidateRow(id, x.Record.PPInsuranceMasterId, x.Record.GlobalPayerId,
                x.Score, (byte)x.Rank, x.BaseNameScore, x.StateAdjustment, x.ProgramAdjustment)).ToList()
            : new List<PendingCandidateRow>();
        return Task.FromResult<IReadOnlyList<PendingCandidateRow>>(list);
    }
}

/// <summary>In-memory IAuditRepository whose alias upsert mirrors the SQL unique key (CanonicalName, ResolvedStateCode).</summary>
public sealed class InMemoryAuditRepository : IAuditRepository
{
    public List<PayerMatchAuditEntry> Entries { get; } = new();
    public Dictionary<(string, string?), int> Aliases { get; } = new();
    public int AliasUpsertCalls { get; private set; }

    public Task WriteAsync(PayerMatchAuditEntry entry, CancellationToken ct)
    {
        lock (Entries) Entries.Add(entry);
        return Task.CompletedTask;
    }

    public Task UpsertAliasAsync(string canonicalName, string? state, string? source, int globalPayerId,
        string confirmedBy, string sourceAction, string? exampleRawName, CancellationToken ct)
    {
        lock (Aliases)
        {
            AliasUpsertCalls++;
            Aliases[(canonicalName, state)] = globalPayerId;
        }
        return Task.CompletedTask;
    }
}

public sealed class CountingNotificationService : INotificationService
{
    public int Count { get; private set; }
    public Task NotifyReviewNeededAsync(LabInsuranceRow row, MatchResult result, CancellationToken ct)
    {
        Count++;
        return Task.CompletedTask;
    }
}
