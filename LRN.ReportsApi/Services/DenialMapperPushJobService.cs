using System.Collections.Concurrent;

namespace LRN.ReportsApi.Services;

// Async background jobs for the Denial Mapper "Push to Labs" flow. Both steps are slow and both are
// backgrounded so the admin is never blocked on the page (the request returns a jobId immediately):
//   1. Compare  (ComparePushAsync)  - counts open tasks per difference per lab and writes the
//      PendingConfirmation push-audit rows. Kicked off by "Push to Labs".
//   2. Confirm  (ConfirmPushAsync)  - merges every mapping into each lab master (the long step).
//      Kicked off later by the admin from the Push Status page, per the spec: "confirm pushing also
//      taking time so we can do it later." Leaves the push 'Pushed' / awaiting AR Manager.
// Job status is in-memory (transient); the durable push list comes from the push-audit tables,
// surfaced on the Push Status page.

public sealed class MapperPushJobStartResponse
{
    public string JobId { get; set; } = string.Empty;
    public string Operation { get; set; } = string.Empty;   // Compare | Confirm
    public string Status { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
    public int LabCount { get; set; }
}

public sealed class MapperPushJobStatusResponse
{
    public string JobId { get; set; } = string.Empty;
    public string Operation { get; set; } = string.Empty;   // Compare | Confirm
    public string Status { get; set; } = string.Empty;      // Queued | Running | Completed | Failed
    public string Message { get; set; } = string.Empty;
    public int LabCount { get; set; }
    public int TotalDifferences { get; set; }
    public IReadOnlyList<int> LabIds { get; set; } = Array.Empty<int>();
    public IReadOnlyList<long> PushAuditIds { get; set; } = Array.Empty<long>();
    public DateTime CreatedOnUtc { get; set; }
    public DateTime? CompletedOnUtc { get; set; }
}

public interface IDenialMapperPushJobService
{
    MapperPushJobStartResponse StartCompare(IReadOnlyList<int> labIds, string requestedBy, string role);
    MapperPushJobStartResponse StartConfirm(IReadOnlyList<long> pushAuditIds, string requestedBy, string role);
    MapperPushJobStatusResponse? GetStatus(string jobId, string requestedBy);
    IReadOnlyList<MapperPushJobStatusResponse> ListJobs(string requestedBy);
}

public sealed class DenialMapperPushJobService : IDenialMapperPushJobService
{
    private static readonly ConcurrentDictionary<string, PushJobState> Jobs = new(StringComparer.OrdinalIgnoreCase);
    private static readonly TimeSpan Retention = TimeSpan.FromHours(6);
    private static readonly TimeSpan MaxDuration = TimeSpan.FromMinutes(20);
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<DenialMapperPushJobService> _logger;

    public DenialMapperPushJobService(IServiceScopeFactory scopeFactory, ILogger<DenialMapperPushJobService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    public MapperPushJobStartResponse StartCompare(IReadOnlyList<int> labIds, string requestedBy, string role)
    {
        var ids = (labIds ?? Array.Empty<int>()).Where(x => x > 0).Distinct().OrderBy(x => x).ToList();
        if (ids.Count == 0)
            return new MapperPushJobStartResponse { Operation = "Compare", Status = "Failed", Message = "Select at least one lab to push." };

        ExpireStale();
        var active = Jobs.Values.FirstOrDefault(x =>
            x.Operation == "Compare"
            && string.Equals(x.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase)
            && (x.Status is "Queued" or "Running")
            && x.LabIds.SequenceEqual(ids));
        if (active is not null)
            return Start(active, "A comparison is already running for this selection.");

        var state = new PushJobState
        {
            JobId = Guid.NewGuid().ToString("N"),
            Operation = "Compare",
            RequestedBy = requestedBy ?? string.Empty,
            Role = role ?? string.Empty,
            LabIds = ids,
            Status = "Queued",
            Message = "Push received. Comparing the Super Master against the selected lab(s) in the background.",
            CreatedOnUtc = DateTime.UtcNow
        };
        Jobs[state.JobId] = state;
        _ = Task.Run(() => RunCompareAsync(state));
        return Start(state, state.Message);
    }

    public MapperPushJobStartResponse StartConfirm(IReadOnlyList<long> pushAuditIds, string requestedBy, string role)
    {
        var ids = (pushAuditIds ?? Array.Empty<long>()).Where(x => x > 0).Distinct().OrderBy(x => x).ToList();
        if (ids.Count == 0)
            return new MapperPushJobStartResponse { Operation = "Confirm", Status = "Failed", Message = "No pending push was selected to confirm." };

        ExpireStale();
        var active = Jobs.Values.FirstOrDefault(x =>
            x.Operation == "Confirm"
            && string.Equals(x.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase)
            && (x.Status is "Queued" or "Running")
            && x.PushAuditIds.SequenceEqual(ids));
        if (active is not null)
            return Start(active, "This push is already being confirmed.");

        var state = new PushJobState
        {
            JobId = Guid.NewGuid().ToString("N"),
            Operation = "Confirm",
            RequestedBy = requestedBy ?? string.Empty,
            Role = role ?? string.Empty,
            PushAuditIds = ids,
            Status = "Queued",
            Message = "Confirming the push. Distributing mappings to the lab(s) in the background.",
            CreatedOnUtc = DateTime.UtcNow
        };
        Jobs[state.JobId] = state;
        _ = Task.Run(() => RunConfirmAsync(state));
        return Start(state, state.Message);
    }

    private static MapperPushJobStartResponse Start(PushJobState s, string message) => new()
    {
        JobId = s.JobId,
        Operation = s.Operation,
        Status = s.Status,
        Message = message,
        LabCount = s.Operation == "Compare" ? s.LabIds.Count : s.PushAuditIds.Count
    };

    private async Task RunCompareAsync(PushJobState state)
    {
        state.Status = "Running";
        state.Message = "Comparing the Super Master against the selected lab(s). You can continue using the system.";
        try
        {
            using var scope = _scopeFactory.CreateScope();
            var repo = scope.ServiceProvider.GetRequiredService<IDenialMapperRepository>();
            using var cts = new CancellationTokenSource(MaxDuration);
            var compare = await repo.ComparePushAsync(state.LabIds, state.RequestedBy, cts.Token);
            state.PushAuditIds = compare.PushAuditIds;
            state.TotalDifferences = compare.TotalDifferences;
            state.LabCount = state.LabIds.Count;
            if (compare.PushAuditIds.Count == 0)
            {
                state.Status = "Failed";
                state.Message = "No active target lab was available to push.";
                return;
            }
            state.Status = "Completed";
            state.Message = $"Comparison complete — {compare.TotalDifferences} difference(s) across {state.LabIds.Count} lab(s). Confirmation required; you can confirm the push at any time from Push Status.";
        }
        catch (OperationCanceledException) { Fail(state, "Comparison timed out after 20 minutes. Please retry."); }
        catch (Exception ex) { Fail(state, $"Comparison failed: {ex.Message}", ex); }
        finally { state.CompletedOnUtc = DateTime.UtcNow; }
    }

    private async Task RunConfirmAsync(PushJobState state)
    {
        state.Status = "Running";
        state.Message = "Distributing mappings to the lab(s). You can continue using the system.";
        try
        {
            using var scope = _scopeFactory.CreateScope();
            var repo = scope.ServiceProvider.GetRequiredService<IDenialMapperRepository>();
            using var cts = new CancellationTokenSource(MaxDuration);
            var count = await repo.ConfirmPushAsync(state.PushAuditIds, state.RequestedBy, state.Role, cts.Token);
            state.LabCount = count;
            state.Status = count > 0 ? "Completed" : "Failed";
            state.Message = count > 0
                ? $"Push confirmed — Super Master distributed to {count} lab(s) and awaiting AR Manager confirmation. Existing overrides were preserved."
                : "No lab mappings were pushed. Refresh Push Status and try again.";
        }
        catch (OperationCanceledException) { Fail(state, "Confirm timed out after 20 minutes. Please retry."); }
        catch (Exception ex) { Fail(state, $"Confirm failed: {ex.Message}", ex); }
        finally { state.CompletedOnUtc = DateTime.UtcNow; }
    }

    private void Fail(PushJobState state, string message, Exception? ex = null)
    {
        state.Status = "Failed";
        state.Message = message;
        if (ex is not null) _logger.LogError(ex, "Denial mapper {Operation} job {JobId} failed.", state.Operation, state.JobId);
        else _logger.LogWarning("Denial mapper {Operation} job {JobId}: {Message}", state.Operation, state.JobId, message);
    }

    public MapperPushJobStatusResponse? GetStatus(string jobId, string requestedBy)
        => Jobs.TryGetValue(jobId ?? string.Empty, out var s)
           && string.Equals(s.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase)
            ? Project(s)
            : null;

    public IReadOnlyList<MapperPushJobStatusResponse> ListJobs(string requestedBy)
    {
        ExpireStale();
        return Jobs.Values
            .Where(x => string.Equals(x.RequestedBy, requestedBy, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(x => x.CreatedOnUtc)
            .Select(Project)
            .ToList();
    }

    private static MapperPushJobStatusResponse Project(PushJobState s) => new()
    {
        JobId = s.JobId,
        Operation = s.Operation,
        Status = s.Status,
        Message = s.Message,
        LabCount = s.LabCount,
        TotalDifferences = s.TotalDifferences,
        LabIds = s.LabIds,
        PushAuditIds = s.PushAuditIds,
        CreatedOnUtc = s.CreatedOnUtc,
        CompletedOnUtc = s.CompletedOnUtc
    };

    private static void ExpireStale()
    {
        var cutoff = DateTime.UtcNow - Retention;
        foreach (var kv in Jobs)
            if (kv.Value.CompletedOnUtc is { } c && c < cutoff)
                Jobs.TryRemove(kv.Key, out _);
    }

    private sealed class PushJobState
    {
        public string JobId = string.Empty;
        public string Operation = "Compare";
        public string RequestedBy = string.Empty;
        public string Role = string.Empty;
        public IReadOnlyList<int> LabIds = Array.Empty<int>();
        public IReadOnlyList<long> PushAuditIds = Array.Empty<long>();
        public string Status = "Queued";
        public string Message = string.Empty;
        public int LabCount;
        public int TotalDifferences;
        public DateTime CreatedOnUtc;
        public DateTime? CompletedOnUtc;
    }
}
