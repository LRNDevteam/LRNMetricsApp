namespace LRN.PayerPolicyMapper;

/// <summary>Worker knobs (appsettings.json section "PayerMapper"). Matching thresholds live in "PayerMatching".</summary>
public sealed class PayerMapperOptions
{
    /// <summary>How often the poll loop wakes up to look for manual trigger requests / rules changes.</summary>
    public int PollIntervalSeconds { get; set; } = 30;
    public int BatchSize { get; set; } = 50;
    /// <summary>UTC hour (0-23) of the nightly safety-net rescan of ALL unmapped rows.</summary>
    public int NightlyHourUtc { get; set; } = 2;
    /// <summary>Interval between scheduled processing runs (each run is audited in dbo.PayerMapperRun).</summary>
    public int ScheduledRunIntervalMinutes { get; set; } = 60;
}
