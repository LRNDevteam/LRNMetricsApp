namespace LRN.ReportQueue.Shared;

/// <summary>
/// Data access for the UserReqReports queue. The per-lab connection string is
/// passed at call time (same convention as IPredictionDbRepository) because the
/// queue table lives in EACH lab database.
/// </summary>
public interface IReportRequestRepository
{
    /// <summary>Inserts a Queued request; throws <see cref="DuplicateReportRequestException"/> on an active duplicate.</summary>
    Task<long> QueueAsync(string connectionString, NewReportRequest request, CancellationToken ct = default);

    /// <summary>Atomically claims the oldest Queued request; null when the queue is empty.</summary>
    Task<ClaimedReport?> ClaimNextAsync(string connectionString, string workerName, CancellationToken ct = default);

    Task CompleteAsync(string connectionString, long reportId, GeneratedReportFile file,
        int retentionDays, string workerName, CancellationToken ct = default);

    Task FailAsync(string connectionString, long reportId, string errorMessage,
        bool isTransient, byte maxRetries, string workerName, CancellationToken ct = default);

    /// <summary>
    /// Live progress (0–100) while a row is Processing — feeds the badge %.
    /// Returns false when the row is no longer Processing (e.g. user cancelled).
    /// </summary>
    Task<bool> UpdateProgressAsync(string connectionString, long reportId, byte percent, CancellationToken ct = default);

    /// <summary>User cancel for Queued/Processing. Returns false when not owned or not active.</summary>
    Task<bool> CancelAsync(string connectionString, long reportId, string userName, CancellationToken ct = default);

    /// <summary>True when the row is still Processing (worker should finish/write Complete).</summary>
    Task<bool> IsStillProcessingAsync(string connectionString, long reportId, CancellationToken ct = default);

    /// <summary>Immediately returns one cleanly interrupted Processing job to Queued.</summary>
    Task RequeueInterruptedAsync(string connectionString, long reportId, string workerName,
        CancellationToken ct = default);

    /// <summary>Re-queues rows stuck in Processing (worker crash/restart recovery).</summary>
    Task<int> ResetStuckAsync(string connectionString, int stuckAfterMinutes, byte maxRetries,
        string workerName, CancellationToken ct = default);

    /// <summary>Marks expired rows and returns the physical files to delete.</summary>
    Task<List<ExpiredReportFile>> ExpireAsync(string connectionString, string workerName, CancellationToken ct = default);

    /// <summary>Hard-deletes old terminal rows; trims audit history.</summary>
    Task PurgeAsync(string connectionString, int purgeAfterDays, int auditRetentionDays, CancellationToken ct = default);

    /// <summary>Latest requests for one user in one lab DB (panel + badge).</summary>
    Task<List<UserReportRow>> GetUserReportsAsync(string connectionString, string userName,
        int top = 20, CancellationToken ct = default);

    /// <summary>Ownership + token check for download. Null when not found / not owned.</summary>
    Task<UserReportRow?> GetForDownloadAsync(string connectionString, long reportId,
        string userName, Guid token, CancellationToken ct = default);

    /// <summary>Physical file path for a verified download (never exposed to the browser).</summary>
    Task<string?> GetFilePathAsync(string connectionString, long reportId,
        string userName, Guid token, CancellationToken ct = default);

    /// <summary>
    /// Marks the row Deleted for the owning user. Null when not found / not owned;
    /// otherwise the (possibly null) file path to physically delete.
    /// </summary>
    Task<DeletedReportInfo?> MarkDeletedAsync(string connectionString, long reportId, string userName, CancellationToken ct = default);

    /// <summary>Failed → Queued for the owning user. False if not owned / not Failed.</summary>
    Task<bool> RetryAsync(string connectionString, long reportId, string userName, CancellationToken ct = default);

    Task MarkDownloadedAsync(string connectionString, long reportId, CancellationToken ct = default);
}
