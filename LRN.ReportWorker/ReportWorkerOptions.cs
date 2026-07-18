namespace LRN.ReportWorker;

/// <summary>Bound from the "ReportWorker" section of appsettings.json.</summary>
public sealed class ReportWorkerOptions
{
    /// <summary>Same folder the dashboard uses ({folder}\{LabName}.json per lab).</summary>
    public string LabConfigFolder { get; set; } = string.Empty;

    /// <summary>Labs whose queues this worker services.</summary>
    public List<string> Labs { get; set; } = [];

    /// <summary>Seconds between queue polls when idle. 5–10s is a good balance.</summary>
    public int PollIntervalSeconds { get; set; } = 5;

    /// <summary>Max reports generated simultaneously across all labs (CPU/RAM bound — ClosedXML is memory-hungry).</summary>
    public int MaxConcurrentReports { get; set; } = 2;

    /// <summary>Automatic retries for transient failures before a request is marked Failed.</summary>
    public byte MaxRetries { get; set; } = 2;

    /// <summary>Processing rows older than this are re-queued at startup / by the sweep (crash recovery).</summary>
    public int StuckAfterMinutes { get; set; } = 60;

    /// <summary>SQL CommandTimeout for the report SELECT (large datasets).</summary>
    public int QueryTimeoutSeconds { get; set; } = 1800;

    /// <summary>Local time of day the daily cleanup runs (HH:mm).</summary>
    public string CleanupTime { get; set; } = "02:00";

    /// <summary>Terminal rows are hard-deleted after this many days (audit rows kept longer).</summary>
    public int PurgeAfterDays { get; set; } = 90;

    public int AuditRetentionDays { get; set; } = 365;
}
